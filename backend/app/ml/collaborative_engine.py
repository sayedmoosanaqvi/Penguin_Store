from typing import Any, Dict, List

from sqlalchemy.orm import Session, load_only

from app.core.supabase_rest import _DELETED_PRODUCT_IDS, fetch_trending_products_https
from app.models import Order, OrderItem, Product
from app.repositories.product_repo import apply_active_product_filter

_RECO_PRODUCT_COLUMNS = (
    Product.id,
    Product.name,
    Product.price,
    Product.image_url,
    Product.category,
    Product.rating,
    Product.stock,
)


def _fallback_top_products(db: Session, limit: int) -> List[Dict[str, Any]]:
    try:
        fallback = (
            apply_active_product_filter(
                db.query(Product).options(load_only(*_RECO_PRODUCT_COLUMNS)),
                deleted_ids=_DELETED_PRODUCT_IDS,
            )
            .order_by(Product.rating.desc())
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
            }
            for p in fallback
        ]
    except Exception:
        db.rollback()
        return fetch_trending_products_https(limit=limit)


def compute_collaborative_recommendations(
    db: Session,
    user_email: str,
    limit: int = 5,
) -> List[Dict[str, Any]]:
    """
    Computes personalized active product recommendations using user-based collaborative filtering.
    """
    try:
        user_orders = db.query(Order).filter(Order.customer_email == user_email).all()
        user_order_ids = [order.id for order in user_orders]

        user_product_ids = set()
        if user_order_ids:
            user_items = db.query(OrderItem).filter(OrderItem.order_id.in_(user_order_ids)).all()
            for item in user_items:
                user_product_ids.add(item.product_id)

        if not user_product_ids:
            return _fallback_top_products(db, limit)

        other_orders = db.query(Order).filter(Order.customer_email != user_email).all()
        other_order_ids = [order.id for order in other_orders]

        product_frequency: Dict[int, int] = {}

        if other_order_ids:
            other_items = db.query(OrderItem).filter(OrderItem.order_id.in_(other_order_ids)).all()

            order_to_products: Dict[int, set] = {}
            order_to_items: Dict[int, list] = {}
            for item in other_items:
                order_to_products.setdefault(item.order_id, set()).add(item.product_id)
                order_to_items.setdefault(item.order_id, []).append(item)

            for oid, order_pids in order_to_products.items():
                shared_items = user_product_ids.intersection(order_pids)
                if shared_items:
                    for item in order_to_items[oid]:
                        if item.product_id not in user_product_ids and item.product_id not in _DELETED_PRODUCT_IDS:
                            product_frequency[item.product_id] = (
                                product_frequency.get(item.product_id, 0) + item.quantity
                            )

        sorted_product_ids = sorted(
            product_frequency.keys(),
            key=lambda k: product_frequency[k],
            reverse=True,
        )

        recommended_products = []
        for pid in sorted_product_ids:
            if len(recommended_products) >= limit:
                break
            product = (
                apply_active_product_filter(
                    db.query(Product).options(load_only(*_RECO_PRODUCT_COLUMNS)),
                    deleted_ids=_DELETED_PRODUCT_IDS,
                )
                .filter(Product.id == pid)
                .first()
            )
            if product:
                recommended_products.append(
                    {
                        "id": product.id,
                        "name": product.name,
                        "price": product.price,
                        "image_url": product.image_url,
                        "category": product.category,
                        "rating": product.rating,
                    }
                )

        if not recommended_products:
            return _fallback_top_products(db, limit)

        return recommended_products
    except Exception:
        db.rollback()
        return _fallback_top_products(db, limit)
