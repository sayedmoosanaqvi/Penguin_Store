from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from typing import List, Dict, Any

from app.security import verify_agent
# Import your database dependency and Product model
from app.database import get_db 
from app.models import Product 

router = APIRouter(prefix="/api/agent", tags=["CTRL-X Agent Tools"])

# ---------------------------------------------------------
# TOOL 1: INVENTORY MONITORING
# The AI calls this to check what is in stock and what S3 images exist
# ---------------------------------------------------------
@router.get("/inventory")
async def get_real_inventory(
    api_key: str = Depends(verify_agent), 
    db: Session = Depends(get_db)
):
    # Fetch all products from your PostgreSQL database
    products = db.query(Product).all()
    
    agent_inventory = []
    for p in products:
        agent_inventory.append({
            "id": p.id,
            "name": p.name,
            "stock": p.stock_quantity,
            "price": float(p.price),
            "has_3d_model": bool(p.s3_model_url), # AI can check if a 3D asset exists!
            "status": "Low Stock" if p.stock_quantity < 5 else "In Stock"
        })
        
    return {"inventory": agent_inventory, "total_items": len(agent_inventory)}

# ---------------------------------------------------------
# TOOL 2: PRODUCT MANAGEMENT (SEO & Descriptions)
# The AI calls this to update a product with text it generated
# ---------------------------------------------------------
@router.put("/products/{product_id}/update-seo")
async def agent_update_product_seo(
    product_id: int, 
    payload: Dict[str, Any], 
    api_key: str = Depends(verify_agent),
    db: Session = Depends(get_db)
):
    # Find the specific product in Postgres
    product = db.query(Product).filter(Product.id == product_id).first()
    
    if not product:
        raise HTTPException(status_code=404, detail="Product not found in DB")
        
    # Apply the AI's generated content
    if "seo_description" in payload:
        product.description = payload["seo_description"]
    if "tags" in payload:
        product.tags = payload["tags"] # Assuming tags is a JSONB or String column
        
    # Save the AI's changes to the database
    db.commit()
    db.refresh(product)
    
    return {
        "message": "CTRL-X successfully updated the product.",
        "product_name": product.name,
        "new_description": product.description
    }