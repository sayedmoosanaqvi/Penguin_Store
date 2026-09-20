from typing import List, Dict, Any
from sqlalchemy.orm import Session
from app.models import Order, OrderItem, Product

def compute_collaborative_recommendations(
    db: Session,
    user_email: str,
    limit: int = 5
) -> List[Dict[str, Any]]:
    """
    Computes personalized product recommendations using user-based collaborative filtering with safe fallback.
    """
    try:
        # 1. Get all orders placed by the target user
        user_orders = db.query(Order).filter(Order.customer_email == user_email).all()
        user_order_ids = [order.id for order in user_orders]
        
        user_product_ids = set()
        if user_order_ids:
            user_items = db.query(OrderItem).filter(OrderItem.order_id.in_(user_order_ids)).all()
            for item in user_items:
                user_product_ids.add(item.product_id)

        if not user_product_ids:
            fallback = db.query(Product).order_by(Product.rating.desc()).limit(limit).all()
            return [
                {
                    "id": p.id,
                    "name": p.name,
                    "price": p.price,
                    "image_url": p.image_url,
                    "category": p.category,
                    "rating": p.rating
                } for p in fallback
            ]

        # 2. Find other orders by different users
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
                        if item.product_id not in user_product_ids:
                            product_frequency[item.product_id] = product_frequency.get(item.product_id, 0) + item.quantity

        sorted_product_ids = sorted(product_frequency.keys(), key=lambda k: product_frequency[k], reverse=True)
        
        recommended_products = []
        for pid in sorted_product_ids[:limit]:
            product = db.query(Product.id, Product.name, Product.price, Product.image_url, Product.category, Product.rating).filter(Product.id == pid).first()
            if product:
                recommended_products.append({
                    "id": product.id,
                    "name": product.name,
                    "price": product.price,
                    "image_url": product.image_url,
                    "category": product.category,
                    "rating": product.rating
                })

        if not recommended_products:
            fallback = db.query(Product).order_by(Product.rating.desc()).limit(limit).all()
            return [
                {
                    "id": p.id,
                    "name": p.name,
                    "price": p.price,
                    "image_url": p.image_url,
                    "category": p.category,
                    "rating": p.rating
                } for p in fallback
            ]

        return recommended_products

    except Exception as e:
        print(f"🔥 COLLABORATIVE ENGINE ERROR: {e}")
        # Graceful fallback so API never throws 500
        fallback = db.query(Product).order_by(Product.rating.desc()).limit(limit).all()
        return [
            {
                "id": p.id,
                "name": p.name,
                "price": p.price,
                "image_url": p.image_url,
                "category": p.category,
                "rating": p.rating
            } for p in fallback
        ]