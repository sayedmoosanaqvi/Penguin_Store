import json
import logging
from datetime import datetime, timezone
from threading import Lock
from typing import Any, List, Optional

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import func
from sqlalchemy.orm import Session, load_only

from app.adapters.supplier_adapter import DummyJSONAdapter
from app.core.supabase_rest import (
    fetch_product_by_id_https,
    get_supabase_client,
    invalidate_supabase_rest_cache,
    is_pg_tcp_reachable,
)
from app.database import SessionLocal
from app.email_utils import send_order_confirmation
from app.models import Notification, Order, OrderItem, Product, User
from app.push_utils import send_push_notification
from app.security import get_current_user, resolve_user_role

logger = logging.getLogger(__name__)

router = APIRouter(tags=["Order Dispatch"])

_MEM_ORDERS_LOCK = Lock()
_MEM_ORDERS: list[dict[str, Any]] = []
_MEM_ORDER_SEQ: int = 5000


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


class CartItem(BaseModel):
    product_id: int = Field(..., gt=0)
    quantity: int = Field(..., ge=1, le=1000)
    unit_price: Optional[float] = Field(default=None, gt=0, le=1_000_000)
    selected_variant: Optional[str] = Field(default=None, max_length=120)
    selected_addons: Optional[List[str]] = Field(default=None)
    pricing_mode: Optional[str] = Field(default="B2C", max_length=32)


class CheckoutRequest(BaseModel):
    customer_name: str = Field(..., min_length=1, max_length=150)
    customer_email: str = Field(..., min_length=3, max_length=254)
    shipping_address: str = Field(..., min_length=1, max_length=300)
    city: str = Field(..., min_length=1, max_length=100)
    state_province: Optional[str] = Field(default="Punjab", max_length=100)
    country: Optional[str] = Field(default="Pakistan", max_length=100)
    postal_code: str = Field(..., min_length=1, max_length=30)
    promo_code: Optional[str] = Field(default=None, max_length=64)
    discount_amount: Optional[float] = Field(default=0.0, ge=0.0)
    tax_amount: Optional[float] = Field(default=0.0, ge=0.0)
    currency_code: Optional[str] = Field(default="USD", max_length=12)
    payment_method: Optional[str] = Field(default="COD", max_length=32)
    items: List[CartItem]


def get_order_record(order_id: int) -> Optional[dict[str, Any]]:
    """Retrieve an order record from in-memory cache or Supabase HTTPS REST."""
    with _MEM_ORDERS_LOCK:
        for o in _MEM_ORDERS:
            if int(o.get("order_id") or o.get("id") or 0) == int(order_id):
                return dict(o)

    try:
        client = get_supabase_client()
        res = client.table("orders").select("*").eq("id", int(order_id)).limit(1).execute()
        rows = res.data or []
        if not rows:
            return None
        row = rows[0]
        items_res = (
            client.table("order_items")
            .select("*")
            .eq("order_id", int(order_id))
            .execute()
        )
        items = []
        for raw_item in items_res.data or []:
            pid = int(raw_item.get("product_id") or 0)
            prod = fetch_product_by_id_https(pid)
            items.append(
                {
                    "product_id": pid,
                    "product_name": (prod.get("name") if prod else f"Product #{pid}"),
                    "quantity": int(raw_item.get("quantity") or 1),
                    "unit_price": float(raw_item.get("unit_price") or 0.0),
                    "selected_variant": raw_item.get("selected_variant"),
                    "selected_addons": raw_item.get("selected_addons") or [],
                    "pricing_mode": raw_item.get("pricing_mode") or "B2C",
                    "fulfillment_type": raw_item.get("fulfillment_type") or "IN_HOUSE",
                    "dispatch_status": raw_item.get("dispatch_status") or "QUEUED_FOR_PACKING",
                    "tracking_number": raw_item.get("tracking_number") or f"LOCAL-PK-{pid}-001",
                }
            )
        return {
            "id": int(row["id"]),
            "order_id": int(row["id"]),
            "customer_name": row.get("customer_name") or "Customer",
            "customer_email": row.get("customer_email") or "",
            "shipping_address": row.get("shipping_address") or "",
            "city": row.get("city") or "",
            "state_province": row.get("state_province") or "Punjab",
            "country": row.get("country") or "Pakistan",
            "postal_code": row.get("postal_code") or "",
            "subtotal_amount": float(row.get("subtotal_amount") or row.get("total_amount") or 0.0),
            "discount_amount": float(row.get("discount_amount") or 0.0),
            "tax_amount": float(row.get("tax_amount") or 0.0),
            "promo_code": row.get("promo_code"),
            "currency_code": row.get("currency_code") or "USD",
            "total_amount": float(row.get("total_amount") or 0.0),
            "payment_method": row.get("payment_method") or "COD",
            "payment_status": row.get("payment_status") or "Confirmed",
            "status": row.get("payment_status") or "Confirmed",
            "email_sent": bool(row.get("email_sent", False)),
            "created_at": str(row.get("created_at") or datetime.now(timezone.utc).isoformat()),
            "items": items,
        }
    except Exception:
        return None


async def finalize_paid_stripe_order(
    order_id: int,
    session_id: str,
    background_tasks: Optional[BackgroundTasks] = None,
) -> Optional[dict[str, Any]]:
    """
    Idempotently finalize an order after Stripe confirms payment_status == 'paid':
    1. Mark order payment_status = 'paid' & status = 'Confirmed'
    2. Deduct product stock in Supabase (only once!)
    3. Trigger order confirmation email & push notification (only once!)
    """
    record = get_order_record(order_id)
    if record is None:
        return None

    already_paid = str(record.get("payment_status") or "").lower() == "paid"
    already_emailed = bool(record.get("email_sent"))

    if already_paid and already_emailed:
        return record

    client = get_supabase_client()

    # Deduct stock if not yet deducted
    if not record.get("stock_deducted"):
        for item in record.get("items") or []:
            pid = int(item.get("product_id") or 0)
            qty = int(item.get("quantity") or 1)
            prod = fetch_product_by_id_https(pid)
            if prod is not None:
                avail = int(prod.get("stock") if prod.get("stock") is not None else 50)
                new_stock = max(0, avail - qty)
                try:
                    client.table("products").update({"stock": new_stock}).eq("id", pid).execute()
                except Exception:
                    pass
        invalidate_supabase_rest_cache()

    # Update order status in memory
    with _MEM_ORDERS_LOCK:
        for o in _MEM_ORDERS:
            if int(o.get("order_id") or o.get("id") or 0) == int(order_id):
                o["payment_status"] = "paid"
                o["status"] = "Confirmed (Paid via Stripe)"
                o["stripe_session_id"] = session_id
                o["stock_deducted"] = True
                o["email_sent"] = True
                record = dict(o)
                break

    # Best-effort update in Supabase orders table
    try:
        client.table("orders").update(
            {
                "payment_status": "paid",
                "stripe_session_id": session_id,
                "email_sent": True,
            }
        ).eq("id", int(order_id)).execute()
    except Exception:
        pass

    clean_email = str(record.get("customer_email") or "").strip().lower()
    if clean_email and not already_emailed:
        if background_tasks is not None:
            background_tasks.add_task(send_order_confirmation, clean_email, str(order_id))
            background_tasks.add_task(
                send_push_notification,
                clean_email,
                "Payment Verified & Order Confirmed!",
                f"Stripe payment received for Order #{order_id}. Your items are queued for dispatch.",
            )
        else:
            try:
                await send_order_confirmation(clean_email, str(order_id))
            except Exception:
                pass
            try:
                await send_push_notification(
                    clean_email,
                    "Payment Verified & Order Confirmed!",
                    f"Stripe payment received for Order #{order_id}. Your items are queued for dispatch.",
                )
            except Exception:
                pass

    return record


@router.post("/api/orders/checkout")
async def process_checkout(
    payload: CheckoutRequest,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    """
    Processes an order, verifies and deducts stock, preserves dynamic variant/add-on
    and B2B tiered pricing, applies promo discounts, and records the order in Supabase.
    """
    global _MEM_ORDER_SEQ

    if not payload.items:
        raise HTTPException(status_code=400, detail="Cart cannot be empty")

    clean_email = payload.customer_email.strip().lower()
    if "@" not in clean_email:
        raise HTTPException(
            status_code=422, detail="Enter a valid customer email address."
        )

    subtotal_amount = 0.0
    fulfillment_summary: dict[str, Any] = {
        "in_house_items": [],
        "dropship_dispatched": [],
    }
    prepared_items: list[dict[str, Any]] = []

    client = get_supabase_client()

    is_stripe_pending = (payload.payment_method or "COD").strip().upper() == "STRIPE"

    for cart_item in payload.items:
        prod_dict = fetch_product_by_id_https(cart_item.product_id)
        if prod_dict is None:
            raise HTTPException(
                status_code=404,
                detail=f"Product ID {cart_item.product_id} not found",
            )

        avail_stock = int(prod_dict.get("stock") if prod_dict.get("stock") is not None else 50)
        if avail_stock < cart_item.quantity:
            raise HTTPException(
                status_code=400,
                detail=(
                    f"Insufficient stock for {prod_dict.get('name')}. "
                    f"Available: {avail_stock}, Requested: {cart_item.quantity}"
                ),
            )

        # Deduct stock immediately ONLY for confirmed COD orders; for Stripe orders,
        # stock is deducted once Stripe verifies payment_status == 'paid'.
        if not is_stripe_pending:
            new_stock = max(0, avail_stock - cart_item.quantity)
            try:
                client.table("products").update({"stock": new_stock}).eq(
                    "id", cart_item.product_id
                ).execute()
            except Exception:
                pass

        base_price = float(prod_dict.get("price") or 0.0)
        effective_unit_price = (
            float(cart_item.unit_price)
            if cart_item.unit_price is not None and cart_item.unit_price > 0
            else base_price
        )
        line_total = round(effective_unit_price * cart_item.quantity, 2)
        subtotal_amount += line_total

        f_type = str(prod_dict.get("fulfillment_type") or "IN_HOUSE")
        tracking = f"LOCAL-PK-{cart_item.product_id}-001"
        dispatch_status = "QUEUED_FOR_PACKING"

        if f_type == "DROPSHIP":
            tracking = f"DS-{cart_item.product_id}-902"
            dispatch_status = "DISPATCHED"
            fulfillment_summary["dropship_dispatched"].append(
                {"product": prod_dict.get("name"), "tracking": tracking}
            )
        else:
            fulfillment_summary["in_house_items"].append(prod_dict.get("name"))

        prepared_items.append(
            {
                "product_id": cart_item.product_id,
                "product_name": prod_dict.get("name") or f"Product #{cart_item.product_id}",
                "quantity": cart_item.quantity,
                "unit_price": round(effective_unit_price, 2),
                "selected_variant": (cart_item.selected_variant or "").strip() or None,
                "selected_addons": cart_item.selected_addons or [],
                "pricing_mode": (cart_item.pricing_mode or "B2C").strip(),
                "fulfillment_type": f_type,
                "dispatch_status": dispatch_status,
                "tracking_number": tracking,
            }
        )

    invalidate_supabase_rest_cache()

    discount = round(min(float(payload.discount_amount or 0.0), subtotal_amount), 2)
    tax = round(float(payload.tax_amount or 0.0), 2)
    final_total = round(max(0.0, subtotal_amount - discount + tax), 2)
    now_iso = datetime.now(timezone.utc).isoformat()

    created_order_id: int | None = None
    try:
        order_res = (
            client.table("orders")
            .insert(
                {
                    "customer_name": payload.customer_name.strip(),
                    "customer_email": clean_email,
                    "shipping_address": payload.shipping_address.strip(),
                    "city": payload.city.strip(),
                    "state_province": (payload.state_province or "Punjab").strip(),
                    "country": (payload.country or "Pakistan").strip(),
                    "postal_code": payload.postal_code.strip(),
                    "total_amount": final_total,
                }
            )
            .execute()
        )
        rows = order_res.data or []
        if rows:
            created_order_id = int(rows[0]["id"])
            for p_item in prepared_items:
                try:
                    client.table("order_items").insert(
                        {
                            "order_id": created_order_id,
                            "product_id": p_item["product_id"],
                            "quantity": p_item["quantity"],
                            "unit_price": p_item["unit_price"],
                            "fulfillment_type": p_item["fulfillment_type"],
                            "dispatch_status": p_item["dispatch_status"],
                            "tracking_number": p_item["tracking_number"],
                        }
                    ).execute()
                except Exception:
                    pass
    except Exception as exc:
        logger.warning("Order Supabase insert fallback to memory cache: %s", exc)

    with _MEM_ORDERS_LOCK:
        if created_order_id is None:
            _MEM_ORDER_SEQ += 1
            created_order_id = _MEM_ORDER_SEQ
        _MEM_ORDERS.insert(
            0,
            {
                "id": created_order_id,
                "order_id": created_order_id,
                "customer_name": payload.customer_name.strip(),
                "customer_email": clean_email,
                "shipping_address": payload.shipping_address.strip(),
                "city": payload.city.strip(),
                "state_province": (payload.state_province or "Punjab").strip(),
                "country": (payload.country or "Pakistan").strip(),
                "postal_code": payload.postal_code.strip(),
                "subtotal_amount": round(subtotal_amount, 2),
                "discount_amount": discount,
                "tax_amount": tax,
                "promo_code": (payload.promo_code or "").strip().upper() or None,
                "currency_code": (payload.currency_code or "USD").strip().upper(),
                "total_amount": final_total,
                "payment_method": "STRIPE" if is_stripe_pending else "COD",
                "payment_status": "pending" if is_stripe_pending else "cod_confirmed",
                "status": "Pending Payment" if is_stripe_pending else "Confirmed (COD)",
                "stock_deducted": not is_stripe_pending,
                "email_sent": not is_stripe_pending,
                "created_at": now_iso,
                "items": prepared_items,
            },
        )

    # IMPORTANT (Phase 2.1): For Stripe orders, DO NOT send the confirmation email
    # until Stripe confirms payment_status == 'paid'. For COD orders, send immediately.
    if not is_stripe_pending:
        background_tasks.add_task(
            send_order_confirmation,
            clean_email,
            str(created_order_id),
        )

        background_tasks.add_task(
            send_push_notification,
            clean_email,
            "Order Confirmed (COD)!",
            f"Your Cash-on-Delivery order #{created_order_id} is confirmed and being processed.",
        )

    return {
        "status": "pending_payment" if is_stripe_pending else "success",
        "order_id": created_order_id,
        "payment_method": "STRIPE" if is_stripe_pending else "COD",
        "payment_status": "pending" if is_stripe_pending else "cod_confirmed",
        "subtotal_amount": round(subtotal_amount, 2),
        "discount_amount": discount,
        "tax_amount": tax,
        "total_charged": final_total,
        "promo_code": (payload.promo_code or "").strip().upper() or None,
        "fulfillment_routing": fulfillment_summary,
    }


@router.get("/api/orders/history/{customer_email}")
def get_order_history(
    customer_email: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """
    Retrieves past orders, line items (including variants, add-ons, promo discount),
    and tracking/fulfillment status over Supabase HTTPS + in-memory session history.
    """
    clean_email = customer_email.strip().lower()
    if not clean_email:
        return {"customer_email": customer_email, "orders": []}

    if (
        resolve_user_role(current_user) != "admin"
        and current_user.email.strip().lower() != clean_email
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only view your own order history.",
        )

    with _MEM_ORDERS_LOCK:
        mem_by_id = {
            int(o["order_id"]): o
            for o in _MEM_ORDERS
            if str(o.get("customer_email") or "").lower() == clean_email
        }

    result: list[dict[str, Any]] = []
    seen_ids: set[int] = set()

    try:
        client = get_supabase_client()
        orders_res = (
            client.table("orders")
            .select("*")
            .ilike("customer_email", clean_email)
            .order("id", desc=True)
            .limit(40)
            .execute()
        )
        db_orders = orders_res.data or []
        order_ids = [int(o["id"]) for o in db_orders if isinstance(o, dict) and o.get("id")]

        items_by_order: dict[int, list[dict[str, Any]]] = {}
        if order_ids:
            items_res = (
                client.table("order_items")
                .select("*")
                .in_("order_id", order_ids)
                .execute()
            )
            for raw_item in items_res.data or []:
                if not isinstance(raw_item, dict):
                    continue
                oid = int(raw_item.get("order_id") or 0)
                pid = int(raw_item.get("product_id") or 0)
                prod = fetch_product_by_id_https(pid)
                items_by_order.setdefault(oid, []).append(
                    {
                        "product_id": pid,
                        "product_name": (
                            prod.get("name") if prod else f"Product #{pid}"
                        ),
                        "quantity": int(raw_item.get("quantity") or 1),
                        "unit_price": float(raw_item.get("unit_price") or 0.0),
                        "selected_variant": raw_item.get("selected_variant"),
                        "selected_addons": (
                            json.loads(raw_item["selected_addons"])
                            if isinstance(raw_item.get("selected_addons"), str)
                            and raw_item["selected_addons"].startswith("[")
                            else (raw_item.get("selected_addons") or [])
                        ),
                        "pricing_mode": raw_item.get("pricing_mode") or "B2C",
                        "fulfillment_type": raw_item.get("fulfillment_type") or "IN_HOUSE",
                        "dispatch_status": raw_item.get("dispatch_status") or "QUEUED_FOR_PACKING",
                        "tracking_number": raw_item.get("tracking_number") or f"LOCAL-PK-{pid}-001",
                    }
                )

        for o in db_orders:
            oid = int(o["id"])
            seen_ids.add(oid)
            mem_match = mem_by_id.get(oid, {})
            result.append(
                {
                    "order_id": oid,
                    "customer_name": o.get("customer_name") or mem_match.get("customer_name") or clean_email,
                    "customer_email": clean_email,
                    "total_amount": float(o.get("total_amount") or 0.0),
                    "subtotal_amount": float(
                        o.get("subtotal_amount")
                        or mem_match.get("subtotal_amount")
                        or o.get("total_amount")
                        or 0.0
                    ),
                    "discount_amount": float(
                        o.get("discount_amount")
                        or mem_match.get("discount_amount")
                        or 0.0
                    ),
                    "tax_amount": float(
                        o.get("tax_amount") or mem_match.get("tax_amount") or 0.0
                    ),
                    "promo_code": o.get("promo_code") or mem_match.get("promo_code"),
                    "shipping_address": o.get("shipping_address") or "",
                    "city": o.get("city") or "",
                    "country": o.get("country") or "Pakistan",
                    "postal_code": o.get("postal_code") or "",
                    "created_at": str(o.get("created_at") or ""),
                    "items": mem_match.get("items") or items_by_order.get(oid, []),
                }
            )
    except Exception as exc:
        logger.warning("Order history HTTPS query fallback: %s", exc)

    for oid, mem_order in mem_by_id.items():
        if oid not in seen_ids:
            result.insert(0, mem_order)

    return {"customer_email": customer_email, "orders": result}


@router.get("/api/orders/detail/{order_id}")
def get_single_order_detail(order_id: int):
    record = get_order_record(order_id)
    if record is None:
        raise HTTPException(status_code=404, detail=f"Order #{order_id} not found.")
    return {"order": record}


class OrderStatusUpdate(BaseModel):
    status: str = Field(..., min_length=2, max_length=64)


@router.get("/api/orders/admin/all")
def list_all_orders_admin(
    current_user: User = Depends(get_current_user),
):
    if resolve_user_role(current_user) != "admin":
        raise HTTPException(status_code=403, detail="Admin access required.")

    with _MEM_ORDERS_LOCK:
        mem_list = [dict(o) for o in _MEM_ORDERS]

    seen = {int(o["order_id"]) for o in mem_list if o.get("order_id")}
    try:
        client = get_supabase_client()
        res = client.table("orders").select("*").order("id", desc=True).limit(100).execute()
        for row in res.data or []:
            oid = int(row["id"])
            if oid not in seen:
                mem_list.append(
                    {
                        "id": oid,
                        "order_id": oid,
                        "customer_name": row.get("customer_name") or "Customer",
                        "customer_email": row.get("customer_email") or "",
                        "total_amount": float(row.get("total_amount") or 0.0),
                        "status": row.get("payment_status") or "Confirmed",
                        "promo_code": row.get("promo_code"),
                        "created_at": str(row.get("created_at") or ""),
                        "items": [],
                    }
                )
    except Exception:
        pass
    return {"orders": mem_list}


@router.put("/api/orders/admin/{order_id}/status")
def update_order_status_admin(
    order_id: int,
    payload: OrderStatusUpdate,
    current_user: User = Depends(get_current_user),
):
    if resolve_user_role(current_user) != "admin":
        raise HTTPException(status_code=403, detail="Admin access required.")

    with _MEM_ORDERS_LOCK:
        for o in _MEM_ORDERS:
            if int(o.get("order_id") or o.get("id") or 0) == int(order_id):
                o["status"] = payload.status.strip()
                break

    try:
        client = get_supabase_client()
        client.table("orders").update({"payment_status": payload.status.strip()}).eq("id", int(order_id)).execute()
    except Exception:
        pass
    return {"status": "updated", "order_id": order_id, "new_status": payload.status.strip()}
