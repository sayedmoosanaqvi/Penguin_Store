import math
from datetime import datetime
from typing import Any, Dict, List

from sqlalchemy import func
from sqlalchemy.orm import Session, load_only

from app.core.supabase_rest import _DELETED_PRODUCT_IDS, fetch_trending_products_https
from app.models import Order, OrderItem, Product
from app.repositories.product_repo import apply_active_product_filter

# Half-life parameter (in days): sales 7 days ago carry 50% weight
HALF_LIFE_DAYS = 7.0
LAMBDA_DECAY = math.log(2) / HALF_LIFE_DAYS


def compute_regional_top_products(
    db: Session,
    country: str = "Pakistan",
    limit: int = 10,
) -> List[Dict[str, Any]]:
    """
    Computes top trending active products for a given country using an
    exponential time-decay machine learning scoring model.
    """
    try:
        now = datetime.utcnow()

        records = (
            apply_active_product_filter(
                db.query(
                    OrderItem.product_id,
                    OrderItem.quantity,
                    Order.created_at,
                    Product.name,
                    Product.price,
                    Product.image_url,
                    Product.category,
                    Product.rating,
                )
                .join(Order, OrderItem.order_id == Order.id)
                .join(Product, OrderItem.product_id == Product.id),
                deleted_ids=_DELETED_PRODUCT_IDS,
            )
            .filter(func.lower(Order.country) == country.strip().lower())
            .all()
        )

        product_scores: Dict[int, Dict[str, Any]] = {}
        for row in records:
            pid = row.product_id
            if pid in _DELETED_PRODUCT_IDS:
                continue
            qty = row.quantity or 1
            created_at = row.created_at or now
            delta_days = max(0.0, (now - created_at).total_seconds() / 86400.0)
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
                    "total_units_sold": 0,
                }

            product_scores[pid]["trending_score"] += decayed_score
            product_scores[pid]["total_units_sold"] += qty

        ranked_products = sorted(
            product_scores.values(),
            key=lambda item: item["trending_score"],
            reverse=True,
        )

        if not ranked_products:
            fallback_products = (
                apply_active_product_filter(
                    db.query(Product).options(
                        load_only(
                            Product.id,
                            Product.name,
                            Product.price,
                            Product.image_url,
                            Product.category,
                            Product.rating,
                            Product.is_featured,
                            Product.stock,
                        )
                    ),
                    deleted_ids=_DELETED_PRODUCT_IDS,
                )
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
                    "total_units_sold": 0,
                }
                for p in fallback_products
            ]

        return ranked_products[:limit]
    except Exception:
        db.rollback()
        return fetch_trending_products_https(limit=limit)
