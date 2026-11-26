"""Multimodal RRF (Reciprocal Rank Fusion) Search Service.

Combines visual ResNet-50 ONNX pgvector similarity with natural-language/voice
intent, spoken/numeric budget constraints, category filtering, 3D flags,
calibrated confidence tiers, and explainable `match_reason` badges.
"""

from __future__ import annotations

import logging
import re
import time
from typing import Any, Optional

import numpy as np

from app.agent.tools import _score_product_dict
from app.core.supabase_rest import (
    fetch_3d_catalog_ids_https,
    fetch_products_https,
)
from app.services.ai_telemetry_service import record_multimodal_search_metric
from app.vector_service import analyze_and_embed_query

logger = logging.getLogger(__name__)


def _parse_inline_price_constraints(
    query_text: Optional[str],
    min_price: Optional[float],
    max_price: Optional[float],
) -> tuple[Optional[float], Optional[float], bool]:
    """Extract numeric/spoken min/max budget and 3D intent directly from natural language."""
    eff_min = min_price
    eff_max = max_price
    only_3d = False

    if not query_text or not query_text.strip():
        return eff_min, eff_max, only_3d

    raw = query_text
    try:
        from app.routers.voice_ai import normalize_spoken_numbers

        raw = normalize_spoken_numbers(raw)
    except Exception:
        pass

    q = re.sub(r"(\d),(\d{3})", r"\1\2", raw.lower())

    if re.search(r"\b(?:3d|ar|glb|360)\b", q):
        only_3d = True

    if eff_min is None and eff_max is None:
        between_match = re.search(
            r"between\s*\$?\s*(\d+(?:\.\d+)?)\s*(?:and|to|-)\s*\$?\s*(\d+(?:\.\d+)?)",
            q,
        )
        if between_match:
            v1 = float(between_match.group(1))
            v2 = float(between_match.group(2))
            eff_min = min(v1, v2)
            eff_max = max(v1, v2)
            return eff_min, eff_max, only_3d

    if eff_max is None:
        max_patterns = (
            r"(?:under|below|less\s+than|max|maximum|up\s+to|budget(?:\s+of)?|within|around)\s*\$?\s*(\d+(?:\.\d+)?)",
            r"\$\s*(\d+(?:\.\d+)?)\s*(?:or\s+less|max)",
            r"(\d+(?:\.\d+)?)\s*(?:dollars?|bucks?|usd)\s*(?:or\s+less|max)?",
        )
        for pat in max_patterns:
            m = re.search(pat, q)
            if m:
                try:
                    eff_max = float(m.group(1))
                    break
                except ValueError:
                    continue

    if eff_min is None:
        min_match = re.search(
            r"(?:over|above|at\s+least|min|minimum)\s*\$?\s*(\d+(?:\.\d+)?)",
            q,
        )
        if min_match:
            try:
                eff_min = float(min_match.group(1))
            except ValueError:
                pass

    return eff_min, eff_max, only_3d


def execute_multimodal_rrf_search(
    *,
    image_bytes: Optional[bytes] = None,
    query_text: Optional[str] = None,
    min_price: Optional[float] = None,
    max_price: Optional[float] = None,
    category: Optional[str] = None,
    only_3d: bool = False,
    limit: int = 12,
) -> dict[str, Any]:
    """
    Execute hybrid Multimodal Search using Reciprocal Rank Fusion (RRF):
      rrf_score = 1/(60 + rank_visual) + 1/(60 + rank_text) + trust_boost
    with honest, calibrated confidence tiers (`strong_match`, `similar_style`,
    `closest_alternatives`) instead of artificial rank-1 inflation.
    """
    started = time.perf_counter()

    raw_query = (query_text or "").strip()
    clean_query = raw_query
    if raw_query:
        try:
            from app.routers.voice_ai import normalize_spoken_numbers

            clean_query = normalize_spoken_numbers(raw_query)
        except Exception:
            clean_query = raw_query

    eff_min, eff_max, inferred_3d = _parse_inline_price_constraints(
        clean_query,
        min_price,
        max_price,
    )
    eff_only_3d = bool(only_3d or inferred_3d)

    all_products = fetch_products_https()
    active_3d_ids = set(fetch_3d_catalog_ids_https())

    # 1. Hard stock, 3D, category & price filtering
    candidates: list[dict[str, Any]] = []
    for p in all_products:
        stock_cnt = int(p.get("stock") if p.get("stock") is not None else 50)
        if stock_cnt <= 0:
            continue
        pid = int(p.get("id") or 0)
        price_val = float(p.get("price") or 0.0)
        if eff_min is not None and price_val < eff_min:
            continue
        if eff_max is not None and price_val > eff_max:
            continue
        if eff_only_3d and pid not in active_3d_ids:
            continue
        if category and category.strip() and category.strip().lower() != "all":
            if category.strip().lower() not in str(p.get("category") or "").lower():
                continue
        candidates.append(dict(p))

    candidate_by_id: dict[int, dict[str, Any]] = {
        int(p["id"]): p for p in candidates if p.get("id") is not None
    }

    # 2. Visual branch (ResNet-50 ONNX cosine similarity via pgvector cache)
    visual_ranks: dict[int, int] = {}
    visual_scores: dict[int, float] = {}
    analysis_info: dict[str, Any] = {}
    is_blank_or_noise = False

    from app.routers.visual_search import (
        _calibrate_display_score,
        _catalog_cache,
        build_visual_search_summary,
        classify_visual_confidence,
    )

    if image_bytes:
        try:
            query_info = analyze_and_embed_query(image_bytes)
            is_blank_or_noise = bool(query_info.get("is_blank_or_noise"))
            analysis_info = {
                "was_deblurred": bool(query_info.get("was_deblurred")),
                "sharpness_score": query_info.get("sharpness_score"),
                "is_blank_or_noise": is_blank_or_noise,
            }
            if not is_blank_or_noise:
                catalog_prods, catalog_matrix = _catalog_cache.get_catalog()
                if catalog_prods and catalog_matrix is not None:
                    variant_vecs = query_info.get("variant_vectors") or [
                        query_info["primary_vector"]
                    ]
                    variant_weights = query_info.get("variant_weights") or [
                        1.0 for _ in variant_vecs
                    ]
                    best_raw: Optional[np.ndarray] = None
                    for vec, w in zip(variant_vecs, variant_weights):
                        q_arr = np.asarray(vec, dtype=np.float32)
                        sims = catalog_matrix @ q_arr
                        weighted = sims * float(0.95 + 0.05 * float(w))
                        best_raw = (
                            weighted
                            if best_raw is None
                            else np.maximum(best_raw, weighted)
                        )

                    if best_raw is not None:
                        scored_vis: list[tuple[int, float]] = []
                        for idx, cat_prod in enumerate(catalog_prods):
                            pid = int(cat_prod["id"])
                            if pid not in candidate_by_id:
                                continue
                            cal = _calibrate_display_score(
                                float(best_raw[idx]),
                                was_deblurred=bool(query_info.get("was_deblurred")),
                                is_heavily_blurred=bool(
                                    query_info.get("is_heavily_blurred")
                                ),
                            )
                            scored_vis.append((pid, float(cal)))

                        scored_vis.sort(key=lambda pair: pair[1], reverse=True)
                        for rank_idx, (pid, cal_score) in enumerate(scored_vis, start=1):
                            visual_ranks[pid] = rank_idx
                            visual_scores[pid] = cal_score
        except ValueError:
            raise
        except Exception as exc:
            logger.warning("Multimodal visual branch fallback: %s", exc)
        finally:
            import gc

            gc.collect()

    # 3. Text / Voice Intent branch
    text_ranks: dict[int, int] = {}
    text_scores: dict[int, float] = {}
    text_reasons: dict[int, str] = {}
    has_keyword_intent = False

    if clean_query:
        keyword_query = re.sub(
            r"\b(?:under|below|less\s+than|between|over|above|at\s+least|max|maximum|min|minimum|up\s+to|within|around|budget(?:\s+of)?|similar\s+to\s+this|like\s+this|with\s+3d(?:\s+model|\s+view)?|dollars?|bucks?|usd)\b|\$\s*\d+(?:\.\d+)?",
            " ",
            clean_query,
            flags=re.IGNORECASE,
        )
        keyword_query = " ".join(keyword_query.split()).strip()
        if keyword_query:
            has_keyword_intent = True
            scored_txt: list[tuple[int, float, str]] = []
            for p in candidates:
                pid = int(p["id"])
                score, reason = _score_product_dict(
                    p,
                    keyword_query,
                    category,
                    active_3d_ids,
                )
                if score > 2.5:
                    scored_txt.append((pid, float(score), reason))

            scored_txt.sort(
                key=lambda item: (item[1], float(candidate_by_id[item[0]].get("rating") or 0.0)),
                reverse=True,
            )
            for rank_idx, (pid, sc, reason) in enumerate(scored_txt, start=1):
                text_ranks[pid] = rank_idx
                text_scores[pid] = sc
                text_reasons[pid] = reason

    # 4. Reciprocal Rank Fusion (RRF) & Calibrated Confidence
    rrf_k = 60.0
    fused: list[dict[str, Any]] = []

    if is_blank_or_noise and not has_keyword_intent:
        candidates = []

    for p in candidates:
        pid = int(p["id"])
        r_vis = visual_ranks.get(pid)
        r_txt = text_ranks.get(pid)

        if image_bytes and r_vis is None and r_txt is None:
            continue
        if not image_bytes and has_keyword_intent and r_txt is None:
            continue

        vis_rrf = (1.0 / (rrf_k + r_vis)) if r_vis is not None else 0.0
        txt_rrf = (1.0 / (rrf_k + r_txt)) if r_txt is not None else 0.0
        rating_val = float(p.get("rating") or 0.0)
        review_cnt = int(p.get("reviews") or 0)
        trust_boost = ((rating_val / 5.0) * 0.0020) if review_cnt > 0 else 0.0005
        rrf_score = round(vis_rrf + txt_rrf + trust_boost, 6)

        vis_score = float(visual_scores.get(pid, 0.0))
        raw_txt_sc = float(text_scores.get(pid, 0.0))
        txt_conf = (
            min(0.95, 0.58 + (raw_txt_sc / 95.0))
            if r_txt is not None
            else 0.0
        )

        # Calibrated confidence (NEVER inflated to 99% solely for being rank #1)
        if image_bytes and has_keyword_intent:
            if r_txt is not None and r_vis is not None:
                calibrated_conf = min(
                    0.98,
                    0.62 * vis_score + 0.38 * txt_conf + (0.04 if vis_score >= 0.65 else 0.0),
                )
            elif r_vis is not None:
                calibrated_conf = vis_score * 0.88
            else:
                calibrated_conf = txt_conf * 0.82
        elif image_bytes:
            calibrated_conf = vis_score
        elif has_keyword_intent:
            calibrated_conf = txt_conf
        else:
            calibrated_conf = 0.76

        calibrated_conf = round(float(max(0.05, min(0.99, calibrated_conf))), 4)
        tier, tier_label = classify_visual_confidence(calibrated_conf)

        # Build concise explainable match_reason
        reason_parts: list[str] = []
        if r_vis is not None and vis_score > 0:
            reason_parts.append(f"{int(round(vis_score * 100))}% Visual")
        if r_txt is not None:
            reason_parts.append(text_reasons.get(pid, "Text Match"))
        if eff_max is not None:
            reason_parts.append(f"Under ${eff_max:.0f}")
        if pid in active_3d_ids:
            reason_parts.append("3D Twin Ready")
        stock_cnt = int(p.get("stock") if p.get("stock") is not None else 50)
        reason_parts.append(f"Only {stock_cnt} Left" if 0 < stock_cnt <= 5 else "In Stock")

        match_reason = " • ".join(reason_parts)

        fused.append(
            {
                "product": p,
                "score": calibrated_conf,
                "visual_score": round(vis_score, 4),
                "rrf_score": rrf_score,
                "confidence_tier": tier,
                "match_label": tier_label,
                "match_reason": match_reason,
                "has_3d_model": pid in active_3d_ids,
            }
        )

    fused.sort(
        key=lambda item: (item["rrf_score"], item["score"]),
        reverse=True,
    )
    matches = fused[:limit]

    latency_ms = round((time.perf_counter() - started) * 1000.0, 2)
    top1 = matches[0]["score"] if matches else 0.0
    overall_tier = (
        matches[0]["confidence_tier"]
        if matches
        else ("blank_or_noise" if is_blank_or_noise else "none")
    )
    search_summary = (
        build_visual_search_summary(
            confidence_tier=overall_tier,
            match_count=len(matches),
            is_blank_or_noise=is_blank_or_noise,
            has_text_refinement=bool(clean_query),
        )
        if image_bytes
        else (
            f"Found {len(matches)} matching in-stock product{'s' if len(matches) != 1 else ''} in {latency_ms:.0f} ms."
            if matches
            else "No in-stock products matched all search constraints."
        )
    )
    avg5 = (
        round(sum(m["score"] for m in matches[:5]) / min(5, len(matches)), 4)
        if matches
        else 0.0
    )

    try:
        record_multimodal_search_metric(
            latency_ms=latency_ms,
            top1_similarity=float(top1),
            avg_top5_similarity=float(avg5),
            total_matches=len(matches),
            has_image=bool(image_bytes),
            has_text=bool(clean_query),
        )
    except Exception:
        pass

    return {
        "status": "success",
        "query_status": (
            "closest_alternatives"
            if overall_tier == "closest_alternatives"
            else ("success" if matches else "not_in_database")
        ),
        "in_database": bool(matches),
        "confidence_tier": overall_tier,
        "search_summary": search_summary,
        "message": search_summary,
        "latency_ms": latency_ms,
        "analysis": {
            **analysis_info,
            "search_mode": "multimodal_rrf",
            "confidence_tier": overall_tier,
            "search_summary": search_summary,
            "query_text": clean_query,
            "max_price": eff_max,
            "effective_max_price": eff_max,
            "effective_min_price": eff_min,
            "only_3d": eff_only_3d,
            "search_time_ms": round(latency_ms, 1),
            "fusion_method": "Reciprocal Rank Fusion (k=60)",
        },
        "matches": matches,
    }
