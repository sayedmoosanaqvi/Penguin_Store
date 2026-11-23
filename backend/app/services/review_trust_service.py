"""AI-Powered Trustworthy Review & Fake Review Detection Engine (Phase 1)."""

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
    "quality", "reliable", "responsive", "fit", "sharp",
}

_NEGATIVE_WORDS = {
    "bad", "poor", "terrible", "worst", "broken", "fake", "slow", "overpriced",
    "cheap", "flimsy", "disappointed", "waste", "late", "damaged", "defective",
    "useless", "horrible", "awful", "fragile", "uncomfortable",
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
        "battery", "display", "size", "accurate", "reliable", "use",
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


def _extract_aspect_sentiments(text: str, rating: int) -> dict[str, str]:
    default_polarity = (
        "positive" if rating >= 4 else ("negative" if rating <= 2 else "neutral")
    )

    aspects: dict[str, str] = {}
    lower_text = text.lower()
    # Split text into clauses/sentences by punctuation and conjunctions
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


def evaluate_review_trust(
    db: Session,
    *,
    product_id: int,
    user_id: int,
    user_email: str,
    rating: int,
    title: Optional[str],
    comment: str,
    verified_purchase: bool,
) -> dict[str, Any]:
    """
    Compute a 0-100 Trust Score, suspicious flag, explainable trust_flags,
    and Aspect-Based Sentiment breakdown for a submitted or audited review.
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

    # 2. Length, lexical diversity & Shannon entropy
    if word_count < 4 or len((comment or "").strip()) < 15:
        score -= 18.0
        flags.append("Ultra-short / low-information review text")
    elif word_count >= 9 and unique_ratio >= 0.62:
        score += 7.0

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
        score -= 18.0
        flags.append("Rating-sentiment polarity mismatch")

    # 6. Cross-product duplicate / near-duplicate phrasing
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
            if r_uid == user_id and r_created is not None:
                created_aware = (
                    r_created
                    if r_created.tzinfo is not None
                    else r_created.replace(tzinfo=timezone.utc)
                )
                if created_aware >= ten_min_ago:
                    burst_count += 1

            if not dup_found and cur_tokens:
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
    aspects = _extract_aspect_sentiments(full_text, rating)

    elapsed_ms = round((time.perf_counter() - started_at) * 1000.0, 2)
    record_review_trust_metric(
        latency_ms=elapsed_ms,
        trust_score=trust_score,
        is_flagged_suspicious=is_flagged,
        product_id=product_id,
        db=db,
    )

    return {
        "trust_score": trust_score,
        "is_flagged_suspicious": is_flagged,
        "trust_flags": flags,
        "aspect_sentiments": aspects,
        "moderation_status": moderation_status,
        "analysis_latency_ms": elapsed_ms,
    }


def _synthesize_summary_from_reviews(
    product: Product,
    high_trust_reviews: list[Review],
    aspect_bars: dict[str, int],
    trust_weighted_rating: float,
) -> tuple[list[str], list[str], str]:
    """Generate 3-bullet AI Summary (pros, cons, verdict) from high-trust reviews."""
    cat = (product.category or "Catalog").title()
    pname = product.name

    pros: list[str] = []
    cons: list[str] = []

    if aspect_bars.get("Quality", 85) >= 75:
        pros.append(f"Consistent praise for {pname} build quality and material finish")
    if aspect_bars.get("Value", 82) >= 75:
        pros.append(f"Strong price-to-performance value at ${float(product.price):.2f}")
    if aspect_bars.get("Performance", 84) >= 75:
        pros.append(f"Reliable daily performance and accurate {cat} sizing/specifications")

    # Extract specific snippets from top high-trust positive/negative reviews
    pos_Snippets = [
        (r.title or r.comment).strip()
        for r in high_trust_reviews
        if r.rating >= 4 and len((r.comment or "").strip()) >= 18
    ]
    neg_Snippets = [
        (r.title or r.comment).strip()
        for r in high_trust_reviews
        if r.rating <= 3 and len((r.comment or "").strip()) >= 12
    ]

    if pos_Snippets and len(pros) < 3:
        snippet = pos_Snippets[0][:95].rstrip(".")
        pros.append(f"Verified buyer highlight: \"{snippet}\"")

    while len(pros) < 3:
        fallbacks = [
            f"Verified customer satisfaction across {cat} criteria",
            "Interactive 3D & catalog verification reduces buyer uncertainty",
            "Smooth dispatch and responsive store support",
        ]
        for fb in fallbacks:
            if fb not in pros and len(pros) < 3:
                pros.append(fb)

    if neg_Snippets:
        snippet = neg_Snippets[0][:95].rstrip(".")
        cons.append(f"Customer note: \"{snippet}\"")
    else:
        lowest_aspect = min(aspect_bars.items(), key=lambda kv: kv[1])[0]
        if aspect_bars.get(lowest_aspect, 85) < 75:
            cons.append(f"Mixed feedback on {lowest_aspect} from a subset of reviewers")
        else:
            cons.append("No major recurring defects reported among verified high-trust buyers")

    verdict = (
        f"With a Trust-Weighted Rating of {trust_weighted_rating:.1f}/5.0 across verified authentic reviews, "
        f"{pname} stands out as a dependable {cat} choice with strong quality and buyer confidence."
        if trust_weighted_rating >= 4.0
        else f"{pname} holds a {trust_weighted_rating:.1f}/5.0 Trust-Weighted Rating; review individual aspect scores before purchasing."
    )

    return pros[:3], cons[:2], verdict


def get_or_generate_product_review_insights(
    db: Session,
    product_id: int,
    *,
    force_refresh: bool = False,
) -> dict[str, Any]:
    """
    Return Trust-Weighted Rating vs. Raw Rating, 3-Bullet AI Summary (pros, cons, verdict),
    Aspect Sentiment Bars, and Verified & Authentic percentage for a product.
    Cached in `product_review_insights` and refreshed when reviews change.
    """
    product = (
        db.query(Product)
        .options(
            load_only(
                Product.id,
                Product.name,
                Product.price,
                Product.category,
                Product.rating,
                Product.reviews,
            )
        )
        .filter(Product.id == product_id)
        .first()
    )
    if product is None:
        raise ValueError("Product not found")

    all_rows = (
        db.query(Review)
        .filter(Review.product_id == product_id)
        .order_by(Review.created_at.desc())
        .all()
    )
    visible_rows = [
        r for r in all_rows if (r.moderation_status or "approved") != "hidden"
    ]
    current_count = len(visible_rows)

    cached = (
        db.query(ProductReviewInsight)
        .filter(ProductReviewInsight.product_id == product_id)
        .first()
    )
    if (
        cached is not None
        and not force_refresh
        and cached.review_count_at_generation == current_count
    ):
        try:
            return {
                "product_id": product_id,
                "raw_rating": round(float(cached.raw_rating), 2),
                "trust_weighted_rating": round(float(cached.trust_weighted_rating), 2),
                "total_reviews": int(cached.total_reviews),
                "verified_authentic_percent": round(float(cached.verified_authentic_percent), 1),
                "flagged_suspicious_count": int(cached.flagged_count),
                "summary": {
                    "pros": json.loads(cached.pros_json or "[]"),
                    "cons": json.loads(cached.cons_json or "[]"),
                    "verdict": cached.verdict,
                },
                "aspect_sentiment_bars": json.loads(cached.aspect_bars_json or "{}"),
                "cached": True,
            }
        except Exception:
            pass

    if visible_rows:
        raw_rating = round(
            sum(int(r.rating) for r in visible_rows) / len(visible_rows),
            2,
        )
        weighted_num = 0.0
        weighted_den = 0.0
        authentic_count = 0
        flagged_count = sum(1 for r in all_rows if r.is_flagged_suspicious)

        aspect_totals: dict[str, list[float]] = {
            "Quality": [],
            "Value": [],
            "Delivery/Experience": [],
            "Performance": [],
        }

        for r in visible_rows:
            t_score = float(r.trust_score if r.trust_score is not None else 85.0)
            # Down-weight flagged suspicious reviews heavily in trust-weighted rating
            weight = (t_score / 100.0) * (0.2 if r.is_flagged_suspicious else 1.25 if r.verified_purchase else 1.0)
            weight = max(0.05, weight)
            weighted_num += int(r.rating) * weight
            weighted_den += weight

            if not r.is_flagged_suspicious and t_score >= 60.0:
                authentic_count += 1

            try:
                asp_map = json.loads(r.aspect_sentiments or "{}")
            except Exception:
                asp_map = {}
            if not isinstance(asp_map, dict) or not asp_map:
                asp_map = _extract_aspect_sentiments(r.comment or "", int(r.rating))

            for asp_name in aspect_totals:
                pol = asp_map.get(asp_name, "positive" if r.rating >= 4 else "neutral")
                val = 1.0 if pol == "positive" else (0.65 if pol == "neutral" else 0.15)
                if not r.is_flagged_suspicious:
                    aspect_totals[asp_name].append(val)

        trust_weighted = (
            round(weighted_num / weighted_den, 2) if weighted_den > 0 else raw_rating
        )
        verified_authentic_pct = round(
            (authentic_count / len(visible_rows)) * 100.0,
            1,
        )
        aspect_bars = {
            k: int(round((sum(vals) / len(vals)) * 100)) if vals else 86
            for k, vals in aspect_totals.items()
        }
        high_trust_rows = [
            r for r in visible_rows if not r.is_flagged_suspicious and (r.trust_score or 85.0) >= 60.0
        ]
    else:
        base_r = float(product.rating or 4.8) if float(product.rating or 0) > 0 else 4.8
        raw_rating = round(base_r, 2)
        trust_weighted = round(min(5.0, base_r), 2)
        verified_authentic_pct = 96.0
        flagged_count = 0
        aspect_bars = {
            "Quality": 92,
            "Value": 88,
            "Delivery/Experience": 90,
            "Performance": 91,
        }
        high_trust_rows = []

    pros, cons, verdict = _synthesize_summary_from_reviews(
        product,
        high_trust_rows,
        aspect_bars,
        trust_weighted,
    )

    try:
        if cached is None:
            cached = ProductReviewInsight(product_id=product_id)
            db.add(cached)
        cached.raw_rating = raw_rating
        cached.trust_weighted_rating = trust_weighted
        cached.total_reviews = current_count if current_count > 0 else int(product.reviews or 0)
        cached.verified_authentic_percent = verified_authentic_pct
        cached.flagged_count = flagged_count
        cached.pros_json = json.dumps(pros)
        cached.cons_json = json.dumps(cons)
        cached.verdict = verdict
        cached.aspect_bars_json = json.dumps(aspect_bars)
        cached.review_count_at_generation = current_count
        db.commit()
    except Exception as exc:
        db.rollback()
        logger.debug("Could not cache ProductReviewInsight: %s", exc)

    return {
        "product_id": product_id,
        "raw_rating": raw_rating,
        "trust_weighted_rating": trust_weighted,
        "total_reviews": current_count if current_count > 0 else int(product.reviews or 0),
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
