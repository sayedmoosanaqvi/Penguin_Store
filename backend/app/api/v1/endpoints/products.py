"""Versioned Products endpoints (/api/v1/products) with hybrid search, instant delete & strict RBAC."""

from __future__ import annotations

import logging
from typing import Optional

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, status
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.security import require_role
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
    q: Optional[str] = Query(default=None, max_length=120),
    min_price: Optional[float] = Query(default=None, ge=0),
    max_price: Optional[float] = Query(default=None, ge=0),
    only_3d: bool = Query(default=False),
    sort: Optional[str] = Query(default=None, max_length=40),
    db: Session = Depends(get_db),
):
    effective_search = search if (search and search.strip()) else q
    return list_public_products(
        db,
        limit=limit,
        offset=offset,
        category=category,
        search=effective_search,
        min_price=min_price,
        max_price=max_price,
        only_3d=only_3d,
        sort=sort,
    )


@router.get("/search", response_model=list[Product])
def search_products_v1(
    q: Optional[str] = Query(default=None, max_length=150),
    search: Optional[str] = Query(default=None, max_length=150),
    category: Optional[str] = Query(default=None, max_length=100),
    min_price: Optional[float] = Query(default=None, ge=0),
    max_price: Optional[float] = Query(default=None, ge=0),
    only_3d: bool = Query(default=False),
    sort: Optional[str] = Query(default=None, max_length=40),
    limit: int = Query(default=60, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    db: Session = Depends(get_db),
):
    """Fast hybrid PostgreSQL + semantic/pgvector product search (excludes inactive/deleted items)."""
    from app.core.supabase_rest import search_products_hybrid_https

    effective_query = q if (q and q.strip()) else search
    return search_products_hybrid_https(
        search=effective_query,
        category=category,
        min_price=min_price,
        max_price=max_price,
        only_3d=only_3d,
        sort=sort,
        limit=limit,
        offset=offset,
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


def _cleanup_product_storage_files(
    product_id: int,
    image_url: Optional[str] = None,
    storage_paths_3d: Optional[list[tuple[str, str]]] = None,
):
    """Clean up Supabase Storage objects (.glb, posters, 2D images) in BackgroundTasks."""
    try:
        from app.core.supabase_rest import get_supabase_client

        client = get_supabase_client()

        # 1. Remove known 3D GLB paths recorded in product_3d_assets
        if storage_paths_3d:
            by_bucket: dict[str, list[str]] = {}
            for bucket, path in storage_paths_3d:
                if bucket and path:
                    by_bucket.setdefault(bucket, []).append(path)
            for bucket, paths in by_bucket.items():
                try:
                    client.storage.from_(bucket).remove(paths)
                except Exception as exc:
                    logger.debug("3D path cleanup notice (%s): %s", bucket, exc)

        # 2. Remove any remaining files under products/{product_id}/ in penguin-store-3d
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
            logger.debug("3D folder cleanup notice for product %s: %s", product_id, exc)

        # 3. Remove custom 2D image / poster stored in penguin-store-assets
        if image_url and "penguin-store-assets" in image_url:
            try:
                parts = image_url.split("penguin-store-assets/")
                if len(parts) > 1:
                    obj_path = parts[1].split("?")[0].lstrip("/")
                    if obj_path:
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


def execute_product_deletion(
    *,
    product_id: int,
    background_tasks: BackgroundTasks,
    db: Session,
) -> dict:
    """Shared bulletproof <300ms product deletion handler (Service Role + FK cascade + soft-delete fallback + verified DB commit)."""
    from app.core.supabase_rest import (
        get_supabase_client,
        invalidate_supabase_rest_cache,
        is_pg_tcp_reachable,
        is_product_active_row,
        mark_product_deleted,
    )
    from app.routers import premium_3d

    if product_id == 144:
        raise HTTPException(
            status_code=403,
            detail="Product #144 is protected as the reference 3D catalog showcase item.",
        )

    client = get_supabase_client()

    # 1. Live lookup against Supabase (bypassing in-memory cache so we never misread stale rows)
    live_row: Optional[dict] = None
    try:
        lookup = (
            client.table("products")
            .select("id,name,image_url,stock")
            .eq("id", product_id)
            .limit(1)
            .execute()
        )
        if lookup.data:
            live_row = lookup.data[0]
    except Exception as exc:
        logger.warning("Direct Supabase lookup error on delete #%s: %s", product_id, exc)

    if live_row is None:
        # Ensure any stale caches are purged even if row was already deleted earlier
        mark_product_deleted(product_id)
        visual_search.invalidate_visual_cache()
        premium_3d.clear_signed_url_cache()
        raise HTTPException(
            status_code=404,
            detail=f"Product #{product_id} was not found (already deleted).",
        )

    raw_name = str(live_row.get("name") or f"Product #{product_id}")
    product_name = raw_name.replace("[Archived] ", "").strip() or f"Product #{product_id}"
    image_url = live_row.get("image_url")

    # Capture any 3D storage paths before deleting asset rows
    storage_paths_3d: list[tuple[str, str]] = []
    try:
        assets_res = (
            client.table("product_3d_assets")
            .select("id,storage_bucket,storage_path")
            .eq("product_id", product_id)
            .execute()
        )
        for a in assets_res.data or []:
            if isinstance(a, dict) and a.get("storage_path"):
                storage_paths_3d.append(
                    (
                        str(a.get("storage_bucket") or "penguin-store-3d"),
                        str(a["storage_path"]),
                    )
                )
    except Exception:
        pass

    try:
        # 2. Delete ephemeral dependent rows across ALL actual schema tables
        for tbl in (
            "product_3d_assets",
            "cart_items",
            "favorites",
            "wishlists",
            "reviews",
            "product_review_insights",
            "rfq_requests",
            "recently_viewed",
        ):
            try:
                client.table(tbl).delete().eq("product_id", product_id).execute()
            except Exception as tbl_err:
                logger.debug("Cascade cleanup on %s for product %s: %s", tbl, product_id, tbl_err)

        # 3. Check if referenced in historical order_items
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

        def _perform_soft_delete() -> bool:
            # Try setting is_active=False first; gracefully fall back to tombstone markers if column not migrated yet
            try:
                upd = (
                    client.table("products")
                    .update(
                        {
                            "is_active": False,
                            "stock": -1,
                            "is_featured": False,
                        }
                    )
                    .eq("id", product_id)
                    .execute()
                )
                if upd.data:
                    return True
            except Exception as soft_exc:
                logger.debug("is_active soft-delete fallback for #%s: %s", product_id, soft_exc)

            upd_fallback = (
                client.table("products")
                .update(
                    {
                        "stock": -1,
                        "is_featured": False,
                        "name": f"[Archived] {product_name}"[:150],
                    }
                )
                .eq("id", product_id)
                .execute()
            )
            return bool(upd_fallback.data)

        delete_mode = "hard"
        verified_gone = False

        if is_in_order:
            delete_mode = "soft"
            verified_gone = _perform_soft_delete()
        else:
            # Attempt hard delete via Supabase Service Role client
            client.table("products").delete().eq("id", product_id).execute()

            # Verify row was actually deleted (catches silent RLS 0-row responses or hidden FKs)
            check_res = (
                client.table("products")
                .select("id,name,stock")
                .eq("id", product_id)
                .limit(1)
                .execute()
            )
            if not check_res.data:
                verified_gone = True
            else:
                # Fallback 1: Direct SQLAlchemy delete if raw PostgreSQL TCP is reachable
                if is_pg_tcp_reachable():
                    try:
                        db.execute(
                            text("DELETE FROM products WHERE id = :pid"),
                            {"pid": product_id},
                        )
                        db.commit()
                        verified_gone = True
                    except Exception:
                        db.rollback()

                # Fallback 2: Soft-delete so product immediately disappears from storefront
                if not verified_gone:
                    delete_mode = "soft"
                    verified_gone = _perform_soft_delete()

        if not verified_gone:
            # Final verification check
            final_check = (
                client.table("products")
                .select("*")
                .eq("id", product_id)
                .limit(1)
                .execute()
            )
            if final_check.data and is_product_active_row(final_check.data[0]):
                raise HTTPException(
                    status_code=500,
                    detail=(
                        f"Database rejected deletion of '{product_name}'. "
                        "Verify SUPABASE_SERVICE_KEY has service_role privileges or run supabase_migrations.sql."
                    ),
                )

        # 4. Immediately purge ALL backend caches (< 2ms)
        mark_product_deleted(product_id)
        invalidate_supabase_rest_cache()
        visual_search.invalidate_visual_cache()
        premium_3d.clear_signed_url_cache()

        # 5. Offload storage cleanup to BackgroundTasks so HTTP response returns in < 300ms (only on hard delete or 3D cleanup)
        if delete_mode == "hard":
            background_tasks.add_task(
                _cleanup_product_storage_files,
                product_id,
                image_url,
                storage_paths_3d,
            )
        elif storage_paths_3d:
            background_tasks.add_task(
                _cleanup_product_storage_files,
                product_id,
                None,
                storage_paths_3d,
            )

        msg = (
            f"Deleted '{product_name}' permanently."
            if delete_mode == "hard"
            else f"Deleted '{product_name}' from store catalog (archived for historical order receipts)."
        )

        return {
            "status": "deleted",
            "mode": delete_mode,
            "product_id": product_id,
            "product_name": product_name,
            "message": msg,
        }
    except HTTPException:
        raise
    except Exception as exc:
        logger.exception("Product deletion error for #%s: %s", product_id, exc)
        raise HTTPException(
            status_code=500,
            detail=f"Delete failed for '{product_name}': {str(exc)}",
        )


@router.delete("/{product_id}", status_code=status.HTTP_200_OK)
def delete_product_v1(
    product_id: int,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    admin_user: User = Depends(require_role(["admin"])),
):
    return execute_product_deletion(
        product_id=product_id,
        background_tasks=background_tasks,
        db=db,
    )
