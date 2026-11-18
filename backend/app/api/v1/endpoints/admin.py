"""Strict Admin & Supplier RBAC Operations Endpoints (/api/v1/admin)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.security import require_role, resolve_user_role
from app.models import Notification, Order, OrderItem, User
from app.schemas.auth import UserRoleUpdate
from app.schemas.commerce import OrderStatusUpdateRequest

router = APIRouter(prefix="/admin", tags=["Admin RBAC"])


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
