"""User-centered e-commerce endpoints: Reviews, Wishlists, Recently Viewed, Addresses & Smart Alerts."""

from __future__ import annotations

import json
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, load_only

from app.core.database import get_db
from app.core.security import get_current_user
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
from app.schemas.commerce import AddressCreate, ReviewCreate, WishlistToggleRequest
from app.services.review_trust_service import (
    evaluate_review_trust,
    get_or_generate_product_review_insights,
)

router = APIRouter(tags=["User Commerce v1"])


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


# ---------------------------------------------------------------------------
# 1. PRODUCT REVIEWS, TRUST SCORING & AI REVIEW INSIGHTS
# ---------------------------------------------------------------------------

def _parse_json_safe(raw: str | None, default: object):
    if not raw:
        return default
    try:
        return json.loads(raw)
    except Exception:
        return default


@router.get("/products/{product_id}/reviews")
def list_product_reviews(
    product_id: int,
    db: Session = Depends(get_db),
):
    exists = db.query(Product.id).filter(Product.id == product_id).first()
    if exists is None:
        raise HTTPException(status_code=404, detail="Product not found.")

    all_rows = (
        db.query(Review)
        .filter(Review.product_id == product_id)
        .order_by(Review.created_at.desc())
        .all()
    )
    rows = [
        r for r in all_rows if (getattr(r, "moderation_status", None) or "approved") != "hidden"
    ]

    dist = {"5": 0, "4": 0, "3": 0, "2": 0, "1": 0}
    total_score = 0
    weighted_num = 0.0
    weighted_den = 0.0
    for r in rows:
        k = str(max(1, min(5, int(r.rating))))
        dist[k] += 1
        total_score += int(r.rating)
        t_score = float(getattr(r, "trust_score", None) or 85.0)
        flagged = bool(getattr(r, "is_flagged_suspicious", False))
        w = max(0.05, (t_score / 100.0) * (0.2 if flagged else (1.25 if r.verified_purchase else 1.0)))
        weighted_num += int(r.rating) * w
        weighted_den += w

    count = len(rows)
    avg = round(total_score / count, 2) if count > 0 else 0.0
    trust_weighted = round(weighted_num / weighted_den, 2) if weighted_den > 0 else avg

    return {
        "product_id": product_id,
        "average_rating": avg,
        "trust_weighted_rating": trust_weighted,
        "total_reviews": count,
        "distribution": dist,
        "reviews": [
            {
                "id": r.id,
                "author": _mask_email(r.user_email),
                "rating": r.rating,
                "title": r.title or "",
                "comment": r.comment,
                "verified_purchase": bool(r.verified_purchase),
                "trust_score": round(float(getattr(r, "trust_score", None) or 85.0), 1),
                "is_flagged_suspicious": bool(getattr(r, "is_flagged_suspicious", False)),
                "trust_flags": _parse_json_safe(getattr(r, "trust_flags", "[]"), []),
                "aspect_sentiments": _parse_json_safe(getattr(r, "aspect_sentiments", "{}"), {}),
                "moderation_status": getattr(r, "moderation_status", None) or "approved",
                "created_at": r.created_at.isoformat() if r.created_at else None,
            }
            for r in rows
        ],
    }


@router.get("/products/{product_id}/review-insights")
def get_product_review_insights_endpoint(
    product_id: int,
    refresh: bool = False,
    db: Session = Depends(get_db),
):
    exists = db.query(Product.id).filter(Product.id == product_id).first()
    if exists is None:
        raise HTTPException(status_code=404, detail="Product not found.")

    return get_or_generate_product_review_insights(
        db,
        product_id,
        force_refresh=refresh,
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
            detail="You have already submitted a review for this product.",
        )

    # Check if customer actually ordered this product for Verified Buyer badge
    clean_email = current_user.email.strip().lower()
    verified_row = (
        db.query(OrderItem.id)
        .join(Order, OrderItem.order_id == Order.id)
        .filter(
            func.lower(Order.customer_email) == clean_email,
            OrderItem.product_id == product_id,
        )
        .first()
    )
    is_verified = verified_row is not None

    trust_eval = evaluate_review_trust(
        db,
        product_id=product_id,
        user_id=current_user.id,
        user_email=clean_email,
        rating=payload.rating,
        title=payload.title.strip() if payload.title else None,
        comment=payload.comment.strip(),
        verified_purchase=is_verified,
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

        # Recompute aggregates excluding hidden spam reviews
        agg_rows = (
            db.query(Review.rating, Review.moderation_status)
            .filter(Review.product_id == product_id)
            .all()
        )
        visible_ratings = [
            r[0] for r in agg_rows if (r[1] or "approved") != "hidden"
        ]
        if visible_ratings:
            product.reviews = len(visible_ratings)
            product.rating = round(sum(visible_ratings) / len(visible_ratings), 2)

        db.commit()
        db.refresh(review)
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=409,
            detail="You have already submitted a review for this product.",
        )

    return {
        "id": review.id,
        "product_id": product_id,
        "author": _mask_email(review.user_email),
        "rating": review.rating,
        "title": review.title or "",
        "comment": review.comment,
        "verified_purchase": bool(review.verified_purchase),
        "trust_score": review.trust_score,
        "is_flagged_suspicious": bool(review.is_flagged_suspicious),
        "trust_flags": trust_eval["trust_flags"],
        "aspect_sentiments": trust_eval["aspect_sentiments"],
        "moderation_status": review.moderation_status,
        "average_rating": product.rating,
        "total_reviews": product.reviews,
        "created_at": review.created_at.isoformat() if review.created_at else None,
    }


# ---------------------------------------------------------------------------
# 2. WISHLIST / FAVORITES
# ---------------------------------------------------------------------------

@router.get("/wishlist/")
def get_wishlist(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    rows = (
        db.query(WishlistItem, Product)
        .join(Product, Product.id == WishlistItem.product_id)
        .options(load_only(*PRODUCT_PUBLIC_COLUMNS, Product.stock))
        .filter(WishlistItem.user_id == current_user.id)
        .order_by(WishlistItem.created_at.desc())
        .all()
    )

    items = []
    for w, p in rows:
        item = _serialize_public_product(p)
        item["price_at_save"] = w.price_at_save
        item["price_dropped"] = (
            w.price_at_save is not None and float(p.price) < float(w.price_at_save)
        )
        item["in_stock"] = (p.stock or 0) > 0
        items.append(item)

    return {
        "count": len(items),
        "product_ids": [i["id"] for i in items],
        "items": items,
    }


@router.post("/wishlist/toggle")
def toggle_wishlist(
    payload: WishlistToggleRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    product = (
        db.query(Product.id, Product.price)
        .filter(Product.id == payload.product_id)
        .first()
    )
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found.")

    existing = (
        db.query(WishlistItem)
        .filter(
            WishlistItem.user_id == current_user.id,
            WishlistItem.product_id == payload.product_id,
        )
        .first()
    )

    if existing is not None:
        db.delete(existing)
        db.commit()
        wishlisted = False
    else:
        db.add(
            WishlistItem(
                user_id=current_user.id,
                product_id=payload.product_id,
                price_at_save=float(product.price),
            )
        )
        db.commit()
        wishlisted = True

    all_ids = [
        r[0]
        for r in db.query(WishlistItem.product_id)
        .filter(WishlistItem.user_id == current_user.id)
        .all()
    ]
    return {"wishlisted": wishlisted, "product_ids": all_ids}


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

    # A) Price drop alerts on wishlisted items
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

    # B) Review reminder for fulfilled orders that have no review from this user yet
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
