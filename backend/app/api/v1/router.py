"""Version 1 API router registry."""

from fastapi import APIRouter

from app.api.v1.endpoints import admin, auth, commerce, products, rfq

api_v1_router = APIRouter(prefix="/api/v1")
api_v1_router.include_router(auth.router)
api_v1_router.include_router(products.router)
api_v1_router.include_router(admin.router)
api_v1_router.include_router(commerce.router)
api_v1_router.include_router(rfq.router)
