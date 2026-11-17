
import os
import logging
from datetime import datetime, timezone
from urllib.parse import urlparse

import stripe
from dotenv import load_dotenv
from fastapi import (
    APIRouter,
    Request,
    HTTPException,
    Depends,
)
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.database import SessionLocal, get_db
from app.models import (
    Order,
    User,
    PremiumSubscription,
)
from app.security import get_current_user
from app.adapters.supplier_adapter import DummyJSONAdapter

load_dotenv()

logger = logging.getLogger(__name__)

stripe.api_key = os.getenv("STRIPE_SECRET_KEY")

STRIPE_WEBHOOK_SECRET = os.getenv(
    "STRIPE_WEBHOOK_SECRET"
)

STRIPE_PREMIUM_PRICE_ID = os.getenv(
    "STRIPE_PREMIUM_PRICE_ID",
    "",
).strip()

FRONTEND_URL = os.getenv(
    "FRONTEND_URL",
    "http://localhost:8080",
).rstrip("/")

ENVIRONMENT = os.getenv(
    "ENVIRONMENT",
    "development",
).lower()

router = APIRouter(tags=["Stripe Checkout"])


class PaymentRequest(BaseModel):
    currency: str = "usd"
    order_id: int
    frontend_origin: str | None = None


class SubscriptionCheckoutRequest(BaseModel):
    frontend_origin: str | None = None


def require_stripe():
    if not stripe.api_key:
        raise HTTPException(
            status_code=503,
            detail="Stripe is not configured.",
        )

    if (
        ENVIRONMENT != "production"
        and stripe.api_key.startswith("sk_live_")
    ):
        raise HTTPException(
            status_code=503,
            detail=(
                "Live Stripe payments are disabled "
                "in the local environment."
            ),
        )


def resolve_frontend_url(origin: str | None) -> str:
    if not origin:
        return FRONTEND_URL

    parsed = urlparse(origin)
    configured = urlparse(FRONTEND_URL)

    normalized = origin.rstrip("/")

    valid_origin = (
        parsed.scheme in ("http", "https")
        and bool(parsed.netloc)
        and parsed.path in ("", "/")
        and not parsed.query
        and not parsed.fragment
        and not parsed.username
        and not parsed.password
    )

    if not valid_origin:
        raise HTTPException(
            status_code=400,
            detail="Invalid frontend origin.",
        )

    if (
        parsed.scheme == configured.scheme
        and parsed.netloc == configured.netloc
    ):
        return FRONTEND_URL

    local_hosts = {
        "localhost",
        "127.0.0.1",
        "::1",
    }

    if (
        ENVIRONMENT == "development"
        and os.getenv(
            "ALLOW_LOCAL_CHECKOUT",
            "false",
        ).lower() == "true"
        and parsed.scheme == "http"
        and parsed.hostname in local_hosts
        and parsed.port is not None
    ):
        return normalized

    raise HTTPException(
        status_code=400,
        detail="Frontend origin is not permitted.",
    )


def _stripe_id(value):
    if isinstance(value, str):
        return value

    if isinstance(value, dict):
        return value.get("id")

    return None


def _stripe_datetime(timestamp):
    if timestamp is None:
        return None

    try:
        return datetime.fromtimestamp(
            int(timestamp),
            tz=timezone.utc,
        )
    except (TypeError, ValueError, OverflowError):
        return None


def _subscription_period_and_price(subscription):
    items = (
        (subscription.get("items") or {})
        .get("data") or []
    )

    for item in items:
        price = item.get("price") or {}

        price_id = _stripe_id(price)

        if price_id == STRIPE_PREMIUM_PRICE_ID:
            period_end = (
                item.get("current_period_end")
                or subscription.get("current_period_end")
            )

            return (
                _stripe_datetime(period_end),
                price_id,
            )

    return None, None


def _sync_subscription(db: Session, subscription):
    subscription_id = _stripe_id(
        subscription.get("id")
    )

    customer_id = _stripe_id(
        subscription.get("customer")
    )

    metadata = subscription.get("metadata") or {}
    user_id = metadata.get("penguin_user_id")

    record = None

    if subscription_id:
        record = db.query(PremiumSubscription).filter(
            PremiumSubscription.stripe_subscription_id
            == subscription_id
        ).first()

    if record is None and customer_id:
        record = db.query(PremiumSubscription).filter(
            PremiumSubscription.stripe_customer_id
            == customer_id
        ).first()

    if record is None and user_id:
        try:
            user_id_int = int(user_id)
        except (TypeError, ValueError):
            logger.warning(
                "Invalid subscription user metadata."
            )
            return False

        user = db.get(User, user_id_int)

        if user is None:
            logger.warning(
                "Subscription references unknown user."
            )
            return False

        record = db.query(PremiumSubscription).filter(
            PremiumSubscription.user_id
            == user.id
        ).first()

        if record is None:
            record = PremiumSubscription(
                user_id=user.id,
            )
            db.add(record)

    if record is None:
        logger.warning(
            "No Penguin Store account found "
            "for subscription %s",
            subscription_id,
        )
        return False

    if (
        record.stripe_subscription_id
        and record.stripe_subscription_id
        != subscription_id
        and record.status not in (
            "canceled",
            "incomplete_expired",
            "inactive",
        )
    ):
        logger.warning(
            "Subscription mismatch for user %s",
            record.user_id,
        )
        return False

    period_end, price_id = (
        _subscription_period_and_price(subscription)
    )

    subscription_status = subscription.get(
        "status",
        "inactive",
    )

    if not price_id:
        logger.warning(
            "Subscription %s is not on "
            "the configured Premium price.",
            subscription_id,
        )
        subscription_status = "inactive"

    record.stripe_customer_id = customer_id
    record.stripe_subscription_id = subscription_id
    record.stripe_price_id = price_id
    record.plan_name = "premium"
    record.status = subscription_status
    record.current_period_end = period_end
    record.cancel_at_period_end = bool(
        subscription.get("cancel_at_period_end", False)
    )

    db.commit()

    logger.info(
        "Premium subscription synchronized for user %s",
        record.user_id,
    )

    return True


def _sync_subscription_from_stripe(subscription_id):
    subscription = stripe.Subscription.retrieve(
        subscription_id
    )

    db = SessionLocal()

    try:
        return _sync_subscription(
            db,
            subscription,
        )
    except Exception:
        db.rollback()
        logger.exception(
            "Premium subscription sync failed."
        )
        raise
    finally:
        db.close()


def _ensure_customer(
    user: User,
    db: Session,
) -> str:
    record = db.query(PremiumSubscription).filter(
        PremiumSubscription.user_id == user.id
    ).first()

    if record and record.stripe_customer_id:
        return record.stripe_customer_id

    customer = stripe.Customer.create(
        email=user.email,
        metadata={
            "penguin_user_id": str(user.id),
        },
        idempotency_key=(
            f"penguin-premium-customer-{user.id}"
        ),
    )

    if record is None:
        record = PremiumSubscription(
            user_id=user.id,
            status="inactive",
            plan_name="premium",
        )

        db.add(record)

    record.stripe_customer_id = customer.id

    try:
        db.commit()
    except Exception:
        db.rollback()
        logger.exception(
            "Unable to save Stripe customer."
        )
        raise HTTPException(
            status_code=503,
            detail="Unable to prepare billing account.",
        )

    return customer.id


# Existing one-time Payment Intent placeholder
@router.post("/create-payment-intent")
def create_payment_intent(data: PaymentRequest):
    raise HTTPException(
        status_code=501,
        detail=(
            "Payment Intent integration "
            "is not configured."
        ),
    )


# Existing one-time product checkout
@router.post("/create-checkout-session")
def create_checkout_session(
    data: PaymentRequest,
    db: Session = Depends(get_db),
):
    require_stripe()

    frontend = resolve_frontend_url(
        data.frontend_origin
    )

    order = db.query(Order).filter(
        Order.id == data.order_id
    ).first()

    if not order:
        raise HTTPException(
            status_code=404,
            detail="Order not found.",
        )

    amount = int(
        round(float(order.total_amount) * 100)
    )

    if amount <= 0:
        raise HTTPException(
            status_code=400,
            detail="Invalid order amount.",
        )

    if data.currency.lower() != "usd":
        raise HTTPException(
            status_code=400,
            detail="Unsupported checkout currency.",
        )

    try:
        session = stripe.checkout.Session.create(
            payment_method_types=["card"],
            line_items=[
                {
                    "price_data": {
                        "currency": "usd",
                        "product_data": {
                            "name": (
                                f"Penguin Store Order #{order.id}"
                            ),
                        },
                        "unit_amount": amount,
                    },
                    "quantity": 1,
                }
            ],
            mode="payment",
            success_url=(
                f"{frontend}/#/success"
                f"?session_id={{CHECKOUT_SESSION_ID}}"
                f"&order_id={order.id}"
            ),
            cancel_url=f"{frontend}/#/cancel",
            shipping_address_collection={
                "allowed_countries": [
                    "US",
                    "GB",
                    "AE",
                    "PK",
                ],
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
        logger.exception(
            "Product checkout session failed."
        )

        raise HTTPException(
            status_code=502,
            detail=(
                "Unable to create Stripe "
                "Checkout Session."
            ),
        )


# New recurring Premium checkout
@router.post("/api/premium-subscriptions/checkout")
def create_premium_checkout(
    data: SubscriptionCheckoutRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    require_stripe()

    if not STRIPE_PREMIUM_PRICE_ID:
        raise HTTPException(
            status_code=503,
            detail=(
                "Premium subscription pricing "
                "is not configured yet."
            ),
        )

    frontend = resolve_frontend_url(
        data.frontend_origin
    )

    existing = db.query(PremiumSubscription).filter(
        PremiumSubscription.user_id
        == current_user.id
    ).first()

    if (
        existing is not None
        and existing.stripe_subscription_id
        and existing.status in (
            "active",
            "trialing",
            "past_due",
            "unpaid",
            "paused",
        )
    ):
        raise HTTPException(
            status_code=409,
            detail=(
                "An existing subscription is linked "
                "to this account. Manage it through "
                "the billing portal."
            ),
        )

    try:
        customer_id = _ensure_customer(
            current_user,
            db,
        )

        session = stripe.checkout.Session.create(
            customer=customer_id,
            mode="subscription",
            payment_method_types=["card"],
            line_items=[
                {
                    "price": STRIPE_PREMIUM_PRICE_ID,
                    "quantity": 1,
                }
            ],
            client_reference_id=str(current_user.id),
            metadata={
                "penguin_user_id": str(current_user.id),
                "checkout_type": "premium_3d",
            },
            subscription_data={
                "metadata": {
                    "penguin_user_id": str(
                        current_user.id
                    ),
                    "product": "penguin_premium_3d",
                }
            },
            success_url=(
                f"{frontend}/#/"
                "?premium_checkout=success"
                "&session_id={CHECKOUT_SESSION_ID}"
            ),
            cancel_url=(
                f"{frontend}/#/"
                "?premium_checkout=cancel"
            ),
        )

        return {
            "url": session.url,
            "session_id": session.id,
        }

    except HTTPException:
        raise

    except stripe.error.StripeError:
        logger.exception(
            "Premium checkout session failed."
        )

        raise HTTPException(
            status_code=502,
            detail=(
                "Unable to create Premium "
                "Checkout Session."
            ),
        )


# New Stripe billing management portal
@router.post("/api/premium-subscriptions/portal")
def create_premium_billing_portal(
    data: SubscriptionCheckoutRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    require_stripe()

    frontend = resolve_frontend_url(
        data.frontend_origin
    )

    subscription = db.query(
        PremiumSubscription
    ).filter(
        PremiumSubscription.user_id
        == current_user.id
    ).first()

    if (
        subscription is None
        or not subscription.stripe_customer_id
    ):
        raise HTTPException(
            status_code=404,
            detail="No billing account found.",
        )

    try:
        session = stripe.billing_portal.Session.create(
            customer=subscription.stripe_customer_id,
            return_url=f"{frontend}/#/",
        )

        return {
            "url": session.url,
        }

    except stripe.error.StripeError:
        logger.exception(
            "Unable to open billing portal."
        )

        raise HTTPException(
            status_code=502,
            detail="Unable to open billing portal.",
        )


# Existing one-time payment status
@router.get("/api/payments/checkout-status")
def checkout_status(session_id: str):
    require_stripe()

    try:
        session = stripe.checkout.Session.retrieve(
            session_id
        )

        if session.mode != "payment":
            raise HTTPException(
                status_code=400,
                detail="Not a product payment session.",
            )

        return {
            "payment_status": session.payment_status,
            "checkout_status": session.status,
            "paid": (
                session.payment_status == "paid"
            ),
        }

    except HTTPException:
        raise

    except stripe.error.StripeError:
        raise HTTPException(
            status_code=400,
            detail=(
                "Unable to verify checkout session."
            ),
        )


async def _fulfill_paid_order(session_data):
    metadata = session_data.get("metadata") or {}
    order_id = metadata.get("internal_order_id")

    if not order_id:
        logger.error(
            "Product webhook missing order ID."
        )
        return False

    collected = (
        session_data.get("collected_information")
        or {}
    )

    details = (
        collected.get("shipping_details")
        or session_data.get("shipping_details")
        or session_data.get("customer_details")
        or {}
    )

    address = details.get("address") or {}

    customer_name = (
        details.get("name")
        or "Valued Customer"
    )

    line1 = (
        address.get("line1")
        or "No Address Provided"
    )

    city = (
        address.get("city")
        or "No City Provided"
    )

    postal_code = (
        address.get("postal_code")
        or "00000"
    )

    db = SessionLocal()

    try:
        order = db.query(Order).filter(
            Order.id == int(order_id)
        ).first()

        if not order:
            logger.error(
                "Webhook order %s not found.",
                order_id,
            )
            return False

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

                item.tracking_number = (
                    dispatch_res.get("tracking_number")
                )

                item.dispatch_status = "DISPATCHED"

            else:
                item.dispatch_status = (
                    "QUEUED_FOR_PACKING"
                )

        db.commit()

        logger.info(
            "Product order %s fulfilled.",
            order_id,
        )

        return True

    except Exception:
        db.rollback()
        logger.exception(
            "Order fulfillment failed."
        )
        raise

    finally:
        db.close()


def _mark_subscription_canceled(subscription_data):
    subscription_id = _stripe_id(
        subscription_data.get("id")
    )

    db = SessionLocal()

    try:
        record = db.query(PremiumSubscription).filter(
            PremiumSubscription.stripe_subscription_id
            == subscription_id
        ).first()

        if record is None:
            return False

        record.status = "canceled"
        record.cancel_at_period_end = False

        db.commit()

        return True

    except Exception:
        db.rollback()
        raise

    finally:
        db.close()


def _invoice_subscription_id(invoice):
    direct = _stripe_id(
        invoice.get("subscription")
    )

    if direct:
        return direct

    parent = invoice.get("parent") or {}

    details = (
        parent.get("subscription_details")
        or {}
    )

    return _stripe_id(
        details.get("subscription")
    )


# Shared verified Stripe webhook
@router.post("/webhook")
async def stripe_webhook(request: Request):
    if not STRIPE_WEBHOOK_SECRET:
        raise HTTPException(
            status_code=503,
            detail="Stripe webhook is not configured.",
        )

    payload = await request.body()

    signature = request.headers.get(
        "stripe-signature"
    )

    if not signature:
        raise HTTPException(
            status_code=400,
            detail="Missing Stripe signature.",
        )

    try:
        event = stripe.Webhook.construct_event(
            payload,
            signature,
            STRIPE_WEBHOOK_SECRET,
        )

    except (
        ValueError,
        stripe.error.SignatureVerificationError,
    ):
        raise HTTPException(
            status_code=400,
            detail="Invalid Stripe webhook signature.",
        )

    event_type = event["type"]
    event_data = event["data"]["object"]

    try:
        if event_type in (
            "checkout.session.completed",
            "checkout.session.async_payment_succeeded",
        ):
            mode = event_data.get("mode")

            if mode == "subscription":
                subscription_id = _stripe_id(
                    event_data.get("subscription")
                )

                if not subscription_id:
                    return {
                        "status": "subscription_pending"
                    }

                synced = _sync_subscription_from_stripe(
                    subscription_id
                )

                return {
                    "status": (
                        "subscription_synced"
                        if synced
                        else "subscription_unmatched"
                    ),
                }

            if mode == "payment":
                if event_data.get("payment_status") != "paid":
                    return {
                        "status": "payment_pending"
                    }

                fulfilled = await _fulfill_paid_order(
                    event_data
                )

                if not fulfilled:
                    raise HTTPException(
                        status_code=500,
                        detail="Order fulfillment not completed.",
                    )

                return {
                    "status": "order_fulfilled"
                }

        if event_type in (
            "customer.subscription.created",
            "customer.subscription.updated",
            "customer.subscription.resumed",
        ):
            subscription_id = _stripe_id(
                event_data.get("id")
            )

            if subscription_id:
                synced = _sync_subscription_from_stripe(
                    subscription_id
                )

                return {
                    "status": (
                        "subscription_synced"
                        if synced
                        else "subscription_unmatched"
                    ),
                }

        if event_type == "customer.subscription.deleted":
            canceled = _mark_subscription_canceled(
                event_data
            )

            return {
                "status": (
                    "subscription_canceled"
                    if canceled
                    else "subscription_unmatched"
                ),
            }

        if event_type in (
            "invoice.paid",
            "invoice.payment_failed",
        ):
            subscription_id = _invoice_subscription_id(
                event_data
            )

            if subscription_id:
                synced = _sync_subscription_from_stripe(
                    subscription_id
                )

                return {
                    "status": (
                        "subscription_synced"
                        if synced
                        else "subscription_unmatched"
                    ),
                }

        return {
            "status": "ignored"
        }

    except HTTPException:
        raise

    except Exception:
        logger.exception(
            "Stripe webhook processing failed: %s",
            event_type,
        )

        raise HTTPException(
            status_code=500,
            detail="Stripe webhook processing failed.",
        )
