"""Strict Pydantic schemas for product management and catalog responses."""

from __future__ import annotations

from typing import Optional

from pydantic import BaseModel, ConfigDict, Field


class ProductBase(BaseModel):
    name: str = Field(..., min_length=1, max_length=160)
    description: Optional[str] = Field(default=None, max_length=4000)
    price: float = Field(..., gt=0, le=1_000_000)
    original_price: Optional[float] = Field(default=None, gt=0, le=1_000_000)
    image_url: str = Field(default="", max_length=1024)
    category: str = Field(..., min_length=1, max_length=100)
    rating: Optional[float] = Field(default=0.0, ge=0.0, le=5.0)
    reviews: Optional[int] = Field(default=0, ge=0)
    discount_percent: Optional[int] = Field(default=None, ge=0, le=95)
    is_featured: Optional[bool] = False


class ProductCreate(ProductBase):
    stock: Optional[int] = Field(default=50, ge=0, le=1_000_000)
    fulfillment_type: Optional[str] = Field(default="IN_HOUSE", max_length=32)


class ProductUpdate(BaseModel):
    name: Optional[str] = Field(default=None, min_length=1, max_length=160)
    description: Optional[str] = Field(default=None, max_length=4000)
    price: Optional[float] = Field(default=None, gt=0, le=1_000_000)
    original_price: Optional[float] = Field(default=None, gt=0, le=1_000_000)
    image_url: Optional[str] = Field(default=None, max_length=1024)
    category: Optional[str] = Field(default=None, min_length=1, max_length=100)
    discount_percent: Optional[int] = Field(default=None, ge=0, le=95)
    is_featured: Optional[bool] = None
    stock: Optional[int] = Field(default=None, ge=0, le=1_000_000)


class Product(ProductBase):
    id: int

    model_config = ConfigDict(from_attributes=True)
