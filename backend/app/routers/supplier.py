import logging

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.adapters.supplier_adapter import DummyJSONAdapter
from app.database import SessionLocal
from app.models import Product
from app.routers.visual_search import invalidate_visual_cache
from app.security import verify_admin_or_agent

logger = logging.getLogger(__name__)

router = APIRouter(tags=["Supplier Integration"])


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


@router.post("/api/supplier/sync-products")
async def sync_supplier_products(
    db: Session = Depends(get_db),
    caller: str = Depends(verify_admin_or_agent),
):
    """
    Syncs inventory using the Adapter pattern.
    Protected by Admin JWT or CTRL-X Agent Key.
    """
    adapter = DummyJSONAdapter()

    try:
        from starlette.concurrency import run_in_threadpool

        products_data = await adapter.fetch_products()

        def _persist_synced(items_list: list[dict]) -> int:
            added = 0
            for item in items_list:
                existing_product = (
                    db.query(Product.id)
                    .filter(Product.name == item["name"])
                    .first()
                )
                if not existing_product:
                    db.add(Product(**item))
                    added += 1
            db.commit()
            return added

        added_count = await run_in_threadpool(_persist_synced, products_data)
        if added_count > 0:
            invalidate_visual_cache()

        return {
            "status": "success",
            "message": f"Successfully synced {added_count} new products via {adapter.supplier_id}.",
        }

    except Exception:
        db.rollback()
        logger.exception("Failed to sync with supplier")
        raise HTTPException(
            status_code=500,
            detail="Failed to sync with supplier.",
        )
