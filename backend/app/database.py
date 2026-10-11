
import os
import logging

from dotenv import load_dotenv
from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

load_dotenv()

logger = logging.getLogger(__name__)

SQLALCHEMY_DATABASE_URL = (
    os.getenv("SUPABASE_DATABASE_URL")
    or os.getenv("DATABASE_URL")
)

if not SQLALCHEMY_DATABASE_URL:
    raise RuntimeError(
        "Database connection string is missing. "
        "Set SUPABASE_DATABASE_URL or DATABASE_URL."
    )

if SQLALCHEMY_DATABASE_URL.startswith("postgres://"):
    SQLALCHEMY_DATABASE_URL = (
        SQLALCHEMY_DATABASE_URL.replace(
            "postgres://",
            "postgresql://",
            1,
        )
    )

engine = create_engine(
    SQLALCHEMY_DATABASE_URL,

    # Reuse a small number of connections.
    pool_size=2,
    max_overflow=2,

    # Check a connection before reusing it.
    pool_pre_ping=True,

    # Refresh old connections periodically.
    pool_recycle=180,

    # Limit waiting for an available pooled connection.
    pool_timeout=15,

    # Limit PostgreSQL connection establishment time.
    connect_args={
        "sslmode": "require",
        "connect_timeout": 10,
    },

    # Roll back any unfinished transaction on return.
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
