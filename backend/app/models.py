from datetime import datetime

from pgvector.sqlalchemy import VECTOR
from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
)
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func

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

    # -----------------------------------------------------------------------
    # Hybrid Inventory & Dropshipping Metadata
    # -----------------------------------------------------------------------

    fulfillment_type = Column(
        String,
        default="IN_HOUSE",
    )

    supplier_id = Column(
        String,
        default="PENGUIN_DIRECT",
    )

    supplier_sku = Column(
        String,
        nullable=True,
    )

    cost_price = Column(
        Float,
        nullable=True,
    )
    # -----------------------------------------------------------------------
    # Visual Search Embeddings
    # -----------------------------------------------------------------------

    # Existing 512-D embedding column.
    # Kept unchanged for compatibility with the previous pipeline.
    image_embedding = Column(
        VECTOR(512),
        nullable=True,
    )

    # New 2048-D embedding column used by the lightweight
    # ResNet-based visual search pipeline.
    image_embedding_v2 = Column(
        VECTOR(2048),
        nullable=True,
    )

    # -----------------------------------------------------------------------
    # Legacy column
    # -----------------------------------------------------------------------
    #
    # Kept because it exists in the database.
    # VS Code search showed this is not referenced elsewhere in the codebase.
    # We are deliberately not deleting it from PostgreSQL in this step.
    #

    visual_embedding = Column(
        Text,
        nullable=True,
    )


class User(Base):
    __tablename__ = "users"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
    )

    email = Column(
        String,
        unique=True,
        index=True,
    )

    hashed_password = Column(
        String,
    )

    is_admin = Column(
        Boolean,
        default=False,
    )


class Order(Base):
    __tablename__ = "orders"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
    )

    customer_name = Column(
        String,
        nullable=False,
    )

    customer_email = Column(
        String,
        nullable=False,
    )

    # -----------------------------------------------------------------------
    # Geographic / shipping data
    # -----------------------------------------------------------------------

    shipping_address = Column(
        String,
        nullable=False,
    )

    city = Column(
        String,
        nullable=False,
    )

    state_province = Column(
        String,
        index=True,
        nullable=False,
    )

    country = Column(
        String,
        index=True,
        default="Pakistan",
    )

    postal_code = Column(
        String,
        nullable=False,
    )

    total_amount = Column(
        Float,
        nullable=False,
    )

    # -----------------------------------------------------------------------
    # Timestamp
    # -----------------------------------------------------------------------

    created_at = Column(
        DateTime,
        default=datetime.utcnow,
        index=True,
    )

    # -----------------------------------------------------------------------
    # Relationships
    # -----------------------------------------------------------------------

    items = relationship(
        "OrderItem",
        back_populates="order",
    )


class OrderItem(Base):
    __tablename__ = "order_items"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
    )

    order_id = Column(
        Integer,
        ForeignKey("orders.id"),
    )

    product_id = Column(
        Integer,
        ForeignKey("products.id"),
    )

    quantity = Column(
        Integer,
        default=1,
    )

    unit_price = Column(
        Float,
        nullable=False,
    )

    # -----------------------------------------------------------------------
    # Fulfillment tracking
    # -----------------------------------------------------------------------

    fulfillment_type = Column(
        String,
        nullable=False,
    )

    dispatch_status = Column(
        String,
        default="PENDING",
    )

    tracking_number = Column(
        String,
        nullable=True,
    )

    order = relationship(
        "Order",
        back_populates="items",
    )


class Notification(Base):
    __tablename__ = "notifications"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
    )

    customer_email = Column(
        String,
        index=True,
    )

    title = Column(
        String,
    )

    message = Column(
        String,
    )

    is_read = Column(
        Boolean,
        default=False,
    )

    notification_type = Column(
        String,
    )

    created_at = Column(
        DateTime(timezone=True),
        server_default=func.now(),
    )