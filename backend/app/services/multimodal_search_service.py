"""Multimodal RRF (Reciprocal Rank Fusion) Search Service.

Combines visual ResNet-50 ONNX pgvector similarity with natural-language/voice
intent, numeric budget constraints, category filtering, 3D flags, and Trust Score.
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
    """Extract numeric min/max budget and 3D intent directly from natural language."""
    eff_min = min_price
    eff_max = max_price
    only_3d = False

    if not query_text or not query_text.strip():
        return eff_min, eff_max, only_3d

    q = re.sub(r"(\d),(\d{3})", r"\1\2", query_text.lower())

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
            r"(?:under|below|less\s+than|max|up\s+to|budget(?:\s+of)?|within)\s*\$?\s*(\d+(?:\.\d+)?)",
            r"\$\s*(\d+(?:\.\d+)?)\s*(?:or\s+less|max)",
            r"(\d+(?:\.\d+)?)\s*dollars?\s*(?:or\s+less|max)?",
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
    """
    started = time.perf_counter()

    clean_query = (query_text or "").strip()
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

    if image_bytes:
        try:
            from app.routers.visual_search import (
                _calibrate_display_score,
                _catalog_cache,
            )

            query_info = analyze_and_embed_query(image_bytes)
            analysis_info = {
                "was_deblurred": bool(query_info.get("was_deblurred")),
                "sharpness_score": query_info.get("sharpness_score"),
            }
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
        except Exception as exc:
            logger.warning("Multimodal visual branch fallback: %s", exc)

    # 3. Text / Voice Intent branch
    text_ranks: dict[int, int] = {}
    text_reasons: dict[int, str] = {}
    if clean_query:
        # Strip explicit price clauses before keyword scoring so "under 200" doesn't dilute keyword match
        keyword_query = re.sub(
            r"\b(?:under|below|less\s+than|between|over|above|max|min|budget|similar\s+to\s+this|dollars?)\b|\$\s*\d+(?:\.\d+)?",
            " ",
            clean_query,
            flags=re.IGNORECASE,
        )
        keyword_query = " ".join(keyword_query.split()).strip() or clean_query

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
                scored_txt.append((pid, score, reason))

        scored_txt.sort(
            key=lambda item: (item[1], float(candidate_by_id[item[0]].get("rating") or 4.8)),
            reverse=True,
        )
        for rank_idx, (pid, _sc, reason) in enumerate(scored_txt, start=1):
            text_ranks[pid] = rank_idx
            text_reasons[pid] = reason

    # 4. Reciprocal Rank Fusion (RRF) & Trust Boost
    rrf_k = 60.0
    fused: list[dict[str, Any]] = []

    for p in candidates:
        pid = int(p["id"])
        r_vis = visual_ranks.get(pid)
        r_txt = text_ranks.get(pid)

        # If both visual and text queries exist, include candidates found in either branch
        # (or top visual candidates if text was purely a price filter)
        if image_bytes and r_vis is None and r_txt is None:
            continue
        if not image_bytes and clean_query and r_txt is None and eff_max is None and eff_min is None:
            continue

        vis_rrf = (1.0 / (rrf_k + r_vis)) if r_vis is not None else 0.0
        txt_rrf = (1.0 / (rrf_k + r_txt)) if r_txt is not None else 0.0
        trust_rating = float(p.get("rating") or 4.8)
        trust_boost = (trust_rating / 5.0) * 0.0025
        rrf_score = round(vis_rrf + txt_rrf + trust_boost, 6)

        vis_score = visual_scores.get(pid, 0.0)
        max_possible_rrf = (
            (1.0 / 61.0 if image_bytes else 0.0)
            + (1.0 / 61.0 if clean_query else 0.0)
            + 0.0025
        )
        norm_confidence = (
            min(0.99, max(0.55, rrf_score / max(0.001, max_possible_rrf)))
            if rrf_score > 0
            else 0.72
        )
        if r_vis == 1 and vis_score > 0.7:
            norm_confidence = max(norm_confidence, vis_score)

        # Build concise explainable match badge
        reason_parts: list[str] = []
        if r_vis is not None and vis_score > 0:
            reason_parts.append(f"{int(round(vis_score * 100))}% Visual")
        if r_txt is not None:
            reason_parts.append(text_reasons.get(pid, "Text Match"))
        if eff_max is not None:
            reason_parts.append(f"Under ${eff_max:.0f}")
        if pid in active_3d_ids:
            reason_parts.append("3D Twin Ready")
        reason_parts.append(f"{trust_rating:.1f}★ Trust")

        match_reason = " • ".join(reason_parts)

        fused.append(
            {
                "product": p,
                "score": round(float(norm_confidence), 4),
                "visual_score": round(float(vis_score), 4),
                "rrf_score": rrf_score,
                "match_label": (
                    "Exact Multimodal Match"
                    if norm_confidence >= 0.85
                    else ("Strong Hybrid Match" if norm_confidence >= 0.68 else "Relevant Match")
                ),
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
        "query_status": "success" if matches else "not_in_database",
        "in_database": bool(matches),
        "message": (
            f"Found {len(matches)} multimodal match{'es' if len(matches) != 1 else ''} in {latency_ms:.0f} ms."
            if matches
            else "No in-stock products matched all multimodal constraints."
        ),
        "latency_ms": latency_ms,
        "analysis": {
            **analysis_info,
            "query_text": clean_query,
            "effective_max_price": eff_max,
            "effective_min_price": eff_min,
            "only_3d": eff_only_3d,
            "fusion_method": "Reciprocal Rank Fusion (k=60)",
        },
        "matches": matches,
    }
