from typing import Any, Dict

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.security import get_optional_current_user, resolve_user_role
from app.ml.collaborative_engine import compute_collaborative_recommendations
from app.models import User

router = APIRouter(prefix="/api/recommendations", tags=["Collaborative ML"])


@router.get("/for-user")
def get_user_recommendations(
    email: str = Query(..., min_length=3, max_length=254, description="Customer email"),
    limit: int = Query(default=5, ge=1, le=10, description="Number of items to return"),
    db: Session = Depends(get_db),
    current_user: User | None = Depends(get_optional_current_user),
) -> Dict[str, Any]:
    """
    Retrieves personalized collaborative recommendations.
    If authenticated, enforces that non-admin callers query only their own email.
    """
    clean_email = email.strip().lower()
    if (
        current_user is not None
        and resolve_user_role(current_user) != "admin"
        and current_user.email.strip().lower() != clean_email
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only request personalized recommendations for your own account.",
        )

    from app.core.supabase_rest import (
        fetch_trending_products_https,
        is_pg_tcp_reachable,
        mark_pg_tcp_unreachable,
    )

    if not is_pg_tcp_reachable():
        products = fetch_trending_products_https(limit=limit)
    else:
        try:
            products = compute_collaborative_recommendations(
                db=db,
                user_email=clean_email,
                limit=limit,
            )
        except Exception:
            mark_pg_tcp_unreachable()
            products = fetch_trending_products_https(limit=limit)

    return {
        "status": "success",
        "user_email": clean_email,
        "count": len(products),
        "products": products,
    }
