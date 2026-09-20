from typing import Dict, Any
from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.database import get_db
from app.ml.collaborative_engine import compute_collaborative_recommendations

router = APIRouter(prefix="/api/recommendations", tags=["Collaborative ML"])

@router.get("/for-user")
def get_user_recommendations(
    email: str = Query(..., description="Customer email for personalized filtering"),
    limit: int = Query(default=5, ge=1, le=10, description="Number of items to return"),
    db: Session = Depends(get_db)
) -> Dict[str, Any]:
    """
    Retrieves personalized collaborative recommendations for a user based on purchase similarity.
    """
    products = compute_collaborative_recommendations(db=db, user_email=email, limit=limit)
    
    return {
        "status": "success",
        "user_email": email,
        "count": len(products),
        "products": products
    }