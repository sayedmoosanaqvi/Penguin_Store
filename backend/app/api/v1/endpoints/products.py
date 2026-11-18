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
    db_product = ProductModel(**payload.model_dump())
    try:
        db.add(db_product)
        db.commit()
        db.refresh(db_product)
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="Product could not be created.")

    background_tasks.add_task(
        visual_search.index_single_product_by_id,
        db_product.id,
    )
    return db_product


@router.put("/{product_id}", response_model=Product)
def update_product_v1(
    product_id: int,
    payload: ProductUpdate,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    admin_user: User = Depends(require_role(["admin"])),
):
    product = get_public_product_by_id(db, product_id)
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found.")

    updates = payload.model_dump(exclude_unset=True)
    image_changed = "image_url" in updates and updates["image_url"] != product.image_url

    for key, val in updates.items():
        setattr(product, key, val)

    try:
        db.commit()
        db.refresh(product)
        visual_search.invalidate_visual_cache()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="Product update conflict.")

    if image_changed:
        background_tasks.add_task(visual_search.index_single_product_by_id, product.id)

    return product


@router.delete("/{product_id}", status_code=status.HTTP_200_OK)
def delete_product_v1(
    product_id: int,
    db: Session = Depends(get_db),
    admin_user: User = Depends(require_role(["admin"])),
):
    if product_id == 144:
        raise HTTPException(
            status_code=403,
            detail="Product #144 is protected as the reference 3D catalog showcase item.",
        )

    product = db.query(ProductModel).filter(ProductModel.id == product_id).first()
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found.")

    try:
        db.delete(product)
        db.commit()
        visual_search.invalidate_visual_cache()
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=409,
            detail="This product is referenced by existing records and cannot be deleted.",
        )

    return {"message": "Product deleted successfully"}
