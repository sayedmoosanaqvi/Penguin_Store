"""Product catalog repository with column projection (excludes heavy 2048-D vectors)."""

from __future__ import annotations

from typing import Optional

from sqlalchemy import or_
from sqlalchemy.orm import Session, load_only

from app.models import Product

PRODUCT_PUBLIC_COLUMNS = (
    Product.id,
    Product.name,
    Product.description,
    Product.price,
    Product.original_price,
    Product.image_url,
    Product.category,
    Product.rating,
    Product.reviews,
    Product.discount_percent,
    Product.is_featured,
)


def list_public_products(
    db: Session,
    *,
    limit: Optional[int] = None,
    offset: int = 0,
    category: Optional[str] = None,
    search: Optional[str] = None,
) -> list[Product]:
    from sqlalchemy.exc import OperationalError
    from app.core.supabase_rest import (
        fetch_products_https,
        is_pg_tcp_reachable,
        mark_pg_tcp_unreachable,
    )

    if not is_pg_tcp_reachable():
        return fetch_products_https(
            limit=limit,
            offset=offset,
            category=category,
            search=search,
        )

    try:
        q = db.query(Product).options(load_only(*PRODUCT_PUBLIC_COLUMNS))

        if category and category.strip().lower() not in ("all", ""):
            clean_cat = category.strip()
            q = q.filter(Product.category.ilike(f"%{clean_cat}%"))

        if search and search.strip():
            clean_term = search.strip()
            q = q.filter(
                or_(
                    Product.name.ilike(f"%{clean_term}%"),
                    Product.category.ilike(f"%{clean_term}%"),
                    Product.description.ilike(f"%{clean_term}%"),
                )
            )

        q = q.order_by(Product.id.asc())

        if offset > 0:
            q = q.offset(offset)
        if limit is not None and limit > 0:
            q = q.limit(limit)

        return q.all()
    except OperationalError:
        db.rollback()
        mark_pg_tcp_unreachable()
        return fetch_products_https(
            limit=limit,
            offset=offset,
            category=category,
            search=search,
        )


def get_public_product_by_id(db: Session, product_id: int) -> Product | None:
    from sqlalchemy.exc import OperationalError
    from app.core.supabase_rest import (
        fetch_product_by_id_https,
        is_pg_tcp_reachable,
        mark_pg_tcp_unreachable,
    )

    if not is_pg_tcp_reachable():
        return fetch_product_by_id_https(product_id)

    try:
        return (
            db.query(Product)
            .options(load_only(*PRODUCT_PUBLIC_COLUMNS))
            .filter(Product.id == product_id)
            .first()
        )
    except OperationalError:
        db.rollback()
        mark_pg_tcp_unreachable()
        return fetch_product_by_id_https(product_id)
