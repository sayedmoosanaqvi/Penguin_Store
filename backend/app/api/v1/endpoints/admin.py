"""Strict Admin & Supplier RBAC Operations Endpoints (/api/v1/admin)."""

from __future__ import annotations

import json
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session, load_only

from app.core.database import get_db
from app.core.security import require_role, resolve_user_role
from app.models import Notification, Order, OrderItem, Product, ProductReviewInsight, Review, User
from app.schemas.auth import UserRoleUpdate
from app.schemas.commerce import OrderStatusUpdateRequest
from app.services.ai_telemetry_service import (
    export_ai_metrics_csv,
    get_ai_metrics_summary,
)
from app.services.review_trust_service import get_or_generate_product_review_insights

router = APIRouter(prefix="/admin", tags=["Admin RBAC"])


class ReviewModerationRequest(BaseModel):
    action: Literal["approve", "hide", "flag"] = Field(
        ...,
        description="Moderation action: approve, hide, or flag",
    )


@router.get("/users")
def list_users_rbac(
    limit: int = Query(default=50, ge=1, le=200),
    db: Session = Depends(get_db),
    admin_user: User = Depends(require_role(["admin"])),
):
    rows = db.query(User).order_by(User.id.asc()).limit(limit).all()
    return {
        "count": len(rows),
        "users": [
            {
                "id": u.id,
                "email": u.email,
                "full_name": getattr(u, "full_name", None),
                "role": resolve_user_role(u),
                "is_admin": bool(u.is_admin),
                "is_active": bool(getattr(u, "is_active", True)),
            }
            for u in rows
        ],
    }


@router.patch("/users/{user_id}/role")
def update_user_role(
    user_id: int,
    payload: UserRoleUpdate,
    db: Session = Depends(get_db),
    admin_user: User = Depends(require_role(["admin"])),
):
    if user_id == admin_user.id and payload.role != "admin":
        raise HTTPException(
            status_code=400,
            detail="You cannot demote your own administrator role.",
        )

    target = db.query(User).filter(User.id == user_id).first()
    if target is None:
        raise HTTPException(status_code=404, detail="User not found.")

    target.role = payload.role
    target.is_admin = payload.role == "admin"
    db.commit()
    db.refresh(target)

    return {
        "id": target.id,
        "email": target.email,
        "role": resolve_user_role(target),
        "is_admin": bool(target.is_admin),
    }


@router.get("/orders")
def list_all_orders_admin(
    limit: int = Query(default=50, ge=1, le=200),
    db: Session = Depends(get_db),
    caller: User = Depends(require_role(["admin", "supplier"])),
):
    orders = (
        db.query(Order)
        .order_by(Order.created_at.desc())
        .limit(limit)
        .all()
    )
    return {
        "count": len(orders),
        "orders": [
            {
                "order_id": o.id,
                "customer_name": o.customer_name,
                "customer_email": o.customer_email,
                "city": o.city,
                "country": o.country,
                "total_amount": o.total_amount,
                "created_at": o.created_at.isoformat() if o.created_at else None,
                "items": [
                    {
                        "id": it.id,
                        "product_id": it.product_id,
                        "quantity": it.quantity,
                        "fulfillment_type": it.fulfillment_type,
                        "dispatch_status": it.dispatch_status,
                        "tracking_number": it.tracking_number,
                    }
                    for it in o.items
                ],
            }
            for o in orders
        ],
    }


@router.patch("/orders/{order_id}/status")
def update_order_dispatch_status(
    order_id: int,
    payload: OrderStatusUpdateRequest,
    db: Session = Depends(get_db),
    caller: User = Depends(require_role(["admin", "supplier"])),
):
    order = db.query(Order).filter(Order.id == order_id).first()
    if order is None:
        raise HTTPException(status_code=404, detail="Order not found.")

    for item in order.items:
        item.dispatch_status = payload.dispatch_status
        if payload.tracking_number is not None and payload.tracking_number.strip():
            item.tracking_number = payload.tracking_number.strip()

    status_label = payload.dispatch_status.replace("_", " ").title()
    notif = Notification(
        customer_email=order.customer_email.strip().lower(),
        title=f"Order #{order.id} Update: {status_label}",
        message=(
            f"Your order #{order.id} status is now {status_label}."
            + (
                f" Tracking: {payload.tracking_number.strip()}"
                if payload.tracking_number
                else ""
            )
        ),
        notification_type="ORDER",
        category="ORDER",
        action_route="/orders",
    )
    db.add(notif)
    db.commit()

    return {
        "status": "updated",
        "order_id": order.id,
        "dispatch_status": payload.dispatch_status,
        "updated_by": resolve_user_role(caller),
    }


# ---------------------------------------------------------------------------
# PHASE 1: ADMIN FAKE REVIEW MODERATION ENDPOINTS
# ---------------------------------------------------------------------------

def _safe_json_load(raw: str | None, fallback: object):
    if not raw:
        return fallback
    try:
        return json.loads(raw)
    except Exception:
        return fallback


@router.get("/reviews/moderation")
def list_reviews_for_moderation(
    flagged_only: bool = Query(default=False),
    limit: int = Query(default=100, ge=1, le=300),
    db: Session = Depends(get_db),
    admin_user: User = Depends(require_role(["admin"])),
):
    """Return reviews with AI trust score, suspicious flag, and breakdown reasons for Admin inspection."""
    q = (
        db.query(Review, Product.name)
        .outerjoin(Product, Product.id == Review.product_id)
        .order_by(Review.is_flagged_suspicious.desc(), Review.trust_score.asc(), Review.created_at.desc())
    )
    if flagged_only:
        q = q.filter(
            (Review.is_flagged_suspicious.is_(True))
            | (Review.moderation_status == "flagged")
            | (Review.moderation_status == "hidden")
        )

    rows = q.limit(limit).all()

    all_reviews = db.query(Review.is_flagged_suspicious, Review.moderation_status).all()
    total_count = len(all_reviews)
    flagged_count = sum(1 for r in all_reviews if r[0] or (r[1] == "flagged"))
    hidden_count = sum(1 for r in all_reviews if r[1] == "hidden")
    approved_count = sum(1 for r in all_reviews if (r[1] or "approved") == "approved" and not r[0])

    return {
        "total_count": total_count,
        "flagged_count": flagged_count,
        "hidden_count": hidden_count,
        "approved_count": approved_count,
        "reviews": [
            {
                "id": rev.id,
                "product_id": rev.product_id,
                "product_name": pname or f"Product #{rev.product_id}",
                "user_email": rev.user_email,
                "rating": rev.rating,
                "title": rev.title or "",
                "comment": rev.comment,
                "verified_purchase": bool(rev.verified_purchase),
                "trust_score": round(float(getattr(rev, "trust_score", None) or 85.0), 1),
                "is_flagged_suspicious": bool(getattr(rev, "is_flagged_suspicious", False)),
                "trust_flags": _safe_json_load(getattr(rev, "trust_flags", "[]"), []),
                "aspect_sentiments": _safe_json_load(getattr(rev, "aspect_sentiments", "{}"), {}),
                "moderation_status": getattr(rev, "moderation_status", None) or "approved",
                "created_at": rev.created_at.isoformat() if rev.created_at else None,
            }
            for rev, pname in rows
        ],
    }


@router.patch("/reviews/{review_id}/moderate")
@router.put("/reviews/{review_id}/moderate")
def moderate_review_status(
    review_id: int,
    payload: ReviewModerationRequest,
    db: Session = Depends(get_db),
    admin_user: User = Depends(require_role(["admin"])),
):
    """Approve, flag, or hide a review and refresh product rating aggregates & AI insights."""
    review = db.query(Review).filter(Review.id == review_id).first()
    if review is None:
        raise HTTPException(status_code=404, detail="Review not found.")

    if payload.action == "approve":
        review.moderation_status = "approved"
        review.is_flagged_suspicious = False
        review.trust_score = max(float(review.trust_score or 75.0), 75.0)
    elif payload.action == "hide":
        review.moderation_status = "hidden"
        review.is_flagged_suspicious = True
    else:
        review.moderation_status = "flagged"
        review.is_flagged_suspicious = True

    db.flush()

    # Recompute product aggregates excluding hidden reviews
    product = (
        db.query(Product)
        .options(load_only(Product.id, Product.rating, Product.reviews))
        .filter(Product.id == review.product_id)
        .first()
    )
    if product is not None:
        visible_ratings = [
            r[0]
            for r in db.query(Review.rating, Review.moderation_status)
            .filter(Review.product_id == review.product_id)
            .all()
            if (r[1] or "approved") != "hidden"
        ]
        product.reviews = len(visible_ratings)
        product.rating = (
            round(sum(visible_ratings) / len(visible_ratings), 2)
            if visible_ratings
            else 4.8
        )

    db.query(ProductReviewInsight).filter(
        ProductReviewInsight.product_id == review.product_id
    ).delete(synchronize_session=False)
    db.commit()
    db.refresh(review)

    return {
        "status": "moderated",
        "review_id": review.id,
        "product_id": review.product_id,
        "moderation_status": review.moderation_status,
        "is_flagged_suspicious": bool(review.is_flagged_suspicious),
        "trust_score": round(float(review.trust_score or 85.0), 1),
    }


# ---------------------------------------------------------------------------
# PHASE 3: EXAMINER-READY AI EVALUATION & METRICS ENDPOINTS
# ---------------------------------------------------------------------------

@router.get("/ai-metrics/summary")
def get_admin_ai_metrics_summary(
    db: Session = Depends(get_db),
    admin_user: User = Depends(require_role(["admin"])),
):
    """Return live + benchmark KPI metrics across Visual Search, CTRL-X, Fake Review Engine, and 3D Optimizer."""
    return get_ai_metrics_summary(db)


@router.get("/ai-metrics/export-csv")
def export_admin_ai_metrics_csv(
    db: Session = Depends(get_db),
    admin_user: User = Depends(require_role(["admin"])),
):
    """Download raw AI evaluation and telemetry logs as a CSV file for FYP thesis charts."""
    csv_text = export_ai_metrics_csv(db)
    return Response(
        content=csv_text,
        media_type="text/csv; charset=utf-8",
        headers={
            "Content-Disposition": 'attachment; filename="penguin_ai_metrics_report.csv"',
        },
    )
