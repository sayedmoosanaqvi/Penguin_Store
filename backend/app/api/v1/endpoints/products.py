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


def _cleanup_product_storage_files(product_id: int, image_url: Optional[str] = None):
    """Clean up Supabase storage files in background so DELETE returns in < 300ms."""
    try:
        from app.core.supabase_rest import get_supabase_client
        client = get_supabase_client()

        # 1. Clean up 3D files under products/{product_id}/ in penguin-store-3d
        try:
            files_res = client.storage.from_("penguin-store-3d").list(f"products/{product_id}")
            if files_res:
                paths_to_delete = [
                    f"products/{product_id}/{f['name']}"
                    for f in files_res
                    if isinstance(f, dict) and "name" in f
                ]
                if paths_to_delete:
                    client.storage.from_("penguin-store-3d").remove(paths_to_delete)
        except Exception as exc:
            logger.debug("3D storage cleanup notice for product %s: %s", product_id, exc)

        # 2. Clean up custom image if stored in penguin-store-assets
        if image_url and "penguin-store-assets" in image_url:
            try:
                parts = image_url.split("penguin-store-assets/")
                if len(parts) > 1:
                    obj_path = parts[1].split("?")[0]
                    client.storage.from_("penguin-store-assets").remove([obj_path])
            except Exception as exc:
                logger.debug("Image storage cleanup notice for product %s: %s", product_id, exc)
    except Exception as exc:
        logger.warning("Background storage cleanup error for product %s: %s", product_id, exc)


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
        background_tasks.add_task(visual_search.invalidate_visual_cache)
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
        background_tasks.add_task(visual_search.invalidate_visual_cache)
        if rows:
            return _normalize_product_dict(rows[0])
        return fetch_product_by_id_https(product_id) or existing
    except Exception:
        raise HTTPException(status_code=409, detail="Product update conflict.")


@router.delete("/{product_id}", status_code=status.HTTP_200_OK)
def delete_product_v1(
    product_id: int,
    background_tasks: BackgroundTasks,
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

    client = get_supabase_client()
    product_name = str(existing.get("name") or f"Product #{product_id}")

    try:
        # 1. Clean up ephemeral dependent rows that would trigger FK constraints
        for tbl in [
            "product_3d_assets",
            "cart_items",
            "wishlist_items",
            "reviews",
            "product_review_insights",
            "rfq_requests",
            "recently_viewed_items",
        ]:
            try:
                client.table(tbl).delete().eq("product_id", product_id).execute()
            except Exception as tbl_err:
                logger.debug("Cascade cleanup on %s for product %s: %s", tbl, product_id, tbl_err)

        # 2. Check if product is referenced in order_items (historical customer invoices)
        is_in_order = False
        try:
            ord_res = (
                client.table("order_items")
                .select("id")
                .eq("product_id", product_id)
                .limit(1)
                .execute()
            )
            if ord_res.data:
                is_in_order = True
        except Exception:
            pass

        if is_in_order:
            # Soft-delete / archive to maintain accounting integrity of past orders
            client.table("products").update({
                "stock": 0,
                "is_featured": False,
                "name": f"[Archived] {product_name}",
            }).eq("id", product_id).execute()
            logger.info("Product #%s referenced in orders: archived cleanly.", product_id)
        else:
            client.table("products").delete().eq("id", product_id).execute()
            logger.info("Product #%s hard-deleted cleanly from database.", product_id)

        # 3. Immediately invalidate memory catalog cache
        invalidate_supabase_rest_cache()
        background_tasks.add_task(visual_search.invalidate_visual_cache)

        # 4. Offload Supabase Storage file cleanup to BackgroundTasks (< 300ms response)
        background_tasks.add_task(
            _cleanup_product_storage_files,
            product_id,
            existing.get("image_url"),
        )

        return {
            "status": "deleted",
            "product_id": product_id,
            "product_name": product_name,
            "message": f"Product '{product_name}' deleted successfully",
        }
    except Exception as exc:
        logger.exception("Product deletion error: %s", exc)
        raise HTTPException(
            status_code=500,
            detail=f"Could not delete product: {str(exc)}",
        )
