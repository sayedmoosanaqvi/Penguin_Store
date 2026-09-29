import os
from sqlalchemy import create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
from dotenv import load_dotenv

# Load environment variables from the .env file in the backend directory
load_dotenv()

# --- SUPABASE SETUP ---
SQLALCHEMY_DATABASE_URL = os.getenv("SUPABASE_DATABASE_URL") or os.getenv("DATABASE_URL")

# Fallback hardcoded safeguard (Updated to Port 6543 for Transaction Mode)
if not SQLALCHEMY_DATABASE_URL:
    SQLALCHEMY_DATABASE_URL = "postgresql://postgres.bjfspmjpiagfqildttjd:Penguinstore%401234@aws-0-ap-northeast-1.pooler.supabase.com:6543/postgres"

# Ensure postgresql:// dialect is used
if SQLALCHEMY_DATABASE_URL and SQLALCHEMY_DATABASE_URL.startswith("postgres://"):
    SQLALCHEMY_DATABASE_URL = SQLALCHEMY_DATABASE_URL.replace("postgres://", "postgresql://", 1)

# Establish the connection engine with pool safeguards
engine = create_engine(
    SQLALCHEMY_DATABASE_URL,
    pool_pre_ping=True,   # Tests connection liveness before every query
    pool_recycle=300      # Recycles connections every 5 minutes to prevent stale SSL drops
)

# Create a session factory
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# Base class for models
Base = declarative_base()

# Dependency to get the database session for API routes
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()