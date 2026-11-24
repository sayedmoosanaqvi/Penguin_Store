
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
    """
    Resolve the safe frontend return base URL for Stripe Checkout redirects.
    Supports:
    - Local Flutter Web development on any localhost / 127.0.0.1 port
    - GitHub Pages subpaths (e.g. https://<user>.github.io/Penguin_Store)
    - Custom production domains matching FRONTEND_URL
    """
    if not origin or not origin.strip():
        return FRONTEND_URL

    cleaned = origin.strip().rstrip("/")
    parsed = urlparse(cleaned)

    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        return FRONTEND_URL

    # Allow any localhost / 127.0.0.1 origin for local Flutter Web testing
    if parsed.hostname in {"localhost", "127.0.0.1", "::1"}:
        return cleaned

    # Allow github.io (including /Penguin_Store base-href path), penguinstore.co, or configured FRONTEND_URL host
    configured = urlparse(FRONTEND_URL)
    is_allowed_domain = (
        parsed.hostname == configured.hostname
        or (parsed.hostname and parsed.hostname.endswith(".github.io"))
        or parsed.hostname in {"penguinstore.co", "www.penguinstore.co"}
    )
    if is_allowed_domain:
        if parsed.path and parsed.path not in ("", "/"):
            return f"{parsed.scheme}://{parsed.netloc}{parsed.path.rstrip('/')}"
        # Only attach configured subpath (e.g. /Penguin_Store) if host is github.io or matches configured host
        if (
            (parsed.hostname and parsed.hostname.endswith(".github.io"))
            or parsed.hostname == configured.hostname
        ) and configured.path and configured.path not in ("", "/"):
            return f"{parsed.scheme}://{parsed.netloc}{configured.path.rstrip('/')}"
        return f"{parsed.scheme}://{parsed.netloc}"

    return FRONTEND_URL


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


# Existing & v1 one-time product checkout session (Supabase HTTPS + memory-aware)
@router.post("/create-checkout-session")
@router.post("/api/v1/stripe/create-checkout-session")
def create_checkout_session(
    data: PaymentRequest,
):
    require_stripe()

    frontend = resolve_frontend_url(data.frontend_origin)

    from app.routers.orders import generate_order_receipt_token, get_order_record

    order_record = get_order_record(data.order_id)
    if not order_record:
        raise HTTPException(
            status_code=404,
            detail=f"Order #{data.order_id} not found.",
        )

    total_usd = float(order_record.get("total_amount") or 0.0)
    amount_cents = int(round(total_usd * 100))

    if amount_cents < 50:
        amount_cents = 50  # Stripe minimum charge is $0.50 USD

    # Build itemized summary for the Stripe Checkout page
    items = order_record.get("items") or []
    item_descriptions = []
    for item in items[:5]:
        p_name = item.get("product_name") or f"Product #{item.get('product_id')}"
        qty = item.get("quantity", 1)
        variant = item.get("selected_variant")
        addons = item.get("selected_addons") or []
        tag_parts = [p for p in [variant, *addons] if p]
        tag_str = f" ({', '.join(tag_parts)})" if tag_parts else ""
        item_descriptions.append(f"{qty}x {p_name}{tag_str}")

    summary_desc = (
        " • ".join(item_descriptions)
        if item_descriptions
        else f"Penguin Store Order #{data.order_id}"
    )
    if order_record.get("promo_code"):
        summary_desc += f" [Promo: {order_record['promo_code']}]"

    customer_email = str(order_record.get("customer_email") or "").strip() or None
    receipt_token = (
        generate_order_receipt_token(data.order_id, customer_email)
        if customer_email
        else ""
    )

    try:
        session = stripe.checkout.Session.create(
            payment_method_types=["card"],
            customer_email=customer_email,
            line_items=[
                {
                    "price_data": {
                        "currency": "usd",
                        "product_data": {
                            "name": f"Penguin Store Order #{data.order_id}",
                            "description": summary_desc[:450],
                        },
                        "unit_amount": amount_cents,
                    },
                    "quantity": 1,
                }
            ],
            mode="payment",
            success_url=(
                f"{frontend}/#/checkout-success"
                f"?session_id={{CHECKOUT_SESSION_ID}}"
                f"&order_id={data.order_id}"
                f"&receipt_token={receipt_token}"
            ),
            cancel_url=f"{frontend}/#/checkout-cancel?order_id={data.order_id}",
            metadata={
                "internal_order_id": str(data.order_id),
                "customer_email": customer_email or "",
            },
        )

        return {
            "url": session.url,
            "checkout_url": session.url,
            "session_id": session.id,
            "order_id": data.order_id,
            "receipt_token": receipt_token,
        }

    except stripe.error.StripeError as exc:
        logger.exception("Product checkout session failed: %s", exc)
        raise HTTPException(
            status_code=502,
            detail="Unable to create Stripe Checkout Session.",
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


# Verify Stripe Checkout session & finalize order + email idempotently (Phase 2.1)
@router.get("/api/payments/checkout-status")
@router.get("/api/v1/stripe/verify-session/{session_id}")
async def verify_stripe_checkout_session(
    session_id: str,
    order_id: int | None = None,
):
    require_stripe()

    try:
        session = stripe.checkout.Session.retrieve(session_id)

        if session.mode != "payment":
            raise HTTPException(
                status_code=400,
                detail="Not a product payment session.",
            )

        is_paid = session.payment_status == "paid"
        metadata = session.get("metadata") or {}
        resolved_order_id = order_id
        if resolved_order_id is None and metadata.get("internal_order_id"):
            try:
                resolved_order_id = int(metadata["internal_order_id"])
            except (TypeError, ValueError):
                resolved_order_id = None

        order_record = None
        if is_paid and resolved_order_id is not None:
            from app.routers.orders import finalize_paid_stripe_order

            order_record = await finalize_paid_stripe_order(
                order_id=resolved_order_id,
                session_id=session_id,
            )
        elif resolved_order_id is not None:
            from app.routers.orders import get_order_record

            order_record = get_order_record(resolved_order_id)

        receipt_token = ""
        if order_record and resolved_order_id is not None:
            from app.routers.orders import generate_order_receipt_token

            ord_email = str(order_record.get("customer_email") or "").strip()
            if ord_email:
                receipt_token = generate_order_receipt_token(resolved_order_id, ord_email)

        return {
            "session_id": session_id,
            "order_id": resolved_order_id,
            "receipt_token": receipt_token,
            "payment_status": session.payment_status,
            "checkout_status": session.status,
            "paid": is_paid,
            "order": order_record,
        }

    except HTTPException:
        raise

    except stripe.error.StripeError:
        raise HTTPException(
            status_code=400,
            detail="Unable to verify checkout session.",
        )


async def _fulfill_paid_order(session_data):
    metadata = session_data.get("metadata") or {}
    order_id = metadata.get("internal_order_id")
    session_id = session_data.get("id") or ""

    if not order_id:
        logger.error("Product webhook missing order ID.")
        return False

    try:
        from app.routers.orders import finalize_paid_stripe_order

        record = await finalize_paid_stripe_order(
            order_id=int(order_id),
            session_id=str(session_id),
        )
        return record is not None
    except Exception:
        logger.exception("Stripe webhook order fulfillment failed for order %s", order_id)
        return False


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
@router.post("/api/v1/stripe/webhook")
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
