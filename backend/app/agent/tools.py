import json
from typing import Optional, Union
from pydantic import BaseModel, Field
from langchain_core.tools import tool
from sqlalchemy.orm import Session
from app.database import SessionLocal
from app.models import Product, Order
from app.agent.rag import retrieve_store_knowledge

class ProductSearchInput(BaseModel):
    search_term: Optional[str] = Field(None, description="Specific keyword to search in product names (e.g., 'perfume', 'boots', 'headphones').")
    category: Optional[str] = Field(None, description="The category of the product (e.g., 'ELECTRONICS', 'SMARTPHONES', 'FRAGRANCES').")
    max_price: Optional[float] = Field(None, description="The absolute maximum price the user is willing to pay.")
    is_featured: Optional[bool] = Field(None, description="Set to True if the user specifically asks for featured or trending items.")

@tool("search_inventory", args_schema=ProductSearchInput)
def search_inventory(search_term: Optional[str] = None, category: Optional[str] = None, max_price: Optional[float] = None, is_featured: Optional[bool] = None) -> str:
    """
    Searches the live PostgreSQL database for products based on keywords, category, maximum price, and featured status.
    Always use this tool when a user asks for product recommendations, prices, or availability.
    """
    print(f"\n[TOOL CALLED] search_inventory with: search_term={search_term}, category={category}, max_price={max_price}, is_featured={is_featured}")
    
    db: Session = SessionLocal()
    try:
        query = db.query(Product)
        
        if search_term:
            query = query.filter(Product.name.ilike(f"%{search_term}%"))
            
        if category:
            query = query.filter(Product.category.ilike(f"%{category}%"))
        if max_price is not None:
            query = query.filter(Product.price <= max_price)
        if is_featured is not None:
            query = query.filter(Product.is_featured == is_featured)
            
        products = query.limit(5).all()
        
        results = [
            {
                "id": p.id,
                "name": p.name,
                "price": p.price,
                "category": p.category,
                "is_featured": p.is_featured,
                "fulfillment_type": getattr(p, "fulfillment_type", "IN_HOUSE") or "IN_HOUSE"
            } for p in products
        ]
        
        print(f"[TOOL RESULT] Found {len(results)} products: {results}\n")
        return json.dumps(results)
    except Exception as e:
        print(f"[TOOL ERROR] {str(e)}")
        return "[]"
    finally:
        db.close()


class AddToCartInput(BaseModel):
    product_id: int = Field(..., description="The ID of the product to add to cart.")
    quantity: int = Field(default=1, description="The number of items to add.")

@tool("add_to_cart", args_schema=AddToCartInput)
def add_to_cart(product_id: int, quantity: int = 1) -> str:
    """
    Executes a cart addition. Always use this tool when a user asks to buy a product, 
    add it to their cart, or purchase an item. You must pass the exact product_id.
    """
    print(f"\n[TOOL CALLED] add_to_cart with: product_id={product_id}, quantity={quantity}")
    
    db: Session = SessionLocal()
    try:
        p = db.query(Product).filter(Product.id == product_id).first()
        if not p:
            return json.dumps({"error": "Product not found"})
        
        result = {
            "action": "add_to_cart",
            "product": {
                "id": p.id,
                "name": p.name,
                "price": p.price,
                "image_url": getattr(p, "image_url", "")
            },
            "quantity": quantity
        }
        return json.dumps(result)
    except Exception as e:
        print(f"[TOOL ERROR] {str(e)}")
        return json.dumps({"error": str(e)})
    finally:
        db.close()


class OrderStatusInput(BaseModel):
    order_id: Union[str, int] = Field(..., description="The exact order ID or tracking number provided by the user.")

@tool("check_order_status", args_schema=OrderStatusInput)
def check_order_status(order_id: Union[str, int]) -> str:
    """
    Looks up the real-time shipping status, total amount, and delivery details of a customer's order.
    Always use this when a user asks about their order status, tracks a package, or provides an order number.
    """
    print(f"\n[TOOL CALLED] check_order_status with: order_id={order_id}")
    
    db: Session = SessionLocal()
    try:
        clean_id = str(order_id)
        query_id = int(clean_id) if clean_id.isdigit() else clean_id
        order = db.query(Order).filter(Order.id == query_id).first()
        
        if not order:
            return json.dumps({"error": f"Order {order_id} could not be found in the system."})
        
        result = {
            "action": "order_status",
            "order": {
                "order_id": str(order.id),
                "status": getattr(order, "status", "PROCESSING"),
                "total": getattr(order, "total_amount", 0.0),
                "shipping_address": getattr(order, "shipping_address", "Address not provided"),
                "estimated_delivery": "Within 1-2 business days" if getattr(order, "fulfillment_type", "") == "IN_HOUSE" else "Within 7-10 business days"
            }
        }
        return json.dumps(result)
    except Exception as e:
        print(f"[TOOL ERROR] {str(e)}")
        return json.dumps({"error": str(e)})
    finally:
        db.close()


class KnowledgeBaseSearchInput(BaseModel):
    query: str = Field(..., description="The user's question regarding store policies, warranties, returns, payment methods, or fulfillment locations.")

@tool("search_knowledge_base", args_schema=KnowledgeBaseSearchInput)
def search_knowledge_base(query: str) -> str:
    """
    Searches the Penguin Store official knowledge base for policies, return guidelines, 
    warranty details, payment security, and fulfillment locations. 
    Always use this tool when a user asks about store rules, policies, or return windows.
    """
    print(f"\n[TOOL CALLED] search_knowledge_base with query: '{query}'")
    try:
        context = retrieve_store_knowledge(query)
        if not context:
            return "No specific policy found in the knowledge base."
        return context
    except Exception as e:
        print(f"[TOOL ERROR] {str(e)}")
        return "Error retrieving store policies."