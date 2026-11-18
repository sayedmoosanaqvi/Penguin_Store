"""Pydantic schema package (re-exports legacy names cleanly)."""

from app.schemas.auth import (
    DeleteAccountRequest,
    UserCreate,
    UserProfileResponse,
    UserRoleUpdate,
)
from app.schemas.commerce import (
    AddressCreate,
    CartBulkSyncRequest,
    CartSyncItem,
    OrderStatusUpdateRequest,
    ReviewCreate,
    WishlistToggleRequest,
)
from app.schemas.product import (
    Product,
    ProductBase,
    ProductCreate,
    ProductUpdate,
)

__all__ = [
    "AddressCreate",
    "CartBulkSyncRequest",
    "CartSyncItem",
    "DeleteAccountRequest",
    "OrderStatusUpdateRequest",
    "Product",
    "ProductBase",
    "ProductCreate",
    "ProductUpdate",
    "ReviewCreate",
    "UserCreate",
    "UserProfileResponse",
    "UserRoleUpdate",
    "WishlistToggleRequest",
]
