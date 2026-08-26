from datetime import datetime
from sqlalchemy import Column, Integer, String, Float, Boolean, Text, ForeignKey, DateTime
from sqlalchemy.orm import relationship
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
    stock = Column(Integer, default=50)

    # Hybrid Inventory & Dropshipping Metadata
    fulfillment_type = Column(String, default="IN_HOUSE")
    supplier_id = Column(String, default="PENGUIN_DIRECT")
    supplier_sku = Column(String, nullable=True)
    cost_price = Column(Float, nullable=True)


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    email = Column(String, unique=True, index=True)
    hashed_password = Column(String)
    is_admin = Column(Boolean, default=False)


class Order(Base):
    __tablename__ = "orders"

    id = Column(Integer, primary_key=True, index=True)
    customer_name = Column(String, nullable=False)
    customer_email = Column(String, nullable=False)
    shipping_address = Column(String, nullable=False)
    city = Column(String, nullable=False)
    postal_code = Column(String, nullable=False)
    total_amount = Column(Float, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)

    # Relationship to individual items
    items = relationship("OrderItem", back_populates="order")


class OrderItem(Base):
    __tablename__ = "order_items"

    id = Column(Integer, primary_key=True, index=True)
    order_id = Column(Integer, ForeignKey("orders.id"))
    product_id = Column(Integer, ForeignKey("products.id"))
    quantity = Column(Integer, default=1)
    unit_price = Column(Float, nullable=False)
    
    # Fulfillment tracking per line item
    fulfillment_type = Column(String, nullable=False)   # 'IN_HOUSE' or 'DROPSHIP'
    dispatch_status = Column(String, default="PENDING")  # 'PENDING', 'DISPATCHED', 'PACKING'
    tracking_number = Column(String, nullable=True)

    order = relationship("Order", back_populates="items")