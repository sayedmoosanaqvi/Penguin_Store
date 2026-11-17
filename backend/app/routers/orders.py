import logging
from typing import List, Optional

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import func
from sqlalchemy.orm import Session, load_only

from app.adapters.supplier_adapter import DummyJSONAdapter
from app.database import SessionLocal
from app.email_utils import send_order_confirmation
from app.models import Notification, Order, OrderItem, Product, User
from app.push_utils import send_push_notification
from app.security import get_optional_current_user

logger = logging.getLogger(__name__)

router = APIRouter(tags=["Order Dispatch"])


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


# Pydantic models for checkout validation
class CartItem(BaseModel):
    product_id: int = Field(..., gt=0)
    quantity: int = Field(..., ge=1, le=100)


class CheckoutRequest(BaseModel):
    customer_name: str = Field(..., min_length=1, max_length=150)
    customer_email: str = Field(..., min_length=3, max_length=254)
    shipping_address: str = Field(..., min_length=1, max_length=300)
    city: str = Field(..., min_length=1, max_length=100)
    state_province: Optional[str] = Field(default="Punjab", max_length=100)
    country: Optional[str] = Field(default="Pakistan", max_length=100)
    postal_code: str = Field(..., min_length=1, max_length=30)
    items: List[CartItem]


@router.post("/api/orders/checkout")
async def process_checkout(
    payload: CheckoutRequest,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    """
    Processes an order, verifies and deducts stock, splits fulfillment,
    and triggers background email & push notifications.
    """
    if not payload.items:
        raise HTTPException(status_code=400, detail="Cart cannot be empty")

    clean_email = payload.customer_email.strip().lower()
    if "@" not in clean_email:
        raise HTTPException(status_code=422, detail="Enter a valid customer email address.")

    adapter = DummyJSONAdapter()
    total_order_amount = 0.0
    order_items_to_create = []
    fulfillment_summary = {"in_house_items": [], "dropship_dispatched": []}

    try:
        # 1. Process each item in the cart, check stock, and deduct inventory
        for cart_item in payload.items:
            product = (
                db.query(Product)
                .options(
                    load_only(
                        Product.id,
                        Product.name,
                        Product.price,
                        Product.stock,
                        Product.fulfillment_type,
                        Product.supplier_sku,
                    )
                )
                .filter(Product.id == cart_item.product_id)
                .first()
            )
            if not product:
                raise HTTPException(
                    status_code=404,
                    detail=f"Product ID {cart_item.product_id} not found",
                )

            available_stock = int(product.stock if product.stock is not None else 0)
            if available_stock < cart_item.quantity:
                raise HTTPException(
                    status_code=400,
                    detail=(
                        f"Insufficient stock for {product.name}. "
                        f"Available: {available_stock}, Requested: {cart_item.quantity}"
                    ),
                )

            # Deduct stock
            product.stock = available_stock - cart_item.quantity

            line_total = float(product.price) * cart_item.quantity
            total_order_amount += line_total

            # 2. Check fulfillment type
            if product.fulfillment_type == "DROPSHIP":
                dispatch_res = await adapter.place_order(
                    supplier_sku=product.supplier_sku or str(product.id),
                    shipping_address={
                        "recipient": payload.customer_name.strip(),
                        "address": payload.shipping_address.strip(),
                        "city": payload.city.strip(),
                        "postal_code": payload.postal_code.strip(),
                    },
                )

                order_items_to_create.append(
                    OrderItem(
                        product_id=product.id,
                        quantity=cart_item.quantity,
                        unit_price=product.price,
                        fulfillment_type="DROPSHIP",
                        dispatch_status="DISPATCHED",
                        tracking_number=dispatch_res.get("tracking_number"),
                    )
                )
                fulfillment_summary["dropship_dispatched"].append(
                    {
                        "product": product.name,
                        "tracking": dispatch_res.get("tracking_number"),
                    }
                )
            else:
                order_items_to_create.append(
                    OrderItem(
                        product_id=product.id,
                        quantity=cart_item.quantity,
                        unit_price=product.price,
                        fulfillment_type="IN_HOUSE",
                        dispatch_status="QUEUED_FOR_PACKING",
                        tracking_number=f"LOCAL-PK-{product.id}-001",
                    )
                )
                fulfillment_summary["in_house_items"].append(product.name)

        # 3. Save order record to PostgreSQL
        new_order = Order(
            customer_name=payload.customer_name.strip(),
            customer_email=clean_email,
            shipping_address=payload.shipping_address.strip(),
            city=payload.city.strip(),
            state_province=(payload.state_province or "Punjab").strip(),
            country=(payload.country or "Pakistan").strip(),
            postal_code=payload.postal_code.strip(),
            total_amount=round(total_order_amount, 2),
            items=order_items_to_create,
        )
        db.add(new_order)
        db.commit()
        db.refresh(new_order)

        # ---> IN-APP NOTIFICATION CREATION <---
        in_app_notif = Notification(
            customer_email=clean_email,
            title="Order Confirmed! 📦",
            message=f"Your order #{new_order.id} has been placed successfully and is being processed.",
            notification_type="ORDER",
        )
        db.add(in_app_notif)
        db.commit()

        # 4. TRIGGER NOTIFICATIONS (Runs in the background)
        background_tasks.add_task(
            send_order_confirmation,
            clean_email,
            str(new_order.id),
        )

        background_tasks.add_task(
            send_push_notification,
            clean_email,
            "Payment Successful! 🎉",
            f"Your order #{new_order.id} is confirmed and being processed.",
        )

        return {
            "status": "success",
            "order_id": new_order.id,
            "total_charged": round(total_order_amount, 2),
            "fulfillment_routing": fulfillment_summary,
        }

    except HTTPException:
        db.rollback()
        raise
    except Exception:
        db.rollback()
        logger.exception("Checkout processing failed")
        raise HTTPException(
            status_code=500,
            detail="Unable to process checkout at this time. Please try again.",
        )


@router.get("/api/orders/history/{customer_email}")
def get_order_history(
    customer_email: str,
    db: Session = Depends(get_db),
    current_user: User | None = Depends(get_optional_current_user),
):
    """
    Retrieves all past orders, line items, and tracking/fulfillment status for a given customer email.
    """
    clean_email = customer_email.strip().lower()
    if not clean_email:
        return {"customer_email": customer_email, "orders": []}

    # If a non-admin user provides a JWT token, enforce ownership of the email
    if (
        current_user is not None
        and not current_user.is_admin
        and current_user.email.strip().lower() != clean_email
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only view your own order history.",
        )

    orders = (
        db.query(Order)
        .filter(func.lower(Order.customer_email) == clean_email)
        .order_by(Order.created_at.desc())
        .all()
    )

    if not orders:
        return {"customer_email": customer_email, "orders": []}

    # Batch-fetch product names without loading large embedding vectors
    all_product_ids = {
        item.product_id
        for order in orders
        for item in order.items
        if item.product_id is not None
    }
    product_names = {}
    if all_product_ids:
        rows = (
            db.query(Product.id, Product.name)
            .filter(Product.id.in_(all_product_ids))
            .all()
        )
        product_names = {pid: pname for pid, pname in rows}

    result = []
    for order in orders:
        items_list = []
        for item in order.items:
            items_list.append(
                {
                    "product_id": item.product_id,
                    "product_name": product_names.get(
                        item.product_id,
                        "Unknown Product",
                    ),
                    "quantity": item.quantity,
                    "unit_price": item.unit_price,
                    "fulfillment_type": item.fulfillment_type,
                    "dispatch_status": item.dispatch_status,
                    "tracking_number": item.tracking_number,
                }
            )

        result.append(
            {
                "order_id": order.id,
                "total_amount": order.total_amount,
                "shipping_address": order.shipping_address,
                "city": order.city,
                "postal_code": order.postal_code,
                "created_at": (
                    order.created_at.isoformat()
                    if order.created_at
                    else ""
                ),
                "items": items_list,
            }
        )

    return {"customer_email": customer_email, "orders": result}
