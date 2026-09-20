import math
from datetime import datetime
from typing import List, Dict, Any
from sqlalchemy.orm import Session
from sqlalchemy import func
from app.models import Order, OrderItem, Product

# Half-life parameter (in days): sales 7 days ago carry 50% weight
HALF_LIFE_DAYS = 7.0
LAMBDA_DECAY = math.log(2) / HALF_LIFE_DAYS

def compute_regional_top_products(
    db: Session,
    country: str = "Pakistan",
    limit: int = 10
) -> List[Dict[str, Any]]:
    """
    Computes top trending products for a given country using an
    exponential time-decay machine learning scoring model.
    """
    now = datetime.utcnow()

    # Query all order items matching the target country
    records = (
        db.query(
            OrderItem.product_id,
            OrderItem.quantity,
            Order.created_at,
            Product.name,
            Product.price,
            Product.image_url,
            Product.category,
            Product.rating
        )
        .join(Order, OrderItem.order_id == Order.id)
        .join(Product, OrderItem.product_id == Product.id)
        .filter(func.lower(Order.country) == country.strip().lower())
        .all()
    )

    # Compute decayed momentum scores per product
    product_scores: Dict[int, Dict[str, Any]] = {}

    for row in records:
        pid = row.product_id
        qty = row.quantity or 1
        created_at = row.created_at or now

        # Calculate time delta in days
        delta_days = max(0.0, (now - created_at).total_seconds() / 86400.0)

        # Exponential decay calculation: q * e^(-lambda * delta_t)
        weight = math.exp(-LAMBDA_DECAY * delta_days)
        decayed_score = qty * weight

        if pid not in product_scores:
            product_scores[pid] = {
                "id": pid,
                "name": row.name,
                "price": row.price,
                "image_url": row.image_url,
                "category": row.category,
                "rating": row.rating,
                "trending_score": 0.0,
                "total_units_sold": 0
            }

        product_scores[pid]["trending_score"] += decayed_score
        product_scores[pid]["total_units_sold"] += qty

    # Sort descending by calculated trending score
    ranked_products = sorted(
        product_scores.values(),
        key=lambda item: item["trending_score"],
        reverse=True
    )

    # Cold-Start Fallback: If no regional sales exist yet, return featured products
    if not ranked_products:
        fallback_products = (
            db.query(Product)
            .order_by(Product.is_featured.desc(), Product.rating.desc())
            .limit(limit)
            .all()
        )
        return [
            {
                "id": p.id,
                "name": p.name,
                "price": p.price,
                "image_url": p.image_url,
                "category": p.category,
                "rating": p.rating,
                "trending_score": 0.0,
                "total_units_sold": 0
            }
            for p in fallback_products
        ]

    return ranked_products[:limit]