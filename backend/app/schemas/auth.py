"""Strict Pydantic schemas for authentication, user profiles, and RBAC management."""

from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field


class UserCreate(BaseModel):
    email: str = Field(..., min_length=3, max_length=254)
    password: str = Field(..., min_length=8, max_length=72)
    full_name: Optional[str] = Field(default=None, max_length=150)


class UserProfileResponse(BaseModel):
    id: int
    email: str
    full_name: Optional[str] = None
    is_admin: bool
    role: str


class UserRoleUpdate(BaseModel):
    role: Literal["customer", "supplier", "admin"]


class DeleteAccountRequest(BaseModel):
    password: str = Field(..., min_length=1, max_length=72)
