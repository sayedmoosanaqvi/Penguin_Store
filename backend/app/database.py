import os
from sqlalchemy import create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
from dotenv import load_dotenv

# Load environment variables from the .env file in the backend directory
load_dotenv()

# --- NEW SUPABASE SETUP ---
# Look for SUPABASE_DATABASE_URL, or fall back to DATABASE_URL or the direct string if missing
SQLALCHEMY_DATABASE_URL = os.getenv("SUPABASE_DATABASE_URL") or os.getenv("DATABASE_URL")

# Fallback hardcoded safeguard so it never evaluates to None
if not SQLALCHEMY_DATABASE_URL:
    SQLALCHEMY_DATABASE_URL = "postgresql://postgres.bjfspmjpiagfqildttjd:Penguinstore%401234@aws-0-ap-northeast-1.pooler.supabase.com:5432/postgres"

# SQLAlchemy requires the dialect to be 'postgresql://' instead of 'postgres://'
if SQLALCHEMY_DATABASE_URL and SQLALCHEMY_DATABASE_URL.startswith("postgres://"):
    SQLALCHEMY_DATABASE_URL = SQLALCHEMY_DATABASE_URL.replace("postgres://", "postgresql://", 1)

# Establish the connection engine
engine = create_engine(SQLALCHEMY_DATABASE_URL)

# Create a session factory
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# Base class for our models
Base = declarative_base()

# Dependency to get the database session for API routes
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()