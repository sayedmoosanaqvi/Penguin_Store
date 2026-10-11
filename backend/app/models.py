
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

    image_embedding = Column(
        VECTOR(512),
        nullable=True,
    )

    image_embedding_v2 = Column(
        VECTOR(2048),
        nullable=True,
    )

    visual_embedding = Column(
        Text,
        nullable=True,
    )

    assets_3d = relationship(
        "Product3DAsset",
        back_populates="product",
        cascade="all, delete-orphan",
        passive_deletes=True,
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

    premium_subscription = relationship(
        "PremiumSubscription",
        back_populates="user",
        uselist=False,
        cascade="all, delete-orphan",
        passive_deletes=True,
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

    created_at = Column(
        DateTime,
        default=datetime.utcnow,
        index=True,
    )

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


class Product3DAsset(Base):
    __tablename__ = "product_3d_assets"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
    )

    product_id = Column(
        Integer,
        ForeignKey(
            "products.id",
            ondelete="CASCADE",
        ),
        nullable=False,
        index=True,
    )

    display_name = Column(
        String(150),
        nullable=False,
        default="3D Product View",
    )

    variant_name = Column(
        String(100),
        nullable=True,
    )

    storage_bucket = Column(
        String(100),
        nullable=False,
        default="penguin-store-3d",
    )

    storage_path = Column(
        String(512),
        unique=True,
        nullable=False,
    )

    model_format = Column(
        String(20),
        nullable=False,
        default="glb",
    )

    file_size_bytes = Column(
        Integer,
        nullable=True,
    )

    is_active = Column(
        Boolean,
        nullable=False,
        default=False,
    )

    created_at = Column(
        DateTime(timezone=True),
        server_default=func.now(),
    )

    updated_at = Column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
    )

    product = relationship(
        "Product",
        back_populates="assets_3d",
    )


class PremiumSubscription(Base):
    __tablename__ = "premium_subscriptions"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
    )

    user_id = Column(
        Integer,
        ForeignKey(
            "users.id",
            ondelete="CASCADE",
        ),
        unique=True,
        nullable=False,
        index=True,
    )

    stripe_customer_id = Column(
        String(255),
        unique=True,
        nullable=True,
    )

    stripe_subscription_id = Column(
        String(255),
        unique=True,
        nullable=True,
    )

    stripe_price_id = Column(
        String(255),
        nullable=True,
    )

    plan_name = Column(
        String(50),
        nullable=False,
        default="premium",
    )

    status = Column(
        String(50),
        nullable=False,
        default="inactive",
        index=True,
    )

    current_period_end = Column(
        DateTime(timezone=True),
        nullable=True,
    )

    cancel_at_period_end = Column(
        Boolean,
        nullable=False,
        default=False,
    )

    created_at = Column(
        DateTime(timezone=True),
        server_default=func.now(),
    )

    updated_at = Column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
    )

    user = relationship(
        "User",
        back_populates="premium_subscription",
    )
