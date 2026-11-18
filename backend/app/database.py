"""Backward-compatible facade delegating to app.core.database."""

from app.core.database import (
    SQLALCHEMY_DATABASE_URL,
    Base,
    SessionLocal,
    engine,
    get_db,
)

__all__ = [
    "SQLALCHEMY_DATABASE_URL",
    "Base",
    "SessionLocal",
    "engine",
    "get_db",
]
