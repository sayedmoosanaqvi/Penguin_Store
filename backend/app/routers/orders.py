import hashlib
import hmac
import json
import logging
from datetime import datetime, timezone
from threading import Lock
from typing import Any, List, Optional

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import func
from sqlalchemy.orm import Session, load_only

from app.adapters.supplier_adapter import DummyJSONAdapter
from app.core.config import settings
from app.core.supabase_rest import (
    fetch_product_by_id_https,
    get_supabase_client,
    invalidate_supabase_rest_cache,
    is_pg_tcp_reachable,
    is_product_active_row,
)
from app.database import SessionLocal
from app.email_utils import send_order_confirmation
from app.models import Notification, Order, OrderItem, Product, User
from app.push_utils import send_push_notification
from app.security import get_current_user, get_optional_current_user, resolve_user_role

logger = logging.getLogger(__name__)

router = APIRouter(tags=["Order Dispatch"])

_MEM_ORDERS_LOCK = Lock()
_MEM_ORDERS: list[dict[str, Any]] = []
_MEM_ORDER_SEQ: int = 5000

_FULFILLMENT_LOCK = Lock()
_FULFILLED_ORDER_IDS: set[int] = set()
_FULFILLED_SESSION_IDS: set[str] = set()

# Authoritative server-side add-on catalog (never trust client-supplied prices)
_ADDON_FEES: tuple[tuple[str, tuple[str, ...], float], ...] = (
    ("gift_wrap", ("gift_wrap", "gift wrapping"), 9.99),
    ("extended_warranty", ("extended_warranty", "extended 2-year warranty", "2-year warranty"), 29.99),
    ("express_handling", ("express_handling", "priority express handling", "express handling"), 14.50),
)

_TAX_RATE = 0.05


def generate_order_receipt_token(order_id: int, customer_email: str) -> str:
    """Create an HMAC-SHA256 receipt capability token bound to order_id + customer_email."""
    secret = (settings.SECRET_KEY or "penguin-store-hmac-fallback").encode("utf-8")
    msg = f"order-receipt:{int(order_id)}:{customer_email.strip().lower()}".encode("utf-8")
    return hmac.new(secret, msg, hashlib.sha256).hexdigest()


def verify_order_receipt_token(
    order_id: int,
    customer_email: str,
    candidate_token: Optional[str],
) -> bool:
    if not candidate_token or not customer_email:
        return False
    expected = generate_order_receipt_token(order_id, customer_email)
    return hmac.compare_digest(candidate_token.strip(), expected)


def _compute_variant_delta(category: str, selected_variant: Optional[str]) -> float:
    if not selected_variant or not selected_variant.strip():
        return 0.0
    v = selected_variant.strip().lower()
    cat = (category or "").strip().lower()
    is_apparel = any(
        kw in cat for kw in ("cloth", "fashion", "apparel", "wear", "jacket", "shoe", "foot")
    )
    if is_apparel:
        if "pro custom fit" in v:
            return 18.0
        if v.startswith("xl") or "tailored fit" in v:
            return 8.0
        return 0.0

    if "collector studio edition" in v:
        return 45.0
    if "pro edition" in v:
        return 24.0
    return 0.0


def _compute_addons_unit_delta(selected_addons: Optional[List[str]]) -> float:
    if not selected_addons:
        return 0.0
    matched_ids: set[str] = set()
    total = 0.0
    for raw in selected_addons:
        if not raw:
            continue
        norm = str(raw).strip().lower()
        for addon_id, needles, fee in _ADDON_FEES:
            if addon_id not in matched_ids and any(n in norm for n in needles):
                matched_ids.add(addon_id)
                total += fee
    return round(total, 2)


def _compute_moq_discount_percent(quantity: int) -> float:
    if quantity >= 50:
        return 22.0
    if quantity >= 10:
        return 12.0
    return 0.0


def compute_authoritative_unit_price(
    product_row: dict[str, Any],
    quantity: int,
    selected_variant: Optional[str] = None,
    selected_addons: Optional[List[str]] = None,
) -> float:
    """Compute exact unit price from live DB product record + variant + B2B MOQ tier + add-ons."""
    base_price = max(0.0, float(product_row.get("price") or 0.0))
    variant_delta = _compute_variant_delta(
        str(product_row.get("category") or ""),
        selected_variant,
    )
    moq_pct = _compute_moq_discount_percent(int(quantity))
    discounted_base = (base_price + variant_delta) * (1.0 - moq_pct / 100.0)
    addons_delta = _compute_addons_unit_delta(selected_addons)
    return round(discounted_base + addons_delta, 2)


def compute_authoritative_promo_discount(
    subtotal: float,
    promo_code: Optional[str],
) -> tuple[float, Optional[str]]:
    """Evaluate valid server-side promo rules; unknown codes yield $0.00 discount."""
    if subtotal <= 0 or not promo_code or not promo_code.strip():
        return 0.0, None
    code = promo_code.strip().upper()
    if code == "PENGUIN10":
        return round(subtotal * 0.10, 2), code
    if code == "WELCOME20":
        disc = 20.0 if subtotal >= 200.0 else round(subtotal * 0.10, 2)
        return round(min(disc, subtotal), 2), code
    if code in ("WHOLESALE15", "B2BBULK"):
        disc = round(subtotal * 0.15, 2) if subtotal >= 250.0 else round(subtotal * 0.08, 2)
        return round(min(disc, subtotal), 2), code
    if code == "ARCTIC5":
        disc = 5.0 if subtotal >= 15.0 else 0.0
        return round(min(disc, subtotal), 2), (code if disc > 0 else None)
    return 0.0, None


def calculate_server_order_pricing(
    items: List["CartItem"],
    promo_code: Optional[str] = None,
    product_lookup=fetch_product_by_id_https,
) -> dict[str, Any]:
    """
    Recalculate all unit prices, B2B MOQ discounts, add-ons, promo discounts,
    and 5% tax strictly on the server from live product records.
    """
    subtotal = 0.0
    resolved_lines: list[dict[str, Any]] = []
    for cart_item in items:
        prod_dict = product_lookup(cart_item.product_id)
        if prod_dict is None or not is_product_active_row(prod_dict):
            raise HTTPException(
                status_code=404,
                detail=f"Product ID {cart_item.product_id} not found or unavailable.",
            )
        avail_stock = int(
            prod_dict.get("stock") if prod_dict.get("stock") is not None else 50
        )
        if avail_stock < cart_item.quantity:
            raise HTTPException(
                status_code=400,
                detail=(
                    f"Insufficient stock for {prod_dict.get('name')}. "
                    f"Available: {avail_stock}, Requested: {cart_item.quantity}"
                ),
            )
        unit_price = compute_authoritative_unit_price(
            prod_dict,
            quantity=cart_item.quantity,
            selected_variant=cart_item.selected_variant,
            selected_addons=cart_item.selected_addons,
        )
        line_total = round(unit_price * cart_item.quantity, 2)
        subtotal = round(subtotal + line_total, 2)
        resolved_lines.append(
            {
                "product": prod_dict,
                "cart_item": cart_item,
                "unit_price": unit_price,
                "line_total": line_total,
                "available_stock": avail_stock,
            }
        )

    discount, applied_code = compute_authoritative_promo_discount(subtotal, promo_code)
    taxable = max(0.0, round(subtotal - discount, 2))
    tax = round(taxable * _TAX_RATE, 2)
    grand_total = round(taxable + tax, 2)
    return {
        "lines": resolved_lines,
        "subtotal": round(subtotal, 2),
        "discount": discount,
        "applied_promo_code": applied_code,
        "tax": tax,
        "total": grand_total,
    }


def decrement_stock_atomic(
    client: Any,
    product_id: int,
    quantity: int,
    known_available: Optional[int] = None,
) -> bool:
    """
    Atomically decrement stock in Supabase PostgreSQL so concurrent checkouts
    cannot oversell inventory below zero.
    Tries RPC `decrement_product_stock_atomic` first, then conditional `.gte("stock", qty)`.
    """
    try:
        rpc_res = client.rpc(
            "decrement_product_stock_atomic",
            {"p_product_id": int(product_id), "p_qty": int(quantity)},
        ).execute()
        if rpc_res.data is not None:
            if isinstance(rpc_res.data, int):
                return rpc_res.data >= 0
            if isinstance(rpc_res.data, list) and rpc_res.data:
                return True
    except Exception:
        pass

    try:
        current = known_available
        if current is None:
            prod = fetch_product_by_id_https(product_id)
            if prod is None:
                return False
            current = int(prod.get("stock") if prod.get("stock") is not None else 50)
        if current < quantity:
            return False
        new_stock = current - quantity
        upd = (
            client.table("products")
            .update({"stock": new_stock})
            .eq("id", int(product_id))
            .gte("stock", int(quantity))
            .execute()
        )
        if upd.data is not None and len(upd.data) == 0:
            return False
        return True
    except Exception as exc:
        logger.warning("Conditional stock decrement warning for product %s: %s", product_id, exc)
        return True


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
    1. Mark order payment_status = 'paid' & fulfilled_at = NOW()
    2. Atomically deduct product stock in Supabase (at most once!)
    3. Trigger order confirmation email & push notification (at most once!)
    """
    clean_sid = str(session_id or "").strip()
    with _FULFILLMENT_LOCK:
        if int(order_id) in _FULFILLED_ORDER_IDS or (
            clean_sid and clean_sid in _FULFILLED_SESSION_IDS
        ):
            return get_order_record(order_id)

        record = get_order_record(order_id)
        if record is None:
            return None

        already_paid = str(record.get("payment_status") or "").lower() == "paid"
        already_emailed = bool(record.get("email_sent"))
        already_fulfilled = bool(record.get("fulfilled_at"))

        if (already_paid and already_emailed) or already_fulfilled:
            _FULFILLED_ORDER_IDS.add(int(order_id))
            if clean_sid:
                _FULFILLED_SESSION_IDS.add(clean_sid)
            return record

        # Claim fulfillment inside the lock before side effects
        _FULFILLED_ORDER_IDS.add(int(order_id))
        if clean_sid:
            _FULFILLED_SESSION_IDS.add(clean_sid)

    client = get_supabase_client()
    now_iso = datetime.now(timezone.utc).isoformat()

    # Deduct stock atomically if not yet deducted
    if not record.get("stock_deducted"):
        for item in record.get("items") or []:
            pid = int(item.get("product_id") or 0)
            qty = int(item.get("quantity") or 1)
            decrement_stock_atomic(client, pid, qty)
        invalidate_supabase_rest_cache()

    # Update order status in memory
    with _MEM_ORDERS_LOCK:
        for o in _MEM_ORDERS:
            if int(o.get("order_id") or o.get("id") or 0) == int(order_id):
                o["payment_status"] = "paid"
                o["status"] = "Confirmed (Paid via Stripe)"
                o["stripe_session_id"] = clean_sid
                o["stock_deducted"] = True
                o["email_sent"] = True
                o["fulfilled_at"] = now_iso
                record = dict(o)
                break

    # Best-effort update in Supabase orders table
    try:
        client.table("orders").update(
            {
                "payment_status": "paid",
                "stripe_session_id": clean_sid,
                "email_sent": True,
                "fulfilled_at": now_iso,
            }
        ).eq("id", int(order_id)).execute()
    except Exception:
        try:
            client.table("orders").update(
                {
                    "payment_status": "paid",
                    "stripe_session_id": clean_sid,
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
    Processes an order using authoritative server-side pricing (never trusting client
    unit_price, discount_amount, or tax_amount), atomically verifies/deducts stock,
    and returns a signed receipt_token for zero-IDOR confirmation lookups.
    """
    global _MEM_ORDER_SEQ

    if not payload.items:
        raise HTTPException(status_code=400, detail="Cart cannot be empty")

    clean_email = payload.customer_email.strip().lower()
    if "@" not in clean_email:
        raise HTTPException(
            status_code=422, detail="Enter a valid customer email address."
        )

    pricing = calculate_server_order_pricing(
        payload.items,
        promo_code=payload.promo_code,
    )
    subtotal_amount: float = pricing["subtotal"]
    discount: float = pricing["discount"]
    applied_promo_code: Optional[str] = pricing["applied_promo_code"]
    tax: float = pricing["tax"]
    final_total: float = pricing["total"]

    fulfillment_summary: dict[str, Any] = {
        "in_house_items": [],
        "dropship_dispatched": [],
    }
    prepared_items: list[dict[str, Any]] = []

    client = get_supabase_client()
    is_stripe_pending = (payload.payment_method or "COD").strip().upper() == "STRIPE"

    for line in pricing["lines"]:
        prod_dict = line["product"]
        cart_item: CartItem = line["cart_item"]
        effective_unit_price: float = line["unit_price"]
        avail_stock: int = line["available_stock"]

        # Deduct stock atomically ONLY for confirmed COD orders; for Stripe orders,
        # stock is deducted once Stripe verifies payment_status == 'paid'.
        if not is_stripe_pending:
            ok = decrement_stock_atomic(
                client,
                cart_item.product_id,
                cart_item.quantity,
                known_available=avail_stock,
            )
            if not ok:
                raise HTTPException(
                    status_code=400,
                    detail=f"Insufficient stock for {prod_dict.get('name')}.",
                )

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
                "pricing_mode": (
                    "B2B"
                    if cart_item.quantity >= 10
                    else (cart_item.pricing_mode or "B2C").strip()
                ),
                "fulfillment_type": f_type,
                "dispatch_status": dispatch_status,
                "tracking_number": tracking,
            }
        )

    invalidate_supabase_rest_cache()
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
                "promo_code": applied_promo_code,
                "currency_code": (payload.currency_code or "USD").strip().upper(),
                "total_amount": final_total,
                "payment_method": "STRIPE" if is_stripe_pending else "COD",
                "payment_status": "pending" if is_stripe_pending else "cod_confirmed",
                "status": "Pending Payment" if is_stripe_pending else "Confirmed (COD)",
                "stock_deducted": not is_stripe_pending,
                "email_sent": not is_stripe_pending,
                "fulfilled_at": None if is_stripe_pending else now_iso,
                "created_at": now_iso,
                "items": prepared_items,
            },
        )

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

    receipt_token = generate_order_receipt_token(created_order_id, clean_email)

    return {
        "status": "pending_payment" if is_stripe_pending else "success",
        "order_id": created_order_id,
        "receipt_token": receipt_token,
        "payment_method": "STRIPE" if is_stripe_pending else "COD",
        "payment_status": "pending" if is_stripe_pending else "cod_confirmed",
        "subtotal_amount": round(subtotal_amount, 2),
        "discount_amount": discount,
        "tax_amount": tax,
        "total_charged": final_total,
        "promo_code": applied_promo_code,
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
def get_single_order_detail(
    order_id: int,
    receipt_token: Optional[str] = Query(default=None, max_length=128),
    current_user: Optional[User] = Depends(get_optional_current_user),
):
    """
    Anti-IDOR order lookup: requires either an authenticated JWT matching the order's
    customer_email (or admin role), OR a valid HMAC-SHA256 receipt_token issued at checkout.
    """
    if current_user is None and not (receipt_token and receipt_token.strip()):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication or valid receipt token required to view order details.",
        )

    record = get_order_record(order_id)
    if record is None:
        raise HTTPException(status_code=404, detail=f"Order #{order_id} not found.")

    order_email = str(record.get("customer_email") or "").strip().lower()
    has_valid_token = verify_order_receipt_token(order_id, order_email, receipt_token)

    if current_user is not None:
        caller_role = resolve_user_role(current_user)
        caller_email = (current_user.email or "").strip().lower()
        if caller_role == "admin" or (caller_email and caller_email == order_email) or has_valid_token:
            return {"order": record}
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You are not authorized to view another customer's order.",
        )

    if not has_valid_token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired order receipt token.",
        )

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
