from sqlalchemy import Column, Integer, String, Float, Boolean, Text
from .database import Base

class Product(Base):
    __tablename__ = "products"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, index=True, nullable=False)
    description = Column(Text, nullable=True) 
    price = Column(Float, nullable=False)
    original_price = Column(Float, nullable=True) 
    image_url = Column(String, nullable=False)
    category = Column(String, index=True, nullable=False)
    rating = Column(Float, default=0.0)
    reviews = Column(Integer, default=0)
    discount_percent = Column(Integer, nullable=True)
    is_featured = Column(Boolean, default=False)

# 1. User is now a separate, independent class
class User(Base):
    __tablename__ = "users"

    # 2. Fixed the underscore in primary_key
    id = Column(Integer, primary_key=True, index=True)
    email = Column(String, unique=True, index=True)
    hashed_password = Column(String)
    is_admin = Column(Boolean, default=False)