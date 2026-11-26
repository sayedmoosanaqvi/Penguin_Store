"""100% Data-Grounded AI Review Intelligence & Fake Review Detection Engine.

Zero canned/boilerplate templates:
  - 0 reviews   -> `has_insights: False`, honest empty state, zero fabricated ratings/pros/cons.
  - 1-2 reviews -> `sample_tier: "early_feedback"`, summarizes ONLY what those real shoppers wrote.
  - 3+ reviews  -> `sample_tier: "full_insights"`, extracts Pros, Cons, Aspect Sentiment & Verdict
                   strictly grounded in actual Supabase review text.
"""

from __future__ import annotations

import json
import logging
import math
import re
import time
from collections import Counter
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

from sqlalchemy.orm import Session, load_only

from app.models import Product, ProductReviewInsight, Review
from app.services.ai_telemetry_service import record_review_trust_metric

logger = logging.getLogger(__name__)

INSIGHT_SCHEMA_VERSION = 2

_SPAM_PATTERNS = re.compile(
    r"(https?://|www\.|\.com\b|whatsapp|telegram|crypto|free\s+money|"
    r"click\s+here|buy\s+followers|promo\s+code|dm\s+me|earn\s+\$\d+)",
    re.IGNORECASE,
)

_BOT_CLICHES = (
    "a+++",
    "1000% recommend",
    "best product in the universe",
    "good good good",
    "nice nice nice",
    "buy now buy now",
    "five stars five stars",
)

_POSITIVE_WORDS = {
    "great", "excellent", "amazing", "good", "love", "sturdy", "comfortable",
    "authentic", "fast", "worth", "value", "premium", "clean", "durable",
    "smooth", "accurate", "recommend", "solid", "impressive", "perfect",
    "quality", "reliable", "responsive", "fit", "sharp", "crisp", "genuine",
}

_NEGATIVE_WORDS = {
    "bad", "poor", "terrible", "worst", "broken", "fake", "slow", "overpriced",
    "cheap", "flimsy", "disappointed", "waste", "late", "damaged", "defective",
    "useless", "horrible", "awful", "fragile", "uncomfortable", "tight", "loose",
}

_ASPECT_KEYWORDS: dict[str, tuple[str, ...]] = {
    "Quality": (
        "quality", "build", "material", "fabric", "sturdy", "durable",
        "craftsmanship", "finish", "stitching", "solid", "flimsy", "premium",
    ),
    "Value": (
        "price", "value", "worth", "money", "affordable", "cheap",
        "expensive", "overpriced", "deal", "budget", "cost",
    ),
    "Delivery/Experience": (
        "delivery", "shipping", "arrived", "packaging", "box", "service",
        "fast", "quick", "late", "dispatch", "experience", "3d",
    ),
    "Performance": (
        "performance", "fit", "comfortable", "wear", "works", "speed",
        "battery", "display", "size", "accurate", "reliable", "use", "sound",
    ),
}


def _shannon_char_entropy(text: str) -> float:
    clean = text.strip().lower()
    if not clean:
        return 0.0
    counts = Counter(clean)
    n = len(clean)
    return -sum((c / n) * math.log2(c / n) for c in counts.values())


def _token_set(text: str) -> set[str]:
    return set(re.findall(r"[a-z0-9]{2,}", text.lower()))


def _jaccard_similarity(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union > 0 else 0.0


def _mentioned_aspects(text: str) -> set[str]:
    lower_text = (text or "").lower()
    found: set[str] = set()
    for aspect, kw_list in _ASPECT_KEYWORDS.items():
        if any(kw in lower_text for kw in kw_list):
            found.add(aspect)
    return found


def _extract_aspect_sentiments(text: str, rating: int) -> dict[str, str]:
    default_polarity = (
        "positive" if rating >= 4 else ("negative" if rating <= 2 else "neutral")
    )

    aspects: dict[str, str] = {}
    lower_text = (text or "").lower()
    clauses = [
        c.strip()
        for c in re.split(r"[,.;!?]|\b(?:but|however|although|yet|except)\b", lower_text)
        if c.strip()
    ]

    for aspect, kw_list in _ASPECT_KEYWORDS.items():
        relevant_clauses = [c for c in clauses if any(kw in c for kw in kw_list)]
        if not relevant_clauses:
            aspects[aspect] = default_polarity
            continue

        c_text = " ".join(relevant_clauses)
        c_tokens = set(re.findall(r"[a-z0-9]+", c_text))
        c_pos = len(c_tokens & _POSITIVE_WORDS)
        c_neg = len(c_tokens & _NEGATIVE_WORDS)

        if c_pos > c_neg:
            aspects[aspect] = "positive"
        elif c_neg > c_pos:
            aspects[aspect] = "negative"
        else:
            aspects[aspect] = default_polarity

    return aspects


def format_human_trust_reasons(
    *,
    verified_purchase: bool,
    trust_score: float,
    is_flagged_suspicious: bool,
    trust_flags: list[str],
    comment: str = "",
) -> str:
    """Build concise, transparent shopper-readable authenticity cues for a single review."""
    if is_flagged_suspicious or trust_score < 52.0:
        primary_issue = "Unverified generic hype"
        for f in trust_flags:
            fl = f.lower()
            if "spam" in fl or "link" in fl:
                primary_issue = "Promotional link spam"
                break
            if "duplicate" in fl:
                primary_issue = "Copy-paste duplicate text"
                break
            if "mismatch" in fl:
                primary_issue = "Rating-sentiment contradiction"
                break
            if "burst" in fl:
                primary_issue = "Unusual burst posting"
                break
            if "entropy" in fl or "repetition" in fl or "bot-template" in fl:
                primary_issue = "Repetitive template phrasing"
                break
            if "short" in fl:
                primary_issue = "Minimal detail"
        return f"Lower Trust • {primary_issue}"

    cues: list[str] = []
    if verified_purchase:
        cues.append("Verified Purchase")
    else:
        cues.append("Community Account")

    words = re.findall(r"[a-zA-Z0-9']+", comment or "")
    mentioned = _mentioned_aspects(comment or "")
    if len(words) >= 14 and len(mentioned) >= 2:
        cues.append(f"Detailed ({', '.join(sorted(mentioned)[:2])})")
    elif len(words) >= 8:
        cues.append("Specific usage details")
    elif len(mentioned) >= 1:
        cues.append(f"Mentions {next(iter(sorted(mentioned)))}")
    else:
        cues.append("Concise buyer note")

    return " • ".join(cues)


def evaluate_review_trust(
    db: Optional[Session],
    *,
    product_id: int,
    user_id: int,
    user_email: str,
    rating: int,
    title: Optional[str],
    comment: str,
    verified_purchase: bool,
    tags: Optional[list[str]] = None,
    exclude_review_id: Optional[int] = None,
) -> dict[str, Any]:
    """
    Compute a 0-100 Trust Score, suspicious flag, explainable trust_flags,
    human-readable trust_reasons, and Aspect-Based Sentiment breakdown.
    """
    started_at = time.perf_counter()
    full_text = f"{title or ''} {comment or ''}".strip()
    words = re.findall(r"[a-zA-Z0-9']+", full_text)
    word_count = len(words)
    unique_ratio = (len({w.lower() for w in words}) / word_count) if word_count > 0 else 0.0
    entropy = _shannon_char_entropy(comment or "")

    score = 72.0
    flags: list[str] = []

    # 1. Verified purchase signal
    if verified_purchase:
        score += 18.0
    else:
        score -= 4.0
        flags.append("Unverified purchase (no matching completed order found)")

    # 2. Length, lexical diversity, concrete product details & Shannon entropy
    mentioned = _mentioned_aspects(full_text)
    if word_count < 4 or len((comment or "").strip()) < 15:
        score -= 18.0
        flags.append("Ultra-short / low-information review text")
    elif word_count >= 12 and unique_ratio >= 0.62 and len(mentioned) >= 1:
        score += 8.0
    elif word_count >= 8 and unique_ratio >= 0.60:
        score += 5.0

    if entropy < 2.35:
        score -= 26.0
        flags.append("Low character entropy / repetitive character sequence")
    elif unique_ratio < 0.42 and word_count >= 6:
        score -= 22.0
        flags.append("High word repetition / template-like phrasing")

    # 3. Promotional URL / spam pattern check
    if _SPAM_PATTERNS.search(full_text):
        score -= 48.0
        flags.append("Promotional link or external solicitation spam detected")

    # 4. Excessive ALL-CAPS or punctuation hype
    alpha_chars = [c for c in (comment or "") if c.isalpha()]
    caps_ratio = (
        sum(1 for c in alpha_chars if c.isupper()) / len(alpha_chars)
        if len(alpha_chars) >= 12
        else 0.0
    )
    exclamations = full_text.count("!")
    if caps_ratio > 0.48 or exclamations >= 4:
        score -= 14.0
        flags.append("Excessive capitalization or exclamation hype")

    # 5. Bot cliche / rating-sentiment contradiction
    lower_full = full_text.lower()
    if any(cliche in lower_full for cliche in _BOT_CLICHES):
        score -= 20.0
        flags.append("Generic bot-template praise pattern detected")

    tokens = _token_set(full_text)
    pos_count = len(tokens & _POSITIVE_WORDS)
    neg_count = len(tokens & _NEGATIVE_WORDS)
    if (rating == 5 and neg_count >= 2 and pos_count == 0) or (
        rating == 1 and pos_count >= 2 and neg_count == 0
    ):
        score -= 22.0
        flags.append("Rating-sentiment polarity mismatch")

    # 6. Cross-product duplicate / near-duplicate phrasing & burst velocity
    if db is not None:
        try:
            recent_reviews = (
                db.query(Review.id, Review.comment, Review.user_id, Review.created_at)
                .order_by(Review.created_at.desc())
                .limit(80)
                .all()
            )
            cur_tokens = _token_set(comment or "")
            dup_found = False
            burst_count = 0
            now_utc = datetime.now(timezone.utc)
            ten_min_ago = now_utc - timedelta(minutes=10)

            for r_id, r_comment, r_uid, r_created in recent_reviews:
                if exclude_review_id is not None and int(r_id) == int(exclude_review_id):
                    continue
                if r_uid == user_id and r_created is not None:
                    created_aware = (
                        r_created
                        if r_created.tzinfo is not None
                        else r_created.replace(tzinfo=timezone.utc)
                    )
                    if created_aware >= ten_min_ago:
                        burst_count += 1

                if not dup_found and cur_tokens and len(cur_tokens) >= 4:
                    other_tokens = _token_set(r_comment or "")
                    if _jaccard_similarity(cur_tokens, other_tokens) >= 0.78:
                        dup_found = True

            if dup_found:
                score -= 34.0
                flags.append("Duplicate or near-duplicate phrasing across catalog")

            if burst_count >= 3:
                score -= 20.0
                flags.append("Burst-posting velocity anomaly (>=3 reviews in 10m)")
        except Exception as exc:
            logger.debug("Duplicate/burst review check skipped: %s", exc)

    trust_score = round(max(5.0, min(99.0, score)), 1)
    has_severe_flag = any(
        kw in f.lower()
        for f in flags
        for kw in ("spam", "duplicate", "repetitive", "entropy", "mismatch", "bot-template")
    )
    is_flagged = bool(trust_score < 52.0 or (has_severe_flag and trust_score < 65.0))
    moderation_status = "flagged" if is_flagged else "approved"

    aspects: dict[str, Any] = _extract_aspect_sentiments(full_text, rating)
    clean_tags = [
        str(t).strip()[:40]
        for t in (tags or [])
        if str(t).strip()
    ][:6]
    if clean_tags:
        aspects["_tags"] = clean_tags

    trust_reasons = format_human_trust_reasons(
        verified_purchase=verified_purchase,
        trust_score=trust_score,
        is_flagged_suspicious=is_flagged,
        trust_flags=flags,
        comment=comment,
    )

    elapsed_ms = round((time.perf_counter() - started_at) * 1000.0, 2)
    if db is not None:
        try:
            record_review_trust_metric(
                latency_ms=elapsed_ms,
                trust_score=trust_score,
                is_flagged_suspicious=is_flagged,
                product_id=product_id,
                db=db,
            )
        except Exception:
            pass

    return {
        "trust_score": trust_score,
        "is_flagged_suspicious": is_flagged,
        "trust_flags": flags,
        "trust_reasons": trust_reasons,
        "aspect_sentiments": aspects,
        "tags": clean_tags,
        "moderation_status": moderation_status,
        "analysis_latency_ms": elapsed_ms,
    }


def _clean_quote_clause(raw: str, max_len: int = 115) -> str:
    txt = re.sub(r"\s+", " ", (raw or "").strip()).strip("\"' ")
    if len(txt) <= max_len:
        return txt.rstrip(".")
    cut = txt[:max_len].rsplit(" ", 1)[0]
    return f"{cut}…"


def _synthesize_grounded_insights(
    product_name: str,
    visible_rows: list[Any],
    high_trust_rows: list[Any],
    aspect_bars: dict[str, int],
    trust_weighted_rating: float,
    verified_purchase_count: int,
) -> tuple[list[str], list[str], str]:
    """
    100% Data-Grounded Pros, Cons & Verdict.
    NEVER invents generic store marketing phrases; every bullet is derived from
    the actual reviews present in Supabase.
    """
    source_rows = high_trust_rows if high_trust_rows else visible_rows
    count = len(visible_rows)

    pos_quotes: list[str] = []
    neg_quotes: list[str] = []
    tag_counts: Counter[str] = Counter()

    for r in source_rows:
        rating = int(getattr(r, "rating", 0) or 0)
        title = str(getattr(r, "title", "") or "").strip()
        comment = str(getattr(r, "comment", "") or "").strip()
        badge = "Verified buyer" if getattr(r, "verified_purchase", False) else "Shopper"

        # Collect any structured tags attached to the review
        try:
            asp_raw = json.loads(getattr(r, "aspect_sentiments", "{}") or "{}")
            if isinstance(asp_raw, dict) and isinstance(asp_raw.get("_tags"), list):
                for t in asp_raw["_tags"]:
                    if isinstance(t, str) and t.strip():
                        tag_counts[t.strip()] += 1
        except Exception:
            pass

        snippet_src = f"{title} — {comment}" if (title and title.lower() not in comment.lower()) else (comment or title)
        if not snippet_src:
            continue

        if rating >= 4:
            pos_quotes.append(f"{badge}: \"{_clean_quote_clause(snippet_src)}\"")
        elif rating <= 2:
            neg_quotes.append(f"{badge} critique ({rating}★): \"{_clean_quote_clause(snippet_src)}\"")
        else:
            # 3-star mixed review: split on contrast conjunctions if present
            parts = re.split(r"\b(?:but|however|although|yet)\b", comment, maxsplit=1, flags=re.IGNORECASE)
            if len(parts) == 2 and len(parts[0].strip()) >= 8 and len(parts[1].strip()) >= 8:
                pos_quotes.append(f"{badge}: \"{_clean_quote_clause(parts[0])}\"")
                neg_quotes.append(f"{badge} note: \"{_clean_quote_clause(parts[1])}\"")
            else:
                neg_quotes.append(f"Mixed 3★ note: \"{_clean_quote_clause(snippet_src)}\"")

    pros: list[str] = []
    cons: list[str] = []

    if count <= 2:
        # Strict 1-2 review Early Feedback mode: quote ONLY what those 1-2 reviewers wrote
        pros.extend(pos_quotes[:2])
        cons.extend(neg_quotes[:2])
        verdict = (
            f"Early Feedback based on {count} customer review{'s' if count != 1 else ''} "
            f"({verified_purchase_count} verified purchase{'s' if verified_purchase_count != 1 else ''}), "
            f"averaging {trust_weighted_rating:.2f}/5.0 trust-weighted stars for {product_name}."
        )
        return pros, cons, verdict

    # 3+ reviews: combine grounded aspect consensus + top real shopper quotes + recurring tags
    for asp, pct in sorted(aspect_bars.items(), key=lambda kv: kv[1], reverse=True):
        if pct >= 75 and len(pros) < 2:
            pros.append(f"{pct}% positive buyer sentiment on {asp} across {count} reviews")
        elif pct <= 55 and len(cons) < 2:
            cons.append(f"Mixed/critical buyer sentiment on {asp} ({pct}% positive)")

    for t_name, t_cnt in tag_counts.most_common(2):
        if t_cnt >= 2 and len(pros) < 3:
            pros.append(f"{t_cnt} reviewers tagged \"{t_name}\"")

    for pq in pos_quotes:
        if len(pros) >= 3:
            break
        pros.append(pq)

    for nq in neg_quotes:
        if len(cons) >= 2:
            break
        cons.append(nq)

    verdict = (
        f"Based on {count} customer reviews ({verified_purchase_count} verified purchases), "
        f"{product_name} earns a {trust_weighted_rating:.2f}/5.0 Trust-Weighted Rating."
    )
    return pros[:3], cons[:2], verdict


def invalidate_product_review_insights(db: Optional[Session], product_id: int) -> None:
    """Purge cached DB & in-memory review insights immediately after any review mutation."""
    if db is not None:
        try:
            db.query(ProductReviewInsight).filter(
                ProductReviewInsight.product_id == int(product_id)
            ).delete(synchronize_session=False)
            db.commit()
        except Exception:
            db.rollback()
    try:
        from app.core.supabase_rest import get_supabase_client

        get_supabase_client().table("product_review_insights").delete().eq(
            "product_id", int(product_id)
        ).execute()
    except Exception:
        pass
    try:
        from app.core.concurrency import global_single_flight

        global_single_flight.invalidate_prefix(f"review_insights:{int(product_id)}")
    except Exception:
        pass


def get_or_generate_product_review_insights(
    db: Optional[Session],
    product_id: int,
    *,
    force_refresh: bool = False,
) -> dict[str, Any]:
    """
    Return 100% honest, data-grounded Review Intelligence for `product_id`.
    - 0 reviews   -> `has_insights: False` (never fabricates ratings or template pros/cons).
    - 1-2 reviews -> `sample_tier: "early_feedback"` grounded solely in those reviews.
    - 3+ reviews  -> `sample_tier: "full_insights"` grounded in actual review text & aspects.
    """
    from app.core.supabase_rest import fetch_product_by_id_https, get_supabase_client

    pid = int(product_id)
    product_name = f"Product #{pid}"
    if db is not None:
        try:
            p_obj = (
                db.query(Product)
                .options(load_only(Product.id, Product.name))
                .filter(Product.id == pid)
                .first()
            )
            if p_obj is not None:
                product_name = p_obj.name
            else:
                p_https = fetch_product_by_id_https(pid)
                if p_https is None:
                    raise ValueError("Product not found")
                product_name = str(p_https.get("name") or product_name)
        except ValueError:
            raise
        except Exception:
            p_https = fetch_product_by_id_https(pid)
            if p_https is None:
                raise ValueError("Product not found")
            product_name = str(p_https.get("name") or product_name)
    else:
        p_https = fetch_product_by_id_https(pid)
        if p_https is None:
            raise ValueError("Product not found")
        product_name = str(p_https.get("name") or product_name)

    all_rows: list[Any] = []
    if db is not None:
        try:
            all_rows = (
                db.query(Review)
                .filter(Review.product_id == pid)
                .order_by(Review.created_at.desc())
                .all()
            )
        except Exception:
            all_rows = []

    if not all_rows:
        try:
            res = (
                get_supabase_client()
                .table("reviews")
                .select("*")
                .eq("product_id", pid)
                .order("created_at", desc=True)
                .execute()
            )
            from types import SimpleNamespace

            all_rows = [SimpleNamespace(**r) for r in (res.data or []) if isinstance(r, dict)]
        except Exception:
            pass

    visible_rows = [
        r for r in all_rows if (getattr(r, "moderation_status", None) or "approved") != "hidden"
    ]
    current_count = len(visible_rows)
    flagged_count = sum(1 for r in all_rows if bool(getattr(r, "is_flagged_suspicious", False)))

    # STRICT HONESTY RULE #1: 0 visible reviews -> ZERO fabricated insights or template fluff!
    if current_count == 0:
        invalidate_product_review_insights(db, pid)
        return {
            "product_id": pid,
            "has_insights": False,
            "sample_tier": "no_reviews",
            "early_feedback_badge": None,
            "raw_rating": 0.0,
            "trust_weighted_rating": 0.0,
            "total_reviews": 0,
            "verified_purchase_count": 0,
            "verified_authentic_percent": 0.0,
            "flagged_suspicious_count": flagged_count,
            "summary": {
                "pros": [],
                "cons": [],
                "verdict": "No customer reviews yet. Be the first verified shopper to share your experience.",
            },
            "aspect_sentiment_bars": {},
            "cached": False,
        }

    verified_purchase_count = sum(1 for r in visible_rows if bool(getattr(r, "verified_purchase", False)))
    sample_tier = "early_feedback" if current_count <= 2 else "full_insights"
    early_badge = (
        f"Early Feedback — Based on {current_count} review{'s' if current_count != 1 else ''}"
        if current_count <= 2
        else None
    )

    # Check schema-v2 DB cache when count >= 3
    cached_row = None
    if db is not None:
        try:
            cached_row = (
                db.query(ProductReviewInsight)
                .filter(ProductReviewInsight.product_id == pid)
                .first()
            )
            if (
                cached_row is not None
                and not force_refresh
                and cached_row.review_count_at_generation == current_count
            ):
                bars_raw = json.loads(cached_row.aspect_bars_json or "{}")
                if isinstance(bars_raw, dict) and bars_raw.get("_schema_v") == INSIGHT_SCHEMA_VERSION:
                    clean_bars = (
                        {
                            k: int(v)
                            for k, v in bars_raw.items()
                            if not k.startswith("_") and isinstance(v, (int, float))
                        }
                        if current_count >= 3
                        else {}
                    )
                    return {
                        "product_id": pid,
                        "has_insights": True,
                        "sample_tier": sample_tier,
                        "early_feedback_badge": early_badge,
                        "raw_rating": round(float(cached_row.raw_rating), 2),
                        "trust_weighted_rating": round(float(cached_row.trust_weighted_rating), 2),
                        "total_reviews": current_count,
                        "verified_purchase_count": verified_purchase_count,
                        "verified_authentic_percent": round(float(cached_row.verified_authentic_percent), 1),
                        "flagged_suspicious_count": int(cached_row.flagged_count),
                        "summary": {
                            "pros": json.loads(cached_row.pros_json or "[]"),
                            "cons": json.loads(cached_row.cons_json or "[]"),
                            "verdict": cached_row.verdict,
                        },
                        "aspect_sentiment_bars": clean_bars,
                        "cached": True,
                    }
        except Exception:
            pass

    raw_rating = round(
        sum(int(getattr(r, "rating", 0) or 0) for r in visible_rows) / current_count,
        2,
    )
    weighted_num = 0.0
    weighted_den = 0.0
    authentic_count = 0

    aspect_totals: dict[str, list[float]] = {
        "Quality": [],
        "Value": [],
        "Delivery/Experience": [],
        "Performance": [],
    }

    for r in visible_rows:
        t_score = float(getattr(r, "trust_score", None) or 85.0)
        is_susp = bool(getattr(r, "is_flagged_suspicious", False))
        is_ver = bool(getattr(r, "verified_purchase", False))
        r_rating = int(getattr(r, "rating", 5) or 5)
        r_comment = str(getattr(r, "comment", "") or "")
        r_title = str(getattr(r, "title", "") or "")

        weight = max(0.05, (t_score / 100.0) * (0.2 if is_susp else (1.30 if is_ver else 1.0)))
        weighted_num += r_rating * weight
        weighted_den += weight

        if not is_susp and t_score >= 60.0:
            authentic_count += 1

        # Only record aspect sentiment bars for aspects ACTUALLY mentioned in the review text!
        full_txt = f"{r_title} {r_comment}".strip()
        mentioned = _mentioned_aspects(full_txt)
        if not is_susp and mentioned:
            try:
                asp_map = json.loads(getattr(r, "aspect_sentiments", "{}") or "{}")
            except Exception:
                asp_map = {}
            if not isinstance(asp_map, dict) or not asp_map:
                asp_map = _extract_aspect_sentiments(full_txt, r_rating)

            for asp_name in mentioned:
                pol = asp_map.get(asp_name, "positive" if r_rating >= 4 else "neutral")
                val = 1.0 if pol == "positive" else (0.60 if pol == "neutral" else 0.10)
                aspect_totals[asp_name].append(val)

    trust_weighted = round(weighted_num / weighted_den, 2) if weighted_den > 0 else raw_rating
    verified_authentic_pct = round((authentic_count / current_count) * 100.0, 1)

    aspect_bars = (
        {
            k: int(round((sum(vals) / len(vals)) * 100))
            for k, vals in aspect_totals.items()
            if vals  # Strictly omit unmentioned aspects instead of fabricating 86%!
        }
        if current_count >= 3
        else {}  # Suppress statistical aspect percentages for 1-2 review Early Feedback tier
    )

    high_trust_rows = [
        r
        for r in visible_rows
        if not bool(getattr(r, "is_flagged_suspicious", False))
        and float(getattr(r, "trust_score", None) or 85.0) >= 60.0
    ]

    pros, cons, verdict = _synthesize_grounded_insights(
        product_name=product_name,
        visible_rows=visible_rows,
        high_trust_rows=high_trust_rows,
        aspect_bars=aspect_bars,
        trust_weighted_rating=trust_weighted,
        verified_purchase_count=verified_purchase_count,
    )

    bars_to_store = dict(aspect_bars)
    bars_to_store["_schema_v"] = INSIGHT_SCHEMA_VERSION

    if db is not None:
        try:
            if cached_row is None:
                cached_row = ProductReviewInsight(product_id=pid)
                db.add(cached_row)
            cached_row.raw_rating = raw_rating
            cached_row.trust_weighted_rating = trust_weighted
            cached_row.total_reviews = current_count
            cached_row.verified_authentic_percent = verified_authentic_pct
            cached_row.flagged_count = flagged_count
            cached_row.pros_json = json.dumps(pros)
            cached_row.cons_json = json.dumps(cons)
            cached_row.verdict = verdict
            cached_row.aspect_bars_json = json.dumps(bars_to_store)
            cached_row.review_count_at_generation = current_count
            db.commit()
        except Exception as exc:
            db.rollback()
            logger.debug("Could not cache ProductReviewInsight: %s", exc)

    return {
        "product_id": pid,
        "has_insights": True,
        "sample_tier": sample_tier,
        "early_feedback_badge": early_badge,
        "raw_rating": raw_rating,
        "trust_weighted_rating": trust_weighted,
        "total_reviews": current_count,
        "verified_purchase_count": verified_purchase_count,
        "verified_authentic_percent": verified_authentic_pct,
        "flagged_suspicious_count": flagged_count,
        "summary": {
            "pros": pros,
            "cons": cons,
            "verdict": verdict,
        },
        "aspect_sentiment_bars": aspect_bars,
        "cached": False,
    }
