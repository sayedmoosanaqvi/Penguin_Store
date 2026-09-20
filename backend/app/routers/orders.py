from fastapi import APIRouter, HTTPException, Depends, BackgroundTasks
from pydantic import BaseModel
from typing import List, Optional
from sqlalchemy.orm import Session
from app.database import SessionLocal
from app.models import Product, Order, OrderItem, Notification
from app.adapters.supplier_adapter import DummyJSONAdapter

# Import the notification helpers
from app.email_utils import send_order_confirmation
from app.push_utils import send_push_notification

router = APIRouter(tags=["Order Dispatch"])

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

# Pydantic models for checkout validation
class CartItem(BaseModel):
    product_id: int
    quantity: int

class CheckoutRequest(BaseModel):
    customer_name: str
    customer_email: str
    shipping_address: str
    city: str
    state_province: Optional[str] = "Punjab"  # Added fallback
    country: Optional[str] = "Pakistan"       # Added fallback
    postal_code: str
    items: List[CartItem]

@router.post("/api/orders/checkout")
async def process_checkout(
    payload: CheckoutRequest, 
    background_tasks: BackgroundTasks, 
    db: Session = Depends(get_db)
):
    """
    Processes an order, verifies and deducts stock, splits fulfillment, 
    and triggers background email & push notifications.
    """
    if not payload.items:
        raise HTTPException(status_code=400, detail="Cart cannot be empty")

    adapter = DummyJSONAdapter()
    total_order_amount = 0.0
    order_items_to_create = []
    fulfillment_summary = {"in_house_items": [], "dropship_dispatched": []}

    try:
        # 1. Process each item in the cart, check stock, and deduct inventory
        for cart_item in payload.items:
            product = db.query(Product).filter(Product.id == cart_item.product_id).first()
            if not product:
                raise HTTPException(status_code=404, detail=f"Product ID {cart_item.product_id} not found")

            # Validate stock availability
            if product.stock < cart_item.quantity:
                raise HTTPException(
                    status_code=400, 
                    detail=f"Insufficient stock for {product.name}. Available: {product.stock}, Requested: {cart_item.quantity}"
                )

            # Deduct stock
            product.stock -= cart_item.quantity

            line_total = product.price * cart_item.quantity
            total_order_amount += line_total

            # 2. Check fulfillment type
            if product.fulfillment_type == "DROPSHIP":
                # Forward to supplier adapter
                dispatch_res = await adapter.place_order(
                    supplier_sku=product.supplier_sku or str(product.id),
                    shipping_address={
                        "recipient": payload.customer_name,
                        "address": payload.shipping_address,
                        "city": payload.city,
                        "postal_code": payload.postal_code
                    }
                )
                
                order_items_to_create.append(OrderItem(
                    product_id=product.id,
                    quantity=cart_item.quantity,
                    unit_price=product.price,
                    fulfillment_type="DROPSHIP",
                    dispatch_status="DISPATCHED",
                    tracking_number=dispatch_res.get("tracking_number")
                ))
                fulfillment_summary["dropship_dispatched"].append({
                    "product": product.name,
                    "tracking": dispatch_res.get("tracking_number")
                })
            else:
                # In-house fulfillment
                order_items_to_create.append(OrderItem(
                    product_id=product.id,
                    quantity=cart_item.quantity,
                    unit_price=product.price,
                    fulfillment_type="IN_HOUSE",
                    dispatch_status="QUEUED_FOR_PACKING",
                    tracking_number=f"LOCAL-PK-{product.id}-001"
                ))
                fulfillment_summary["in_house_items"].append(product.name)

        # 3. Save order record to PostgreSQL
        new_order = Order(
            customer_name=payload.customer_name,
            customer_email=payload.customer_email,
            shipping_address=payload.shipping_address,
            city=payload.city,
            state_province=payload.state_province or "Punjab", # Catch nulls here
            country=payload.country or "Pakistan",             # Catch nulls here
            postal_code=payload.postal_code,
            total_amount=total_order_amount,
            items=order_items_to_create
        )
        db.add(new_order)
        db.commit()
        db.refresh(new_order)

        # ---> IN-APP NOTIFICATION CREATION <---
        in_app_notif = Notification(
            customer_email=payload.customer_email,
            title="Order Confirmed! 📦",
            message=f"Your order #{new_order.id} has been placed successfully and is being processed.",
            notification_type="ORDER"
        )
        db.add(in_app_notif)
        db.commit()

        # 4. TRIGGER NOTIFICATIONS (Runs in the background)
        # Send Email Receipt
        background_tasks.add_task(
            send_order_confirmation, 
            payload.customer_email, 
            new_order.id
        )
        
        # Send Push Notification to phone
        background_tasks.add_task(
            send_push_notification, 
            payload.customer_email, 
            "Payment Successful! 🎉", 
            f"Your order #{new_order.id} is confirmed and being processed."
        )

        return {
            "status": "success",
            "order_id": new_order.id,
            "total_charged": round(total_order_amount, 2),
            "fulfillment_routing": fulfillment_summary
        }

    except HTTPException as he:
        db.rollback()
        raise he
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/api/orders/history/{customer_email}")
def get_order_history(customer_email: str, db: Session = Depends(get_db)):
    """
    Retrieves all past orders, line items, and tracking/fulfillment status for a given customer email.
    """
    orders = db.query(Order).filter(Order.customer_email == customer_email).all()
    
    if not orders:
        return {"customer_email": customer_email, "orders": []}

    result = []
    for order in orders:
        items_list = []
        for item in order.items:
            product = db.query(Product).filter(Product.id == item.product_id).first()
            items_list.append({
                "product_id": item.product_id,
                "product_name": product.name if product else "Unknown Product",
                "quantity": item.quantity,
                "unit_price": item.unit_price,
                "fulfillment_type": item.fulfillment_type,
                "dispatch_status": item.dispatch_status,
                "tracking_number": item.tracking_number
            })
            
        result.append({
            "order_id": order.id,
            "total_amount": order.total_amount,
            "shipping_address": order.shipping_address,
            "city": order.city,
            "postal_code": order.postal_code,
            "created_at": order.created_at.isoformat(),
            "items": items_list
        })

    return {"customer_email": customer_email, "orders": result}