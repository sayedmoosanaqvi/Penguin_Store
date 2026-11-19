"""Versioned Products endpoints (/api/v1/products) with pagination & strict RBAC."""

from __future__ import annotations

import logging
from typing import Optional

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, status
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.security import require_role
from app.models import Product as ProductModel
from app.models import User
from app.repositories.product_repo import (
    get_public_product_by_id,
    list_public_products,
)
from app.routers import visual_search
from app.schemas.product import Product, ProductCreate, ProductUpdate

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/products", tags=["Products v1"])


@router.get("/", response_model=list[Product])
def list_products_v1(
    limit: Optional[int] = Query(default=None, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    category: Optional[str] = Query(default=None, max_length=100),
    search: Optional[str] = Query(default=None, max_length=120),
    db: Session = Depends(get_db),
):
    return list_public_products(
        db,
        limit=limit,
        offset=offset,
        category=category,
        search=search,
    )


@router.get("/{product_id}", response_model=Product)
def get_product_v1(
    product_id: int,
    db: Session = Depends(get_db),
):
    product = get_public_product_by_id(db, product_id)
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found.")
    return product


@router.post("/", response_model=Product, status_code=status.HTTP_201_CREATED)
def create_product_v1(
    payload: ProductCreate,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    admin_user: User = Depends(require_role(["admin"])),
):
    from app.core.supabase_rest import (
        _normalize_product_dict,
        get_supabase_client,
        invalidate_supabase_rest_cache,
    )

    try:
        client = get_supabase_client()
        res = client.table("products").insert(payload.model_dump()).execute()
        rows = res.data or []
        if not rows:
            raise HTTPException(status_code=409, detail="Product could not be created.")
        invalidate_supabase_rest_cache()
        return _normalize_product_dict(rows[0])
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=409, detail="Product could not be created.")


@router.put("/{product_id}", response_model=Product)
def update_product_v1(
    product_id: int,
    payload: ProductUpdate,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    admin_user: User = Depends(require_role(["admin"])),
):
    from app.core.supabase_rest import (
        _normalize_product_dict,
        fetch_product_by_id_https,
        get_supabase_client,
        invalidate_supabase_rest_cache,
    )

    existing = fetch_product_by_id_https(product_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Product not found.")

    updates = payload.model_dump(exclude_unset=True)
    if not updates:
        return existing

    try:
        client = get_supabase_client()
        res = client.table("products").update(updates).eq("id", product_id).execute()
        rows = res.data or []
        invalidate_supabase_rest_cache()
        visual_search.invalidate_visual_cache()
        if rows:
            return _normalize_product_dict(rows[0])
        return fetch_product_by_id_https(product_id) or existing
    except Exception:
        raise HTTPException(status_code=409, detail="Product update conflict.")


@router.delete("/{product_id}", status_code=status.HTTP_200_OK)
def delete_product_v1(
    product_id: int,
    db: Session = Depends(get_db),
    admin_user: User = Depends(require_role(["admin"])),
):
    from app.core.supabase_rest import (
        fetch_product_by_id_https,
        get_supabase_client,
        invalidate_supabase_rest_cache,
    )

    if product_id == 144:
        raise HTTPException(
            status_code=403,
            detail="Product #144 is protected as the reference 3D catalog showcase item.",
        )

    existing = fetch_product_by_id_https(product_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Product not found.")

    try:
        client = get_supabase_client()
        client.table("product_3d_assets").delete().eq("product_id", product_id).execute()
        client.table("products").delete().eq("id", product_id).execute()
        invalidate_supabase_rest_cache()
        visual_search.invalidate_visual_cache()
    except Exception:
        raise HTTPException(
            status_code=409,
            detail="This product is referenced by existing records and cannot be deleted.",
        )

    return {"message": "Product deleted successfully"}
