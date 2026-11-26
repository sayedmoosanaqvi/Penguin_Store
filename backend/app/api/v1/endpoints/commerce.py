"""User-centered e-commerce endpoints: Reviews (CRUD + Helpful Votes + Grounded Trust),
Wishlists/Favorites, Recently Viewed, Addresses & Smart Alerts."""

from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from threading import Lock
from typing import Any, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel
from sqlalchemy import func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, load_only

from app.core.concurrency import BoundedLRUDict, KeyedLockPool, global_single_flight
from app.core.database import get_db
from app.core.security import get_current_user, get_optional_current_user, resolve_user_role
from app.models import (
    Notification,
    Order,
    OrderItem,
    Product,
    RecentlyViewedItem,
    Review,
    User,
    UserAddress,
    WishlistItem,
)
from app.repositories.product_repo import PRODUCT_PUBLIC_COLUMNS
from app.schemas.commerce import AddressCreate, ReviewCreate, ReviewUpdate, WishlistToggleRequest
from app.services.review_trust_service import (
    evaluate_review_trust,
    format_human_trust_reasons,
    get_or_generate_product_review_insights,
    invalidate_product_review_insights,
)

logger = logging.getLogger(__name__)
router = APIRouter(tags=["User Commerce v1"])

_HELPFUL_LOCK = Lock()
# review_id -> set of user_ids (synced with Supabase `review_helpful_votes` when available)
_HELPFUL_VOTES_MEM: BoundedLRUDict[set[int]] = BoundedLRUDict(max_size=1024)
_HAS_HELPFUL_TABLE: Optional[bool] = None


def _mask_email(email: str) -> str:
    clean = (email or "").strip()
    if "@" not in clean:
        return "Customer"
    local, domain = clean.split("@", 1)
    prefix = local[:2] if len(local) >= 2 else local[:1]
    return f"{prefix}***@{domain}"


def _serialize_public_product(p: Product) -> dict:
    return {
        "id": p.id,
        "name": p.name,
        "description": p.description or "",
        "price": float(p.price),
        "original_price": float(p.original_price) if p.original_price is not None else None,
        "image_url": p.image_url,
        "category": p.category,
        "rating": float(p.rating or 0.0),
        "reviews": int(p.reviews or 0),
        "discount_percent": p.discount_percent,
        "is_featured": bool(p.is_featured),
    }


def _parse_json_safe(raw: str | None, default: object):
    if not raw:
        return default
    try:
        return json.loads(raw)
    except Exception:
        return default


# ---------------------------------------------------------------------------
# 1. PRODUCT REVIEWS, VERIFIED PURCHASE, HELPFUL VOTES & AI TRUST INSIGHTS
# ---------------------------------------------------------------------------

def _load_helpful_voters(review_ids: list[int]) -> dict[int, set[int]]:
    """Load helpful voter sets per review from Supabase `review_helpful_votes` + memory."""
    global _HAS_HELPFUL_TABLE
    if not review_ids:
        return {}

    out: dict[int, set[int]] = {}
    for rid in review_ids:
        mem_set = _HELPFUL_VOTES_MEM.get(int(rid))
        out[int(rid)] = set(mem_set) if mem_set else set()

    if _HAS_HELPFUL_TABLE is not False:
        try:
            from app.core.supabase_rest import get_supabase_client

            res = (
                get_supabase_client()
                .table("review_helpful_votes")
                .select("review_id,user_id")
                .in_("review_id", [int(x) for x in review_ids])
                .execute()
            )
            _HAS_HELPFUL_TABLE = True
            for row in res.data or []:
                rid = int(row.get("review_id") or 0)
                uid = int(row.get("user_id") or 0)
                if rid > 0 and uid > 0:
                    out.setdefault(rid, set()).add(uid)
            for rid, u_set in out.items():
                _HELPFUL_VOTES_MEM.set(rid, set(u_set))
        except Exception as exc:
            err_l = str(exc).lower()
            if "review_helpful_votes" in err_l or "pgrst205" in err_l or "42p01" in err_l:
                _HAS_HELPFUL_TABLE = False
    return out


def _check_verified_purchase(db: Optional[Session], user_email: str, product_id: int) -> bool:
    """
    Award `verified_purchase = True` ONLY when the customer has a real paid/confirmed
    order containing `product_id` (excludes unpaid pending Stripe checkouts & cancelled orders).
    """
    clean_email = (user_email or "").strip().lower()
    pid = int(product_id)
    if not clean_email or pid <= 0:
        return False

    disallowed_payment = {"pending", "cancelled", "canceled", "failed", "refunded"}
    disallowed_dispatch = {"CANCELLED", "CANCELED"}

    # 1. Check in-memory recent session orders (`orders.py`)
    try:
        from app.routers.orders import _MEM_ORDERS, _MEM_ORDERS_LOCK

        with _MEM_ORDERS_LOCK:
            for ord_rec in _MEM_ORDERS:
                if str(ord_rec.get("customer_email") or "").strip().lower() != clean_email:
                    continue
                pay_st = str(ord_rec.get("payment_status") or "").strip().lower()
                if pay_st in disallowed_payment:
                    continue
                for item in ord_rec.get("items") or []:
                    if int(item.get("product_id") or 0) == pid:
                        disp = str(item.get("dispatch_status") or "").strip().upper()
                        if disp not in disallowed_dispatch:
                            return True
    except Exception:
        pass

    # 2. Check Supabase HTTPS `orders` + `order_items` (inspects payment_status column cleanly)
    try:
        from app.core.supabase_rest import get_supabase_client

        client = get_supabase_client()
        ord_res = (
            client.table("orders")
            .select("*")
            .ilike("customer_email", clean_email)
            .order("id", desc=True)
            .limit(50)
            .execute()
        )
        valid_order_ids: list[int] = []
        for o in ord_res.data or []:
            if not isinstance(o, dict) or not o.get("id"):
                continue
            pay_status = str(o.get("payment_status") or "cod_confirmed").strip().lower()
            if pay_status not in disallowed_payment:
                valid_order_ids.append(int(o["id"]))

        if valid_order_ids:
            it_res = (
                client.table("order_items")
                .select("id,dispatch_status")
                .in_("order_id", valid_order_ids)
                .eq("product_id", pid)
                .execute()
            )
            for it in it_res.data or []:
                disp = str(it.get("dispatch_status") or "QUEUED_FOR_PACKING").strip().upper()
                if disp not in disallowed_dispatch:
                    return True
    except Exception:
        pass

    # 3. Fallback SQLAlchemy join check
    if db is not None:
        try:
            row = (
                db.query(OrderItem.dispatch_status)
                .join(Order, OrderItem.order_id == Order.id)
                .filter(
                    func.lower(Order.customer_email) == clean_email,
                    OrderItem.product_id == pid,
                )
                .first()
            )
            if row is not None and str(row[0] or "").upper() not in disallowed_dispatch:
                return True
        except Exception:
            pass

    return False


def _recompute_product_review_aggregates(db: Session, product_id: int) -> tuple[float, int]:
    """Synchronize `products.rating` and `products.reviews` strictly from visible DB reviews."""
    from app.core.supabase_rest import get_supabase_client, invalidate_supabase_rest_cache

    agg_rows = (
        db.query(Review.rating, Review.moderation_status)
        .filter(Review.product_id == int(product_id))
        .all()
    )
    visible_ratings = [
        int(r[0]) for r in agg_rows if (r[1] or "approved") != "hidden"
    ]
    new_count = len(visible_ratings)
    new_avg = round(sum(visible_ratings) / new_count, 2) if new_count > 0 else 0.0

    prod = (
        db.query(Product)
        .options(load_only(Product.id, Product.rating, Product.reviews))
        .filter(Product.id == int(product_id))
        .first()
    )
    if prod is not None:
        prod.reviews = new_count
        prod.rating = new_avg
        db.flush()

    try:
        get_supabase_client().table("products").update(
            {"rating": new_avg, "reviews": new_count}
        ).eq("id", int(product_id)).execute()
    except Exception:
        pass

    invalidate_product_review_insights(db, int(product_id))
    invalidate_supabase_rest_cache()
    return new_avg, new_count


def _serialize_review_row(
    r: Any,
    *,
    helpful_voters: set[int],
    viewer_user_id: Optional[int],
) -> dict[str, Any]:
    rid = int(getattr(r, "id", 0) or 0)
    uid = int(getattr(r, "user_id", 0) or 0)
    t_score = round(float(getattr(r, "trust_score", None) or 85.0), 1)
    is_susp = bool(getattr(r, "is_flagged_suspicious", False))
    is_ver = bool(getattr(r, "verified_purchase", False))
    flags_raw = getattr(r, "trust_flags", "[]")
    flags = flags_raw if isinstance(flags_raw, list) else _parse_json_safe(flags_raw, [])
    if not isinstance(flags, list):
        flags = []

    asp_raw = getattr(r, "aspect_sentiments", "{}")
    asp_parsed = asp_raw if isinstance(asp_raw, dict) else _parse_json_safe(asp_raw, {})
    if not isinstance(asp_parsed, dict):
        asp_parsed = {}

    tags: list[str] = []
    if isinstance(asp_parsed.get("_tags"), list):
        tags = [str(x) for x in asp_parsed["_tags"] if str(x).strip()]
    clean_aspects = {
        k: str(v) for k, v in asp_parsed.items() if not str(k).startswith("_")
    }

    comment_txt = str(getattr(r, "comment", "") or "")
    trust_reasons = format_human_trust_reasons(
        verified_purchase=is_ver,
        trust_score=t_score,
        is_flagged_suspicious=is_susp,
        trust_flags=[str(f) for f in flags],
        comment=comment_txt,
    )

    created_val = getattr(r, "created_at", None)
    created_iso = (
        created_val.isoformat()
        if hasattr(created_val, "isoformat")
        else (str(created_val) if created_val else None)
    )
    updated_val = getattr(r, "updated_at", None)
    updated_iso = (
        updated_val.isoformat()
        if hasattr(updated_val, "isoformat")
        else (str(updated_val) if updated_val else None)
    )

    return {
        "id": rid,
        "author": _mask_email(str(getattr(r, "user_email", "") or "")),
        "rating": int(getattr(r, "rating", 5) or 5),
        "title": str(getattr(r, "title", "") or ""),
        "comment": comment_txt,
        "tags": tags,
        "verified_purchase": is_ver,
        "helpful_count": len(helpful_voters),
        "viewer_voted_helpful": bool(viewer_user_id is not None and int(viewer_user_id) in helpful_voters),
        "is_own_review": bool(viewer_user_id is not None and uid == int(viewer_user_id)),
        "trust_score": t_score,
        "trust_reasons": trust_reasons,
        "is_flagged_suspicious": is_susp,
        "trust_flags": flags,
        "aspect_sentiments": clean_aspects,
        "moderation_status": str(getattr(r, "moderation_status", None) or "approved"),
        "created_at": created_iso,
        "updated_at": updated_iso,
    }


@router.get("/products/{product_id}/reviews")
def list_product_reviews(
    product_id: int,
    sort: str = Query(default="most_helpful", max_length=32),
    verified_only: bool = Query(default=False),
    star_filter: Optional[int] = Query(default=None, ge=1, le=5),
    db: Session = Depends(get_db),
    current_user: Optional[User] = Depends(get_optional_current_user),
):
    from app.core.supabase_rest import fetch_product_by_id_https, get_supabase_client

    prod = fetch_product_by_id_https(product_id)
    if prod is None:
        exists = db.query(Product.id).filter(Product.id == product_id).first()
        if exists is None:
            raise HTTPException(status_code=404, detail="Product not found.")

    try:
        all_rows: list[Any] = (
            db.query(Review)
            .filter(Review.product_id == product_id)
            .order_by(Review.created_at.desc())
            .all()
        )
    except Exception:
        from types import SimpleNamespace

        res = (
            get_supabase_client()
            .table("reviews")
            .select("*")
            .eq("product_id", int(product_id))
            .order("created_at", desc=True)
            .execute()
        )
        all_rows = [SimpleNamespace(**r) for r in (res.data or []) if isinstance(r, dict)]

    visible_rows = [
        r for r in all_rows if (getattr(r, "moderation_status", None) or "approved") != "hidden"
    ]

    dist = {"5": 0, "4": 0, "3": 0, "2": 0, "1": 0}
    total_score = 0
    weighted_num = 0.0
    weighted_den = 0.0
    verified_count = 0

    for r in visible_rows:
        rating_int = max(1, min(5, int(getattr(r, "rating", 5) or 5)))
        dist[str(rating_int)] += 1
        total_score += rating_int
        is_ver = bool(getattr(r, "verified_purchase", False))
        if is_ver:
            verified_count += 1
        t_score = float(getattr(r, "trust_score", None) or 85.0)
        flagged = bool(getattr(r, "is_flagged_suspicious", False))
        w = max(0.05, (t_score / 100.0) * (0.2 if flagged else (1.30 if is_ver else 1.0)))
        weighted_num += rating_int * w
        weighted_den += w

    count = len(visible_rows)
    avg = round(total_score / count, 2) if count > 0 else 0.0
    trust_weighted = round(weighted_num / weighted_den, 2) if (count > 0 and weighted_den > 0) else 0.0

    helpful_map = _load_helpful_voters([int(getattr(r, "id", 0) or 0) for r in visible_rows])
    viewer_id = current_user.id if current_user is not None else None

    serialized_all = [
        _serialize_review_row(
            r,
            helpful_voters=helpful_map.get(int(getattr(r, "id", 0) or 0), set()),
            viewer_user_id=viewer_id,
        )
        for r in visible_rows
    ]

    my_review = next((item for item in serialized_all if item["is_own_review"]), None)

    # Apply interactive user filters
    filtered = serialized_all
    if verified_only:
        filtered = [x for x in filtered if x["verified_purchase"]]
    if star_filter is not None:
        filtered = [x for x in filtered if x["rating"] == int(star_filter)]

    # Apply interactive sort order
    sort_key = (sort or "most_helpful").strip().lower()
    if sort_key == "highest_trust":
        filtered.sort(
            key=lambda x: (
                0 if x["is_flagged_suspicious"] else 1,
                x["trust_score"],
                1 if x["verified_purchase"] else 0,
                x["helpful_count"],
            ),
            reverse=True,
        )
    elif sort_key in ("most_recent", "newest"):
        filtered.sort(key=lambda x: x["created_at"] or "", reverse=True)
    elif sort_key == "highest_rating":
        filtered.sort(key=lambda x: (x["rating"], x["trust_score"]), reverse=True)
    elif sort_key == "lowest_rating":
        filtered.sort(key=lambda x: (x["rating"], -x["trust_score"]))
    else:  # most_helpful (default)
        filtered.sort(
            key=lambda x: (
                x["helpful_count"],
                1 if x["verified_purchase"] else 0,
                x["trust_score"],
                x["created_at"] or "",
            ),
            reverse=True,
        )

    return {
        "product_id": product_id,
        "average_rating": avg,
        "trust_weighted_rating": trust_weighted,
        "total_reviews": count,
        "filtered_count": len(filtered),
        "verified_purchase_count": verified_count,
        "distribution": dist,
        "my_review": my_review,
        "reviews": filtered,
    }


@router.get("/products/{product_id}/review-insights")
async def get_product_review_insights_endpoint(
    product_id: int,
    refresh: bool = False,
):
    from app.core.database import SessionLocal
    from app.core.supabase_rest import fetch_product_by_id_https

    if fetch_product_by_id_https(product_id) is None:
        raise HTTPException(status_code=404, detail="Product not found.")

    def _compute_sync() -> dict[str, Any]:
        db = SessionLocal()
        try:
            return get_or_generate_product_review_insights(
                db,
                product_id,
                force_refresh=refresh,
            )
        except ValueError:
            raise HTTPException(status_code=404, detail="Product not found.")
        finally:
            db.close()

    if refresh:
        global_single_flight.invalidate_prefix(f"review_insights:{int(product_id)}")
        import asyncio
        return await asyncio.to_thread(_compute_sync)

    return await global_single_flight.get_or_load_sync(
        f"review_insights:{int(product_id)}",
        _compute_sync,
        ttl=60.0,
    )


@router.post("/products/{product_id}/reviews", status_code=status.HTTP_201_CREATED)
def submit_product_review(
    product_id: int,
    payload: ReviewCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    product = (
        db.query(Product)
        .options(load_only(Product.id, Product.name, Product.rating, Product.reviews, Product.price, Product.category))
        .filter(Product.id == product_id)
        .first()
    )
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found.")

    duplicate = (
        db.query(Review.id)
        .filter(Review.product_id == product_id, Review.user_id == current_user.id)
        .first()
    )
    if duplicate is not None:
        raise HTTPException(
            status_code=409,
            detail="You have already reviewed this product. You can edit or update your existing review.",
        )

    clean_email = current_user.email.strip().lower()
    is_verified = _check_verified_purchase(db, clean_email, product_id)

    trust_eval = evaluate_review_trust(
        db,
        product_id=product_id,
        user_id=current_user.id,
        user_email=clean_email,
        rating=payload.rating,
        title=payload.title.strip() if payload.title else None,
        comment=payload.comment.strip(),
        verified_purchase=is_verified,
        tags=payload.tags,
    )

    review = Review(
        product_id=product_id,
        user_id=current_user.id,
        user_email=clean_email,
        rating=payload.rating,
        title=payload.title.strip() if payload.title else None,
        comment=payload.comment.strip(),
        verified_purchase=is_verified,
        trust_score=trust_eval["trust_score"],
        is_flagged_suspicious=trust_eval["is_flagged_suspicious"],
        trust_flags=json.dumps(trust_eval["trust_flags"]),
        aspect_sentiments=json.dumps(trust_eval["aspect_sentiments"]),
        moderation_status=trust_eval["moderation_status"],
    )

    try:
        db.add(review)
        db.flush()
        new_avg, new_count = _recompute_product_review_aggregates(db, product_id)
        db.commit()
        db.refresh(review)
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=409,
            detail="You have already reviewed this product. You can edit or update your existing review.",
        )

    serialized = _serialize_review_row(
        review,
        helpful_voters=set(),
        viewer_user_id=current_user.id,
    )
    serialized["product_id"] = product_id
    serialized["average_rating"] = new_avg
    serialized["total_reviews"] = new_count
    return serialized


@router.put("/products/{product_id}/reviews/{review_id}")
def update_product_review(
    product_id: int,
    review_id: int,
    payload: ReviewUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    review = (
        db.query(Review)
        .filter(Review.id == review_id, Review.product_id == product_id)
        .first()
    )
    if review is None:
        raise HTTPException(status_code=404, detail="Review not found.")

    if review.user_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only edit your own review.",
        )

    clean_email = current_user.email.strip().lower()
    is_verified = bool(review.verified_purchase) or _check_verified_purchase(
        db, clean_email, product_id
    )

    trust_eval = evaluate_review_trust(
        db,
        product_id=product_id,
        user_id=current_user.id,
        user_email=clean_email,
        rating=payload.rating,
        title=payload.title.strip() if payload.title else None,
        comment=payload.comment.strip(),
        verified_purchase=is_verified,
        tags=payload.tags,
        exclude_review_id=review.id,
    )

    review.rating = payload.rating
    review.title = payload.title.strip() if payload.title else None
    review.comment = payload.comment.strip()
    review.verified_purchase = is_verified
    review.trust_score = trust_eval["trust_score"]
    review.is_flagged_suspicious = trust_eval["is_flagged_suspicious"]
    review.trust_flags = json.dumps(trust_eval["trust_flags"])
    review.aspect_sentiments = json.dumps(trust_eval["aspect_sentiments"])
    review.moderation_status = trust_eval["moderation_status"]
    review.updated_at = datetime.now(timezone.utc)

    db.flush()
    new_avg, new_count = _recompute_product_review_aggregates(db, product_id)
    db.commit()
    db.refresh(review)

    voters = _load_helpful_voters([review.id]).get(review.id, set())
    serialized = _serialize_review_row(
        review,
        helpful_voters=voters,
        viewer_user_id=current_user.id,
    )
    serialized["product_id"] = product_id
    serialized["average_rating"] = new_avg
    serialized["total_reviews"] = new_count
    return serialized


@router.delete("/products/{product_id}/reviews/{review_id}")
def delete_product_review(
    product_id: int,
    review_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    review = (
        db.query(Review)
        .filter(Review.id == review_id, Review.product_id == product_id)
        .first()
    )
    if review is None:
        raise HTTPException(status_code=404, detail="Review not found.")

    is_admin = resolve_user_role(current_user) == "admin"
    if review.user_id != current_user.id and not is_admin:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only delete your own review.",
        )

    db.delete(review)
    db.flush()
    new_avg, new_count = _recompute_product_review_aggregates(db, product_id)
    db.commit()
    _HELPFUL_VOTES_MEM.pop(review_id, None)

    return {
        "deleted": True,
        "review_id": review_id,
        "product_id": product_id,
        "average_rating": new_avg,
        "total_reviews": new_count,
    }


@router.post("/reviews/{review_id}/helpful")
def toggle_review_helpful(
    review_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Idempotent 1-vote-per-user helpfulness toggle persisted in Supabase + memory."""
    global _HAS_HELPFUL_TABLE
    exists = db.query(Review.id).filter(Review.id == review_id).first()
    if exists is None:
        raise HTTPException(status_code=404, detail="Review not found.")

    uid = int(current_user.id)
    rid = int(review_id)

    with _HELPFUL_LOCK:
        voters = set(_load_helpful_voters([rid]).get(rid, set()))
        already_voted = uid in voters

        if already_voted:
            voters.discard(uid)
            voted_now = False
        else:
            voters.add(uid)
            voted_now = True

        _HELPFUL_VOTES_MEM.set(rid, set(voters))

        if _HAS_HELPFUL_TABLE is not False:
            try:
                from app.core.supabase_rest import get_supabase_client

                client = get_supabase_client()
                if voted_now:
                    client.table("review_helpful_votes").upsert(
                        {"review_id": rid, "user_id": uid},
                        on_conflict="review_id,user_id",
                    ).execute()
                else:
                    client.table("review_helpful_votes").delete().eq(
                        "review_id", rid
                    ).eq("user_id", uid).execute()
                _HAS_HELPFUL_TABLE = True
            except Exception as exc:
                err_l = str(exc).lower()
                if "review_helpful_votes" in err_l or "pgrst205" in err_l or "42p01" in err_l:
                    _HAS_HELPFUL_TABLE = False

        final_count = len(voters)

    return {
        "review_id": rid,
        "helpful": voted_now,
        "helpful_count": final_count,
    }


# ---------------------------------------------------------------------------
# 2. WISHLIST / FAVORITES (Synced with live Supabase `wishlists` + Bounded LRU)
# ---------------------------------------------------------------------------

_FAV_LOCK_POOL = KeyedLockPool(64)
_MEM_FAVORITES_BY_USER: BoundedLRUDict[dict[int, float]] = BoundedLRUDict(max_size=512)


class FavoritesSyncRequest(BaseModel):
    product_ids: list[int] = []


def _get_user_favorites_map(user_id: int) -> dict[int, float]:
    """Load user favorites from live Supabase `wishlists` table + bounded LRU cache."""
    from app.core.supabase_rest import fetch_product_by_id_https, get_supabase_client

    uid = int(user_id)
    cached = _MEM_FAVORITES_BY_USER.get(uid)
    mem_map = dict(cached) if cached else {}

    try:
        client = get_supabase_client()
        res = (
            client.table("wishlists")
            .select("product_id,price_at_save")
            .eq("user_id", uid)
            .order("created_at", desc=True)
            .execute()
        )
        db_map: dict[int, float] = {}
        for row in res.data or []:
            pid = int(row.get("product_id") or 0)
            if pid > 0:
                p_save = row.get("price_at_save")
                if p_save is None:
                    p_dict = fetch_product_by_id_https(pid)
                    p_save = float((p_dict or {}).get("price") or 0.0)
                db_map[pid] = float(p_save)
        mem_map = db_map
    except Exception as exc:
        logger.debug("Supabase wishlists read fallback: %s", exc)

    _MEM_FAVORITES_BY_USER.set(uid, dict(mem_map))
    return mem_map


def _add_user_favorite(user_id: int, product_id: int) -> dict[str, object]:
    from app.core.supabase_rest import fetch_product_by_id_https, get_supabase_client

    uid = int(user_id)
    pid = int(product_id)
    prod = fetch_product_by_id_https(pid)
    if prod is None:
        raise HTTPException(status_code=404, detail="Product not found.")

    price = float(prod.get("price") or 0.0)
    with _FAV_LOCK_POOL.for_key(uid):
        cur = dict(_MEM_FAVORITES_BY_USER.get(uid) or {})
        cur[pid] = price
        _MEM_FAVORITES_BY_USER.set(uid, cur)

        try:
            get_supabase_client().table("wishlists").upsert(
                {
                    "user_id": uid,
                    "product_id": pid,
                    "price_at_save": price,
                },
                on_conflict="user_id,product_id",
            ).execute()
        except Exception as exc:
            logger.debug("Supabase wishlists upsert fallback: %s", exc)

    fav_map = _get_user_favorites_map(uid)
    return {"wishlisted": True, "product_ids": list(fav_map.keys())}


def _remove_user_favorite(user_id: int, product_id: int) -> dict[str, object]:
    from app.core.supabase_rest import get_supabase_client

    uid = int(user_id)
    pid = int(product_id)
    with _FAV_LOCK_POOL.for_key(uid):
        cur = dict(_MEM_FAVORITES_BY_USER.get(uid) or {})
        cur.pop(pid, None)
        _MEM_FAVORITES_BY_USER.set(uid, cur)

        try:
            get_supabase_client().table("wishlists").delete().eq("user_id", uid).eq(
                "product_id", pid
            ).execute()
        except Exception as exc:
            logger.debug("Supabase wishlists delete fallback: %s", exc)

    fav_map = _get_user_favorites_map(uid)
    return {"wishlisted": False, "product_ids": list(fav_map.keys())}


def _build_favorites_response(user_id: int) -> dict[str, object]:
    from app.core.supabase_rest import fetch_product_by_id_https

    fav_map = _get_user_favorites_map(user_id)
    items = []
    for pid, price_at_save in fav_map.items():
        p = fetch_product_by_id_https(pid)
        if p is None:
            continue
        cur_price = float(p.get("price") or 0.0)
        stock_cnt = int(p.get("stock") if p.get("stock") is not None else 50)
        item = dict(p)
        item["price_at_save"] = price_at_save
        item["price_dropped"] = price_at_save > 0 and cur_price < price_at_save
        item["in_stock"] = stock_cnt > 0
        items.append(item)

    return {
        "count": len(items),
        "product_ids": [int(i["id"]) for i in items],
        "items": items,
    }


@router.get("/wishlist/")
@router.get("/favorites")
def get_wishlist(
    current_user: User = Depends(get_current_user),
):
    return _build_favorites_response(current_user.id)


@router.post("/wishlist/toggle")
def toggle_wishlist(
    payload: WishlistToggleRequest,
    current_user: User = Depends(get_current_user),
):
    fav_map = _get_user_favorites_map(current_user.id)
    if int(payload.product_id) in fav_map:
        return _remove_user_favorite(current_user.id, int(payload.product_id))
    return _add_user_favorite(current_user.id, int(payload.product_id))


@router.post("/favorites/{product_id}")
def add_favorite_endpoint(
    product_id: int,
    current_user: User = Depends(get_current_user),
):
    return _add_user_favorite(current_user.id, product_id)


@router.delete("/favorites/{product_id}")
def remove_favorite_endpoint(
    product_id: int,
    current_user: User = Depends(get_current_user),
):
    return _remove_user_favorite(current_user.id, product_id)


@router.post("/favorites/sync")
def sync_guest_favorites(
    payload: FavoritesSyncRequest,
    current_user: User = Depends(get_current_user),
):
    for pid in payload.product_ids[:100]:
        if pid > 0:
            try:
                _add_user_favorite(current_user.id, int(pid))
            except Exception:
                pass
    return _build_favorites_response(current_user.id)


# ---------------------------------------------------------------------------
# 3. RECENTLY VIEWED PRODUCTS
# ---------------------------------------------------------------------------

@router.get("/recently-viewed/")
def get_recently_viewed(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    rows = (
        db.query(RecentlyViewedItem, Product)
        .join(Product, Product.id == RecentlyViewedItem.product_id)
        .options(load_only(*PRODUCT_PUBLIC_COLUMNS))
        .filter(RecentlyViewedItem.user_id == current_user.id)
        .order_by(RecentlyViewedItem.viewed_at.desc())
        .limit(12)
        .all()
    )
    return {"items": [_serialize_public_product(p) for _, p in rows]}


@router.post("/recently-viewed/{product_id}")
def record_recently_viewed(
    product_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    exists = db.query(Product.id).filter(Product.id == product_id).first()
    if exists is None:
        raise HTTPException(status_code=404, detail="Product not found.")

    existing = (
        db.query(RecentlyViewedItem)
        .filter(
            RecentlyViewedItem.user_id == current_user.id,
            RecentlyViewedItem.product_id == product_id,
        )
        .first()
    )
    if existing is not None:
        existing.viewed_at = datetime.now(timezone.utc)
    else:
        db.add(RecentlyViewedItem(user_id=current_user.id, product_id=product_id))
    db.commit()
    return {"status": "recorded"}


# ---------------------------------------------------------------------------
# 4. SAVED SHIPPING ADDRESSES
# ---------------------------------------------------------------------------

@router.get("/addresses/")
def list_addresses(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    rows = (
        db.query(UserAddress)
        .filter(UserAddress.user_id == current_user.id)
        .order_by(UserAddress.is_default.desc(), UserAddress.id.desc())
        .all()
    )
    return {
        "addresses": [
            {
                "id": a.id,
                "label": a.label,
                "recipient_name": a.recipient_name,
                "phone": a.phone or "",
                "street_address": a.street_address,
                "city": a.city,
                "state_province": a.state_province,
                "country": a.country,
                "postal_code": a.postal_code,
                "is_default": bool(a.is_default),
            }
            for a in rows
        ]
    }


@router.post("/addresses/", status_code=status.HTTP_201_CREATED)
def add_address(
    payload: AddressCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    if payload.is_default:
        db.query(UserAddress).filter(UserAddress.user_id == current_user.id).update(
            {"is_default": False},
            synchronize_session=False,
        )

    addr = UserAddress(
        user_id=current_user.id,
        label=payload.label.strip(),
        recipient_name=payload.recipient_name.strip(),
        phone=payload.phone.strip() if payload.phone else None,
        street_address=payload.street_address.strip(),
        city=payload.city.strip(),
        state_province=payload.state_province.strip(),
        country=payload.country.strip(),
        postal_code=payload.postal_code.strip(),
        is_default=payload.is_default,
    )
    db.add(addr)
    db.commit()
    db.refresh(addr)

    return {
        "id": addr.id,
        "label": addr.label,
        "recipient_name": addr.recipient_name,
        "phone": addr.phone or "",
        "street_address": addr.street_address,
        "city": addr.city,
        "state_province": addr.state_province,
        "country": addr.country,
        "postal_code": addr.postal_code,
        "is_default": bool(addr.is_default),
    }


@router.delete("/addresses/{address_id}")
def delete_address(
    address_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    addr = (
        db.query(UserAddress)
        .filter(UserAddress.id == address_id, UserAddress.user_id == current_user.id)
        .first()
    )
    if addr is None:
        raise HTTPException(status_code=404, detail="Address not found.")
    db.delete(addr)
    db.commit()
    return {"deleted": True, "id": address_id}


# ---------------------------------------------------------------------------
# 5. SMART ENGAGEMENT NOTIFICATION GENERATOR (Price Drop & Review Reminders)
# ---------------------------------------------------------------------------

@router.post("/notifications/check-smart")
def generate_smart_notifications(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Creates non-duplicate price-drop and post-delivery review alerts for the user."""
    email = current_user.email.strip().lower()
    created = 0

    existing_titles = {
        row[0]
        for row in db.query(Notification.title)
        .filter(func.lower(Notification.customer_email) == email)
        .all()
    }

    wish_rows = (
        db.query(WishlistItem, Product.name, Product.price)
        .join(Product, Product.id == WishlistItem.product_id)
        .filter(WishlistItem.user_id == current_user.id)
        .all()
    )
    for w, pname, cur_price in wish_rows:
        if w.price_at_save is not None and float(cur_price) < float(w.price_at_save):
            title = f"Price Drop: {pname}"
            if title not in existing_titles:
                db.add(
                    Notification(
                        customer_email=email,
                        title=title,
                        message=(
                            f"Good news! '{pname}' in your wishlist dropped "
                            f"from ${w.price_at_save:.2f} to ${float(cur_price):.2f}."
                        ),
                        notification_type="PRICE_DROP",
                        category="PRICE_DROP",
                        action_route=f"/product/{w.product_id}",
                    )
                )
                existing_titles.add(title)
                created += 1

    reviewed_pids = {
        r[0]
        for r in db.query(Review.product_id)
        .filter(Review.user_id == current_user.id)
        .all()
    }
    ordered_rows = (
        db.query(OrderItem.product_id, Product.name, OrderItem.dispatch_status)
        .join(Order, Order.id == OrderItem.order_id)
        .join(Product, Product.id == OrderItem.product_id)
        .filter(func.lower(Order.customer_email) == email)
        .limit(5)
        .all()
    )
    for pid, pname, d_status in ordered_rows:
        if pid not in reviewed_pids and str(d_status).upper() in (
            "DELIVERED",
            "DISPATCHED",
            "SHIPPED",
        ):
            title = f"Review Reminder: {pname}"
            if title not in existing_titles:
                db.add(
                    Notification(
                        customer_email=email,
                        title=title,
                        message=f"How was your '{pname}'? Share a verified buyer rating & review!",
                        notification_type="REVIEW",
                        category="REVIEW_REMINDER",
                        action_route=f"/product/{pid}",
                    )
                )
                existing_titles.add(title)
                created += 1

    if created > 0:
        db.commit()

    return {"created_notifications": created}
