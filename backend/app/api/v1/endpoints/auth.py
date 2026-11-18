"""Versioned Auth & Play Store Account Deletion endpoints (/api/v1/auth)."""

from __future__ import annotations

import re

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy import func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.security import (
    create_access_token,
    get_current_user,
    get_password_hash,
    resolve_user_role,
    verify_password,
)
from app.models import User
from app.schemas.auth import (
    DeleteAccountRequest,
    UserCreate,
    UserProfileResponse,
)

router = APIRouter(prefix="/auth", tags=["Auth & Account"])


@router.post("/register", status_code=status.HTTP_201_CREATED)
def register_user(
    user: UserCreate,
    db: Session = Depends(get_db),
):
    email = user.email.strip().lower()
    password = user.password

    if len(email) > 254 or not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", email):
        raise HTTPException(status_code=422, detail="Enter a valid email address.")

    password_bytes = password.encode("utf-8")
    if len(password) < 8:
        raise HTTPException(
            status_code=422,
            detail="Password must contain at least 8 characters.",
        )
    if len(password_bytes) > 72:
        raise HTTPException(
            status_code=422,
            detail="Password exceeds the supported length.",
        )

    existing = (
        db.query(User.id)
        .filter(func.lower(User.email) == email)
        .first()
    )
    if existing:
        raise HTTPException(status_code=400, detail="Email already registered")

    new_user = User(
        email=email,
        full_name=user.full_name.strip() if user.full_name else None,
        hashed_password=get_password_hash(password),
        is_admin=False,
        role="customer",
        is_active=True,
    )

    try:
        db.add(new_user)
        db.commit()
        db.refresh(new_user)
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=400, detail="Email already registered")

    return {
        "message": "User created successfully. Welcome to Penguin Store!"
    }


@router.post("/login")
def login_user(
    form_data: OAuth2PasswordRequestForm = Depends(),
    db: Session = Depends(get_db),
):
    email = form_data.username.strip().lower()
    user = (
        db.query(User)
        .filter(func.lower(User.email) == email)
        .first()
    )

    if (
        not user
        or not getattr(user, "is_active", True)
        or not verify_password(form_data.password, user.hashed_password)
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )

    role = resolve_user_role(user)
    access_token = create_access_token(
        data={
            "sub": user.email,
            "is_admin": bool(user.is_admin or role == "admin"),
            "role": role,
        }
    )

    return {
        "access_token": access_token,
        "token_type": "bearer",
        "role": role,
    }


@router.get("/me", response_model=UserProfileResponse)
def get_authenticated_profile(
    current_user: User = Depends(get_current_user),
):
    role = resolve_user_role(current_user)
    return UserProfileResponse(
        id=current_user.id,
        email=current_user.email,
        full_name=getattr(current_user, "full_name", None),
        is_admin=bool(current_user.is_admin or role == "admin"),
        role=role,
    )


@router.delete("/me", status_code=status.HTTP_200_OK)
def delete_my_account(
    payload: DeleteAccountRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    Google Play Store compliant account deletion endpoint.
    Requires password re-verification before deleting user credentials & personal data.
    """
    if not verify_password(payload.password, current_user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Incorrect password. Account deletion cancelled.",
        )

    if resolve_user_role(current_user) == "admin":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Administrator accounts cannot be self-deleted from client apps.",
        )

    try:
        db.delete(current_user)
        db.commit()
    except Exception:
        db.rollback()
        raise HTTPException(
            status_code=500,
            detail="Unable to delete account right now.",
        )

    return {"status": "deleted", "message": "Your Penguin Store account has been permanently deleted."}
