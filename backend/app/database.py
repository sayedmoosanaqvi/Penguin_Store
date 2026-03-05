from sqlalchemy import create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker

# TODO: Change 'postgres' and 'YOUR_PASSWORD' to your actual PostgreSQL credentials.
# 'penguin_store' is the name of the database we will create.
SQLALCHEMY_DATABASE_URL = "postgresql://postgres:90849512026@localhost/Penguin_Store"

# Establish the connection engine
engine = create_engine(SQLALCHEMY_DATABASE_URL)

# Create a session factory
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# Base class for our models to inherit from
Base = declarative_base()

# Dependency to get the database session for our API routes
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()