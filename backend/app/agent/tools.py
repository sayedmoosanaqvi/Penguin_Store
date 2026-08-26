from typing import Optional, List, Dict
from pydantic import BaseModel, Field
from langchain_core.tools import tool
from sqlalchemy.orm import Session
from app.database import SessionLocal
from app.models import Product

class ProductSearchInput(BaseModel):
    category: Optional[str] = Field(None, description="The category of the product (e.g., 'ELECTRONICS', 'SMARTPHONES', 'FRAGRANCES').")
    max_price: Optional[float] = Field(None, description="The absolute maximum price the user is willing to pay.")
    is_featured: Optional[bool] = Field(None, description="Set to True if the user specifically asks for featured or trending items.")

@tool("search_inventory", args_schema=ProductSearchInput)
def search_inventory(category: Optional[str] = None, max_price: Optional[float] = None, is_featured: Optional[bool] = None) -> List[Dict]:
    """
    Searches the live PostgreSQL database for products based on category, maximum price, and featured status.
    Always use this tool when a user asks for product recommendations, prices, or availability.
    """
    print(f"\n[TOOL CALLED] search_inventory with: category={category}, max_price={max_price}, is_featured={is_featured}")
    
    db: Session = SessionLocal()
    try:
        query = db.query(Product)
        
        if category:
            query = query.filter(Product.category.ilike(f"%{category}%"))
        if max_price is not None:
            query = query.filter(Product.price <= max_price)
        if is_featured is not None:
            query = query.filter(Product.is_featured == is_featured)
            
        products = query.all()
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
        return results
    except Exception as e:
        print(f"[TOOL ERROR] {str(e)}")
        return []
    finally:
        db.close()