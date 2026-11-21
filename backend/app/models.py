
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
    UniqueConstraint,
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

    role = Column(
        String(32),
        nullable=False,
        default="customer",
        index=True,
    )

    full_name = Column(
        String(150),
        nullable=True,
    )

    is_active = Column(
        Boolean,
        nullable=False,
        default=True,
    )

    created_at = Column(
        DateTime(timezone=True),
        server_default=func.now(),
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

    category = Column(
        String(50),
        nullable=False,
        default="SYSTEM",
    )

    action_route = Column(
        String(255),
        nullable=True,
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


class Review(Base):
    __tablename__ = "reviews"
    __table_args__ = (
        UniqueConstraint("product_id", "user_id", name="uq_reviews_product_user"),
    )

    id = Column(Integer, primary_key=True, index=True)
    product_id = Column(
        Integer,
        ForeignKey("products.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    user_id = Column(
        Integer,
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    user_email = Column(String(254), nullable=False)
    rating = Column(Integer, nullable=False)
    title = Column(String(150), nullable=True)
    comment = Column(Text, nullable=False)
    verified_purchase = Column(Boolean, nullable=False, default=False)
    trust_score = Column(Float, nullable=False, default=85.0)
    is_flagged_suspicious = Column(Boolean, nullable=False, default=False)
    trust_flags = Column(Text, nullable=False, default="[]")
    aspect_sentiments = Column(Text, nullable=False, default="{}")
    moderation_status = Column(String(32), nullable=False, default="approved")
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())


class WishlistItem(Base):
    __tablename__ = "wishlists"
    __table_args__ = (
        UniqueConstraint("user_id", "product_id", name="uq_wishlists_user_product"),
    )

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(
        Integer,
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    product_id = Column(
        Integer,
        ForeignKey("products.id", ondelete="CASCADE"),
        nullable=False,
    )
    price_at_save = Column(Float, nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())


class RecentlyViewedItem(Base):
    __tablename__ = "recently_viewed"
    __table_args__ = (
        UniqueConstraint("user_id", "product_id", name="uq_recently_viewed_user_product"),
    )

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(
        Integer,
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    product_id = Column(
        Integer,
        ForeignKey("products.id", ondelete="CASCADE"),
        nullable=False,
    )
    viewed_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())


class UserAddress(Base):
    __tablename__ = "user_addresses"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(
        Integer,
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    label = Column(String(50), nullable=False, default="Home")
    recipient_name = Column(String(150), nullable=False)
    phone = Column(String(40), nullable=True)
    street_address = Column(String(300), nullable=False)
    city = Column(String(100), nullable=False)
    state_province = Column(String(100), nullable=False, default="Punjab")
    country = Column(String(100), nullable=False, default="Pakistan")
    postal_code = Column(String(30), nullable=False)
    is_default = Column(Boolean, nullable=False, default=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())


class CartItemModel(Base):
    __tablename__ = "cart_items"
    __table_args__ = (
        UniqueConstraint(
            "user_id",
            "product_id",
            "selected_variant",
            name="uq_cart_user_product_variant",
        ),
    )

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(
        Integer,
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    product_id = Column(
        Integer,
        ForeignKey("products.id", ondelete="CASCADE"),
        nullable=False,
    )
    quantity = Column(Integer, nullable=False, default=1)
    selected_variant = Column(String(100), nullable=False, default="")
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())


class CtrlXAuditLog(Base):
    __tablename__ = "ctrlx_audit_logs"

    id = Column(Integer, primary_key=True, index=True)
    thread_id = Column(String(200), nullable=False)
    user_email = Column(String(254), nullable=True)
    user_input = Column(String(500), nullable=False)
    routed_agent = Column(String(80), nullable=False)
    tools_called = Column(Text, nullable=False, default="[]")
    data_type = Column(String(50), nullable=False, default="text")
    latency_ms = Column(Float, nullable=False, default=0.0)
    status = Column(String(30), nullable=False, default="success")
    created_at = Column(DateTime(timezone=True), server_default=func.now())


class ProductReviewInsight(Base):
    __tablename__ = "product_review_insights"

    product_id = Column(
        Integer,
        ForeignKey("products.id", ondelete="CASCADE"),
        primary_key=True,
    )
    raw_rating = Column(Float, nullable=False, default=0.0)
    trust_weighted_rating = Column(Float, nullable=False, default=0.0)
    total_reviews = Column(Integer, nullable=False, default=0)
    verified_authentic_percent = Column(Float, nullable=False, default=100.0)
    flagged_count = Column(Integer, nullable=False, default=0)
    pros_json = Column(Text, nullable=False, default="[]")
    cons_json = Column(Text, nullable=False, default="[]")
    verdict = Column(Text, nullable=False, default="")
    aspect_bars_json = Column(Text, nullable=False, default="{}")
    review_count_at_generation = Column(Integer, nullable=False, default=0)
    updated_at = Column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
    )


class AIMetricsLog(Base):
    __tablename__ = "ai_metrics_logs"

    id = Column(Integer, primary_key=True, index=True)
    subsystem = Column(String(50), nullable=False, index=True)
    operation = Column(String(100), nullable=False, default="")
    latency_ms = Column(Float, nullable=False, default=0.0)
    success = Column(Boolean, nullable=False, default=True)
    top1_similarity = Column(Float, nullable=True)
    avg_top5_similarity = Column(Float, nullable=True)
    tool_calls_count = Column(Integer, nullable=True)
    trust_score = Column(Float, nullable=True)
    is_flagged_suspicious = Column(Boolean, nullable=True)
    original_size_kb = Column(Float, nullable=True)
    optimized_size_kb = Column(Float, nullable=True)
    reduction_percent = Column(Float, nullable=True)
    metadata_json = Column(Text, nullable=False, default="{}")
    created_at = Column(DateTime(timezone=True), server_default=func.now(), index=True)


class RFQRequest(Base):
    __tablename__ = "rfq_requests"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    customer_email = Column(String(254), nullable=False, index=True)
    customer_name = Column(String(150), nullable=False, default="")
    company_name = Column(String(150), nullable=False, default="")
    product_id = Column(Integer, ForeignKey("products.id", ondelete="CASCADE"), nullable=False, index=True)
    product_name = Column(String(200), nullable=False, default="")
    quantity = Column(Integer, nullable=False, default=10)
    target_unit_price = Column(Float, nullable=False)
    customization_notes = Column(Text, nullable=False, default="")
    delivery_deadline = Column(String(100), nullable=False, default="")
    status = Column(String(32), nullable=False, default="Pending", index=True)
    admin_quote_price = Column(Float, nullable=True)
    admin_reply = Column(Text, nullable=False, default="")
    created_at = Column(DateTime(timezone=True), server_default=func.now(), index=True)
    updated_at = Column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
    )


