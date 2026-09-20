from typing import Dict, Any
from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.database import get_db
from app.ml.trending_engine import compute_regional_top_products

router = APIRouter(prefix="/api/trending", tags=["Trending / ML"])

@router.get("/top-10")
def get_top_10_by_region(
    country: str = Query(default="Pakistan", description="Country name for localized trends"),
    limit: int = Query(default=10, ge=1, le=20, description="Number of items to return"),
    db: Session = Depends(get_db)
) -> Dict[str, Any]:
    """
    Retrieves the top trending products for a specific region
    ranked using exponential time-decay scoring.
    """
    products = compute_regional_top_products(db=db, country=country, limit=limit)
    
    return {
        "status": "success",
        "country": country,
        "count": len(products),
        "products": products
    }