"""Strict Pydantic schemas for reviews, wishlists, addresses, cart sync, and order administration."""

from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field


class ReviewCreate(BaseModel):
    rating: int = Field(..., ge=1, le=5)
    title: Optional[str] = Field(default=None, max_length=150)
    comment: str = Field(..., min_length=3, max_length=2000)
    tags: list[str] = Field(default_factory=list, max_length=8)


class ReviewUpdate(BaseModel):
    rating: int = Field(..., ge=1, le=5)
    title: Optional[str] = Field(default=None, max_length=150)
    comment: str = Field(..., min_length=3, max_length=2000)
    tags: list[str] = Field(default_factory=list, max_length=8)


class WishlistToggleRequest(BaseModel):
    product_id: int = Field(..., gt=0)


class AddressCreate(BaseModel):
    label: str = Field(default="Home", min_length=1, max_length=50)
    recipient_name: str = Field(..., min_length=1, max_length=150)
    phone: Optional[str] = Field(default=None, max_length=40)
    street_address: str = Field(..., min_length=3, max_length=300)
    city: str = Field(..., min_length=1, max_length=100)
    state_province: str = Field(default="Punjab", min_length=1, max_length=100)
    country: str = Field(default="Pakistan", min_length=1, max_length=100)
    postal_code: str = Field(..., min_length=1, max_length=30)
    is_default: bool = False


class CartSyncItem(BaseModel):
    product_id: int = Field(..., gt=0)
    quantity: int = Field(default=1, ge=1, le=100)
    selected_variant: str = Field(default="", max_length=100)


class CartBulkSyncRequest(BaseModel):
    items: list[CartSyncItem] = Field(default_factory=list, max_length=100)


class OrderStatusUpdateRequest(BaseModel):
    dispatch_status: Literal[
        "PENDING",
        "QUEUED_FOR_PACKING",
        "PROCESSING",
        "DISPATCHED",
        "SHIPPED",
        "DELIVERED",
        "CANCELLED",
    ]
    tracking_number: Optional[str] = Field(default=None, max_length=120)
