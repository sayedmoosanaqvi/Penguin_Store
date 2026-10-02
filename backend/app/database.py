import os

from dotenv import load_dotenv
from sqlalchemy import create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import NullPool


# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

# Loads .env locally.
# Render will use its own environment variables in production.
load_dotenv()


# ---------------------------------------------------------------------------
# Database URL
# ---------------------------------------------------------------------------

SQLALCHEMY_DATABASE_URL = (
    os.getenv("SUPABASE_DATABASE_URL")
    or os.getenv("DATABASE_URL")
)

if not SQLALCHEMY_DATABASE_URL:
    raise RuntimeError(
        "Database connection string is missing. "
        "Set SUPABASE_DATABASE_URL or DATABASE_URL."
    )


# SQLAlchemy expects the modern postgresql:// dialect.
if SQLALCHEMY_DATABASE_URL.startswith("postgres://"):
    SQLALCHEMY_DATABASE_URL = SQLALCHEMY_DATABASE_URL.replace(
        "postgres://",
        "postgresql://",
        1,
    )


# ---------------------------------------------------------------------------
# Database engine
# ---------------------------------------------------------------------------

# Your current Supabase connection uses the transaction pooler (6543).
#
# NullPool is intentional here:
# Supabase's external pooler manages the database-side connections,
# so we avoid maintaining another persistent application-side pool.
#
# This is also useful on a memory-constrained Render instance.
engine = create_engine(
    SQLALCHEMY_DATABASE_URL,
    poolclass=NullPool,
    connect_args={
        "sslmode": "require",
    },
)


# ---------------------------------------------------------------------------
# Session factory
# ---------------------------------------------------------------------------

SessionLocal = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=engine,
)


# ---------------------------------------------------------------------------
# SQLAlchemy models base
# ---------------------------------------------------------------------------

Base = declarative_base()


# ---------------------------------------------------------------------------
# FastAPI database dependency
# ---------------------------------------------------------------------------

def get_db():
    db = SessionLocal()

    try:
        yield db
    finally:
        db.close()