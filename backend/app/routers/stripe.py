from fastapi import APIRouter, Request, HTTPException, Depends
from pydantic import BaseModel
from sqlalchemy.orm import Session
import stripe
import os
from dotenv import load_dotenv

# Your database and adapter imports
from app.database import SessionLocal, get_db
from app.models import Order
from app.adapters.supplier_adapter import DummyJSONAdapter

load_dotenv()

stripe.api_key = os.getenv("STRIPE_SECRET_KEY")
STRIPE_WEBHOOK_SECRET = os.getenv("STRIPE_WEBHOOK_SECRET")

# Load production-ready frontend URL from .env (defaults to localhost:8080 if not set)
FRONTEND_URL = os.getenv("FRONTEND_URL", "http://localhost:8080")

router = APIRouter(tags=["Stripe Checkout"])

class PaymentRequest(BaseModel):
    currency: str = "usd"
    order_id: int 

@router.post("/create-payment-intent")
def create_payment_intent(data: PaymentRequest):
    pass

@router.post("/create-checkout-session")
def create_checkout_session(data: PaymentRequest, db: Session = Depends(get_db)):
    # 1. Securely fetch the real order from the database
    order = db.query(Order).filter(Order.id == data.order_id).first()
    
    if not order:
        raise HTTPException(status_code=404, detail="Order not found")

    # 2. Calculate the true total price directly from your database
    secure_total_in_cents = int(order.total_amount * 100)

    # 3. Create the session using dynamic environment-based URLs
    session = stripe.checkout.Session.create(
        payment_method_types=['card'],
        line_items=[{
            'price_data': {
                'currency': data.currency,
                'product_data': {
                    'name': f'Penguin Store Order #{order.id}',
                },
                'unit_amount': secure_total_in_cents,
            },
            'quantity': 1,
        }],
        mode='payment',
        success_url=f'{FRONTEND_URL}/#/success',
        cancel_url=f'{FRONTEND_URL}/#/cancel',
        
        shipping_address_collection={
            'allowed_countries': ['US', 'GB', 'AE', 'PK'], 
        },
        metadata={
            "internal_order_id": str(order.id) 
        }
    )
    return {"url": session.url}

# 4. The Webhook Listener that receives data AFTER payment
@router.post("/webhook")
async def stripe_webhook(request: Request):
    payload = await request.body()
    sig_header = request.headers.get("stripe-signature")

    try:
        event = stripe.Webhook.construct_event(
            payload, sig_header, STRIPE_WEBHOOK_SECRET
        )
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

    if event['type'] == 'checkout.session.completed':
        session_dict = event['data']['object'].to_dict()
        order_id = session_dict.get('metadata', {}).get('internal_order_id')
        
        details = session_dict.get('shipping_details') or session_dict.get('customer_details') or {}
        address = details.get('address', {})
        customer_name = details.get('name', 'Valued Customer')
        
        line1 = address.get('line1', 'No Address Provided')
        city = address.get('city', 'No City Provided')
        postal_code = address.get('postal_code', '00000')

        print(f"\n✅ PAYMENT SUCCESSFUL: Order {order_id}")
        print(f"📦 Shipping To: {customer_name}, {line1}, {city}")

        # === ENTERPRISE DISPATCH LOGIC ===
        if order_id:
            db = SessionLocal()
            adapter = DummyJSONAdapter()
            try:
                order = db.query(Order).filter(Order.id == int(order_id)).first()
                if order:
                    print("⚙️ Processing routing engine rules...")
                    
                    for item in order.items:
                        if item.fulfillment_type == "DROPSHIP":
                            print(f"🚀 API DISPATCH: Sending Product ID {item.product_id} to supplier...")
                            
                            dispatch_res = await adapter.place_order(
                                supplier_sku=str(item.product_id),
                                shipping_address={
                                    "recipient": customer_name,
                                    "address": line1,
                                    "city": city,
                                    "postal_code": postal_code
                                }
                            )
                            
                            item.tracking_number = dispatch_res.get("tracking_number")
                            item.dispatch_status = "DISPATCHED"
                            print(f"🏷️ Supplier Tracking Number Received: {item.tracking_number}")
                            
                        else:
                            print(f"🏢 IN-HOUSE DISPATCH: Queuing Product ID {item.product_id} for local Sargodha packing.")
                            item.dispatch_status = "QUEUED_FOR_PACKING"
                            
                    db.commit()
            except Exception as e:
                print(f"❌ Dispatch Error: {str(e)}")
            finally:
                db.close()

    return {"status": "success"}