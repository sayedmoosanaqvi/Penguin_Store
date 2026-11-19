"""PostgreSQL (Supabase) database engine and session lifecycle."""

from __future__ import annotations

import logging

from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

from .config import settings

logger = logging.getLogger(__name__)

SQLALCHEMY_DATABASE_URL = settings.SUPABASE_DATABASE_URL

if not SQLALCHEMY_DATABASE_URL:
    raise RuntimeError(
        "Database connection string is missing. "
        "Set SUPABASE_DATABASE_URL or DATABASE_URL."
    )

if SQLALCHEMY_DATABASE_URL.startswith("postgres://"):
    SQLALCHEMY_DATABASE_URL = SQLALCHEMY_DATABASE_URL.replace(
        "postgres://",
        "postgresql://",
        1,
    )

engine = create_engine(
    SQLALCHEMY_DATABASE_URL,
    pool_size=4,
    max_overflow=4,
    pool_pre_ping=True,
    pool_recycle=180,
    pool_timeout=15,
    connect_args={
        "sslmode": "require",
        "connect_timeout": 3,
        "keepalives": 1,
        "keepalives_idle": 30,
        "keepalives_interval": 10,
        "keepalives_count": 3,
    },
    pool_reset_on_return="rollback",
)

SessionLocal = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=engine,
    expire_on_commit=False,
)

Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
