"""Product catalog repository with column projection, hybrid search & active filtering."""

from __future__ import annotations

from typing import Any, Optional

from sqlalchemy import or_, text
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
    Product.stock,
)

_PG_HAS_IS_ACTIVE_COL: Optional[bool] = None


def apply_active_product_filter(query, *, deleted_ids: Optional[set[int]] = None):
    """Excludes soft-deleted, archived, and tombstoned products from SQLAlchemy queries."""
    global _PG_HAS_IS_ACTIVE_COL
    q = query.filter(
        ~Product.name.startswith("[Archived]"),
        or_(Product.stock.is_(None), Product.stock >= 0),
    )
    if deleted_ids:
        q = q.filter(~Product.id.in_(list(deleted_ids)))
    if _PG_HAS_IS_ACTIVE_COL is not False:
        q = q.filter(text("COALESCE(products.is_active, TRUE) = TRUE"))
    return q


def list_public_products(
    db: Session,
    *,
    limit: Optional[int] = None,
    offset: int = 0,
    category: Optional[str] = None,
    search: Optional[str] = None,
    min_price: Optional[float] = None,
    max_price: Optional[float] = None,
    only_3d: bool = False,
    sort: Optional[str] = None,
) -> list[Any]:
    global _PG_HAS_IS_ACTIVE_COL
    from sqlalchemy.exc import OperationalError, ProgrammingError
    from app.core.supabase_rest import (
        _DELETED_PRODUCT_IDS,
        fetch_products_https,
        is_pg_tcp_reachable,
        mark_pg_tcp_unreachable,
        search_products_hybrid_https,
    )

    # Whenever search, semantic fallback, 3D filter, or advanced sorting is requested,
    # or when raw TCP is unreachable, use the fast hybrid search & HTTPS engine.
    if (
        not is_pg_tcp_reachable()
        or (search and search.strip())
        or only_3d
        or (category and category.strip().lower() == "3d")
        or (sort and sort.strip().lower() not in ("", "id"))
    ):
        return search_products_hybrid_https(
            search=search,
            category=category,
            min_price=min_price,
            max_price=max_price,
            only_3d=only_3d,
            sort=sort,
            limit=limit,
            offset=offset,
        )

    try:
        q = apply_active_product_filter(
            db.query(Product).options(load_only(*PRODUCT_PUBLIC_COLUMNS)),
            deleted_ids=_DELETED_PRODUCT_IDS,
        )

        if category and category.strip().lower() not in ("all", ""):
            clean_cat = category.strip()
            q = q.filter(Product.category.ilike(f"%{clean_cat}%"))

        if min_price is not None:
            q = q.filter(Product.price >= float(min_price))
        if max_price is not None:
            q = q.filter(Product.price <= float(max_price))

        q = q.order_by(Product.id.asc())

        if offset > 0:
            q = q.offset(offset)
        if limit is not None and limit > 0:
            q = q.limit(limit)

        return q.all()
    except ProgrammingError:
        db.rollback()
        _PG_HAS_IS_ACTIVE_COL = False
        return fetch_products_https(
            limit=limit,
            offset=offset,
            category=category,
            search=search,
            min_price=min_price,
            max_price=max_price,
            only_3d=only_3d,
            sort=sort,
        )
    except OperationalError:
        db.rollback()
        mark_pg_tcp_unreachable()
        return fetch_products_https(
            limit=limit,
            offset=offset,
            category=category,
            search=search,
            min_price=min_price,
            max_price=max_price,
            only_3d=only_3d,
            sort=sort,
        )


def get_public_product_by_id(db: Session, product_id: int) -> Any | None:
    global _PG_HAS_IS_ACTIVE_COL
    from sqlalchemy.exc import OperationalError, ProgrammingError
    from app.core.supabase_rest import (
        _DELETED_PRODUCT_IDS,
        fetch_product_by_id_https,
        is_pg_tcp_reachable,
        mark_pg_tcp_unreachable,
    )

    if int(product_id) in _DELETED_PRODUCT_IDS:
        return None

    if not is_pg_tcp_reachable():
        return fetch_product_by_id_https(product_id)

    try:
        return (
            apply_active_product_filter(
                db.query(Product).options(load_only(*PRODUCT_PUBLIC_COLUMNS)),
                deleted_ids=_DELETED_PRODUCT_IDS,
            )
            .filter(Product.id == product_id)
            .first()
        )
    except ProgrammingError:
        db.rollback()
        _PG_HAS_IS_ACTIVE_COL = False
        return fetch_product_by_id_https(product_id)
    except OperationalError:
        db.rollback()
        mark_pg_tcp_unreachable()
        return fetch_product_by_id_https(product_id)
