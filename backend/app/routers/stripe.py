
import os
import logging
from urllib.parse import urlparse

import stripe
from dotenv import load_dotenv
from fastapi import APIRouter, Request, HTTPException, Depends
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.database import SessionLocal, get_db
from app.models import Order
from app.adapters.supplier_adapter import DummyJSONAdapter

load_dotenv()

logger = logging.getLogger(__name__)

stripe.api_key = os.getenv("STRIPE_SECRET_KEY")
STRIPE_WEBHOOK_SECRET = os.getenv("STRIPE_WEBHOOK_SECRET")

FRONTEND_URL = os.getenv(
    "FRONTEND_URL",
    "http://localhost:8080",
).rstrip("/")

router = APIRouter(tags=["Stripe Checkout"])


class PaymentRequest(BaseModel):
    currency: str = "usd"
    order_id: int
    frontend_origin: str | None = None


def resolve_frontend_url(origin: str | None) -> str:
    if not origin:
        return FRONTEND_URL

    parsed = urlparse(origin)
    configured = urlparse(FRONTEND_URL)

    normalized = origin.rstrip("/")

    if (
        parsed.scheme == configured.scheme
        and parsed.netloc == configured.netloc
        and parsed.path in ("", "/")
        and not parsed.query
        and not parsed.fragment
        and not parsed.username
        and not parsed.password
    ):
        return normalized

    local_hosts = {"localhost", "127.0.0.1", "::1"}

    if (
        os.getenv("ALLOW_LOCAL_CHECKOUT", "false").lower() == "true"
        and parsed.scheme == "http"
        and parsed.hostname in local_hosts
        and parsed.port is not None
        and parsed.path in ("", "/")
        and not parsed.query
        and not parsed.fragment
        and not parsed.username
        and not parsed.password
    ):
        return normalized

    raise HTTPException(
        status_code=400,
        detail="Frontend origin is not permitted",
    )


@router.post("/create-payment-intent")
def create_payment_intent(data: PaymentRequest):
    raise HTTPException(
        status_code=501,
        detail="Payment Intent integration is not configured",
    )


@router.post("/create-checkout-session")
def create_checkout_session(
    data: PaymentRequest,
    db: Session = Depends(get_db),
):
    if not stripe.api_key:
        raise HTTPException(
            status_code=503,
            detail="Stripe is not configured",
        )

    frontend = resolve_frontend_url(data.frontend_origin)

    order = db.query(Order).filter(
        Order.id == data.order_id
    ).first()

    if not order:
        raise HTTPException(
            status_code=404,
            detail="Order not found",
        )

    amount = int(round(float(order.total_amount) * 100))

    if amount <= 0:
        raise HTTPException(
            status_code=400,
            detail="Invalid order amount",
        )

    if data.currency.lower() != "usd":
        raise HTTPException(
            status_code=400,
            detail="Unsupported checkout currency",
        )

    try:
        session = stripe.checkout.Session.create(
            payment_method_types=["card"],
            line_items=[
                {
                    "price_data": {
                        "currency": "usd",
                        "product_data": {
                            "name": f"Penguin Store Order #{order.id}",
                        },
                        "unit_amount": amount,
                    },
                    "quantity": 1,
                }
            ],
            mode="payment",
            success_url=(
                f"{frontend}/#/success"
                "?session_id={CHECKOUT_SESSION_ID}"
                f"&order_id={order.id}"
            ).replace(
                "{CHECKOUT_SESSION_ID}",
                "{CHECKOUT_SESSION_ID}",
            ),
            cancel_url=f"{frontend}/#/cancel",
            shipping_address_collection={
                "allowed_countries": ["US", "GB", "AE", "PK"],
            },
            metadata={
                "internal_order_id": str(order.id),
            },
        )

        return {
            "url": session.url,
            "session_id": session.id,
        }

    except stripe.error.StripeError:
        logger.exception("Stripe session creation failed")

        raise HTTPException(
            status_code=502,
            detail="Unable to create Stripe Checkout Session",
        )


@router.get("/api/payments/checkout-status")
def checkout_status(
    session_id: str,
):
    if not stripe.api_key:
        raise HTTPException(
            status_code=503,
            detail="Stripe is not configured",
        )

    try:
        session = stripe.checkout.Session.retrieve(session_id)

        return {
            "payment_status": session.payment_status,
            "checkout_status": session.status,
            "paid": session.payment_status == "paid",
        }

    except stripe.error.StripeError:
        raise HTTPException(
            status_code=400,
            detail="Unable to verify checkout session",
        )


@router.post("/webhook")
async def stripe_webhook(request: Request):
    if not STRIPE_WEBHOOK_SECRET:
        raise HTTPException(
            status_code=503,
            detail="Stripe webhook is not configured",
        )

    payload = await request.body()
    signature = request.headers.get("stripe-signature")

    if not signature:
        raise HTTPException(
            status_code=400,
            detail="Missing Stripe signature",
        )

    try:
        event = stripe.Webhook.construct_event(
            payload,
            signature,
            STRIPE_WEBHOOK_SECRET,
        )
    except (ValueError, stripe.error.SignatureVerificationError):
        raise HTTPException(
            status_code=400,
            detail="Invalid webhook payload or signature",
        )

    if event["type"] != "checkout.session.completed":
        return {"status": "ignored"}

    session_data = event["data"]["object"]

    if session_data.get("payment_status") != "paid":
        return {"status": "payment_pending"}

    metadata = session_data.get("metadata") or {}
    order_id = metadata.get("internal_order_id")

    if not order_id:
        logger.error("Webhook missing order ID")
        raise HTTPException(
            status_code=400,
            detail="Order metadata missing",
        )

    details = (
        session_data.get("collected_information", {}).get(
            "shipping_details"
        )
        or session_data.get("shipping_details")
        or session_data.get("customer_details")
        or {}
    )

    address = details.get("address") or {}
    customer_name = details.get("name") or "Valued Customer"

    line1 = address.get("line1") or "No Address Provided"
    city = address.get("city") or "No City Provided"
    postal_code = address.get("postal_code") or "00000"

    db = SessionLocal()

    try:
        order = db.query(Order).filter(
            Order.id == int(order_id)
        ).first()

        if not order:
            raise HTTPException(
                status_code=404,
                detail="Order not found",
            )

        adapter = DummyJSONAdapter()

        for item in order.items:
            if item.dispatch_status in (
                "DISPATCHED",
                "QUEUED_FOR_PACKING",
            ):
                continue

            if item.fulfillment_type == "DROPSHIP":
                dispatch_res = await adapter.place_order(
                    supplier_sku=str(item.product_id),
                    shipping_address={
                        "recipient": customer_name,
                        "address": line1,
                        "city": city,
                        "postal_code": postal_code,
                    },
                )

                item.tracking_number = dispatch_res.get(
                    "tracking_number"
                )
                item.dispatch_status = "DISPATCHED"

            else:
                item.dispatch_status = "QUEUED_FOR_PACKING"

        db.commit()

        logger.info(
            "Payment fulfillment processed for order %s",
            order_id,
        )

    except Exception:
        db.rollback()
        logger.exception(
            "Order fulfillment failed for order %s",
            order_id,
        )
        raise HTTPException(
            status_code=500,
            detail="Order fulfillment failed",
        )

    finally:
        db.close()

    return {"status": "success"}
