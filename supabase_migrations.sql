-- ============================================================================
-- Penguin Store — Enterprise Security, RBAC & Feature Migrations for Supabase
-- Safe & Idempotent: Preserves all existing data including Product #144 & GLBs
-- Run inside Supabase Dashboard -> SQL Editor
-- ============================================================================

-- 1. RBAC & Play Store Account Compliance on `users`
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS role VARCHAR(32) NOT NULL DEFAULT 'customer',
    ADD COLUMN IF NOT EXISTS full_name VARCHAR(150),
    ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Synchronize existing admin accounts
UPDATE users
SET role = 'admin'
WHERE is_admin = TRUE AND role <> 'admin';

CREATE INDEX IF NOT EXISTS idx_users_lower_email ON users (LOWER(email));
CREATE INDEX IF NOT EXISTS idx_users_role ON users (role);


-- 2. Product Reviews & Star Ratings (`reviews`)
CREATE TABLE IF NOT EXISTS reviews (
    id SERIAL PRIMARY KEY,
    product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    user_email VARCHAR(254) NOT NULL,
    rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
    title VARCHAR(150),
    comment TEXT NOT NULL,
    verified_purchase BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_reviews_product_user UNIQUE (product_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_reviews_product_created
    ON reviews (product_id, created_at DESC);


-- Automatically keep `products.rating` and `products.reviews` synchronized
CREATE OR REPLACE FUNCTION sync_product_review_aggregates()
RETURNS TRIGGER AS $$
DECLARE
    target_product_id INTEGER;
    avg_rating DOUBLE PRECISION;
    total_reviews INTEGER;
BEGIN
    target_product_id := COALESCE(NEW.product_id, OLD.product_id);

    SELECT
        COALESCE(ROUND(AVG(rating)::numeric, 2)::double precision, 0.0),
        COUNT(*)::integer
    INTO avg_rating, total_reviews
    FROM reviews
    WHERE product_id = target_product_id;

    UPDATE products
    SET rating = avg_rating,
        reviews = total_reviews
    WHERE id = target_product_id;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_product_reviews ON reviews;
CREATE TRIGGER trg_sync_product_reviews
AFTER INSERT OR UPDATE OR DELETE ON reviews
FOR EACH ROW EXECUTE FUNCTION sync_product_review_aggregates();


-- 3. Persistent Wishlist / Favorites (`wishlists`)
CREATE TABLE IF NOT EXISTS wishlists (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    price_at_save DOUBLE PRECISION,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_wishlists_user_product UNIQUE (user_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_wishlists_user ON wishlists (user_id, created_at DESC);


-- 4. Recently Viewed Products (`recently_viewed`)
CREATE TABLE IF NOT EXISTS recently_viewed (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    viewed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_recently_viewed_user_product UNIQUE (user_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_recently_viewed_user_time
    ON recently_viewed (user_id, viewed_at DESC);


-- 5. Saved Shipping Addresses (`user_addresses`)
CREATE TABLE IF NOT EXISTS user_addresses (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    label VARCHAR(50) NOT NULL DEFAULT 'Home',
    recipient_name VARCHAR(150) NOT NULL,
    phone VARCHAR(40),
    street_address VARCHAR(300) NOT NULL,
    city VARCHAR(100) NOT NULL,
    state_province VARCHAR(100) NOT NULL DEFAULT 'Punjab',
    country VARCHAR(100) NOT NULL DEFAULT 'Pakistan',
    postal_code VARCHAR(30) NOT NULL,
    is_default BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_user_addresses_user ON user_addresses (user_id);


-- 6. Server-Synced Persistent Cart (`cart_items`)
CREATE TABLE IF NOT EXISTS cart_items (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    quantity INTEGER NOT NULL DEFAULT 1 CHECK (quantity >= 1 AND quantity <= 100),
    selected_variant VARCHAR(100) NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_cart_user_product_variant UNIQUE (user_id, product_id, selected_variant)
);

CREATE INDEX IF NOT EXISTS idx_cart_items_user ON cart_items (user_id);


-- 7. Enhanced Notification Center (`notifications`)
ALTER TABLE notifications
    ADD COLUMN IF NOT EXISTS category VARCHAR(50) NOT NULL DEFAULT 'SYSTEM',
    ADD COLUMN IF NOT EXISTS action_route VARCHAR(255);

CREATE INDEX IF NOT EXISTS idx_notifications_email_read_created
    ON notifications (LOWER(customer_email), is_read, created_at DESC);


-- 8. CTRL-X Persistent Execution Audit Logs (`ctrlx_audit_logs`)
CREATE TABLE IF NOT EXISTS ctrlx_audit_logs (
    id SERIAL PRIMARY KEY,
    thread_id VARCHAR(200) NOT NULL,
    user_email VARCHAR(254),
    user_input VARCHAR(500) NOT NULL,
    routed_agent VARCHAR(80) NOT NULL,
    tools_called TEXT NOT NULL DEFAULT '[]',
    data_type VARCHAR(50) NOT NULL DEFAULT 'text',
    latency_ms DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    status VARCHAR(30) NOT NULL DEFAULT 'success',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ctrlx_audit_created
    ON ctrlx_audit_logs (created_at DESC);


-- 9. Storefront & Order Query Indexes
CREATE INDEX IF NOT EXISTS idx_orders_lower_email_created
    ON orders (LOWER(customer_email), created_at DESC);
CREATE INDEX IF NOT EXISTS idx_order_items_order_id
    ON order_items (order_id);
CREATE INDEX IF NOT EXISTS idx_3d_assets_product_active
    ON product_3d_assets (product_id, is_active);


-- 10. Row Level Security (RLS) Policies
-- Locks down PostgREST `anon` direct table access while keeping FastAPI
-- PostgreSQL / service_role access functional and enforcing per-user isolation.

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_3d_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE premium_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE wishlists ENABLE ROW LEVEL SECURITY;
ALTER TABLE recently_viewed ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_addresses ENABLE ROW LEVEL SECURITY;
ALTER TABLE cart_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE ctrlx_audit_logs ENABLE ROW LEVEL SECURITY;

-- Public catalog & reviews read policies (safe for storefront browsing)
DROP POLICY IF EXISTS "Public read products" ON products;
CREATE POLICY "Public read products" ON products
    FOR SELECT USING (TRUE);

DROP POLICY IF EXISTS "Public read active 3d assets" ON product_3d_assets;
CREATE POLICY "Public read active 3d assets" ON product_3d_assets
    FOR SELECT USING (is_active = TRUE);

DROP POLICY IF EXISTS "Public read reviews" ON reviews;
CREATE POLICY "Public read reviews" ON reviews
    FOR SELECT USING (TRUE);

-- Service-role full-access policies for backend/Supabase client operations
DROP POLICY IF EXISTS "Service role full users" ON users;
CREATE POLICY "Service role full users" ON users
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full orders" ON orders;
CREATE POLICY "Service role full orders" ON orders
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full order_items" ON order_items;
CREATE POLICY "Service role full order_items" ON order_items
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full notifications" ON notifications;
CREATE POLICY "Service role full notifications" ON notifications
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full wishlists" ON wishlists;
CREATE POLICY "Service role full wishlists" ON wishlists
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full recently_viewed" ON recently_viewed;
CREATE POLICY "Service role full recently_viewed" ON recently_viewed
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full user_addresses" ON user_addresses;
CREATE POLICY "Service role full user_addresses" ON user_addresses
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full cart_items" ON cart_items;
CREATE POLICY "Service role full cart_items" ON cart_items
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full reviews" ON reviews;
CREATE POLICY "Service role full reviews" ON reviews
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full ctrlx_audit_logs" ON ctrlx_audit_logs;
CREATE POLICY "Service role full ctrlx_audit_logs" ON ctrlx_audit_logs
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');


-- ============================================================================
-- 11. FYP PHASE 1: AI-Powered Trustworthy Review & Fake Review Detection Engine
-- ============================================================================

ALTER TABLE reviews
    ADD COLUMN IF NOT EXISTS trust_score DOUBLE PRECISION NOT NULL DEFAULT 85.0,
    ADD COLUMN IF NOT EXISTS is_flagged_suspicious BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS trust_flags TEXT NOT NULL DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS aspect_sentiments TEXT NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS moderation_status VARCHAR(32) NOT NULL DEFAULT 'approved';

CREATE INDEX IF NOT EXISTS idx_reviews_flagged_status
    ON reviews (is_flagged_suspicious, moderation_status, created_at DESC);

-- Exclude hidden spam reviews from public product aggregate rating
CREATE OR REPLACE FUNCTION sync_product_review_aggregates()
RETURNS TRIGGER AS $$
DECLARE
    target_product_id INTEGER;
    avg_rating DOUBLE PRECISION;
    total_reviews INTEGER;
BEGIN
    target_product_id := COALESCE(NEW.product_id, OLD.product_id);

    SELECT
        COALESCE(ROUND(AVG(rating)::numeric, 2)::double precision, 0.0),
        COUNT(*)::integer
    INTO avg_rating, total_reviews
    FROM reviews
    WHERE product_id = target_product_id
      AND COALESCE(moderation_status, 'approved') <> 'hidden';

    UPDATE products
    SET rating = avg_rating,
        reviews = total_reviews
    WHERE id = target_product_id;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Cached AI Review Summarizer & Aspect Sentiment Insights per product
CREATE TABLE IF NOT EXISTS product_review_insights (
    product_id INTEGER PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
    raw_rating DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    trust_weighted_rating DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    total_reviews INTEGER NOT NULL DEFAULT 0,
    verified_authentic_percent DOUBLE PRECISION NOT NULL DEFAULT 100.0,
    flagged_count INTEGER NOT NULL DEFAULT 0,
    pros_json TEXT NOT NULL DEFAULT '[]',
    cons_json TEXT NOT NULL DEFAULT '[]',
    verdict TEXT NOT NULL DEFAULT '',
    aspect_bars_json TEXT NOT NULL DEFAULT '{}',
    review_count_at_generation INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE product_review_insights ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read product_review_insights" ON product_review_insights;
CREATE POLICY "Public read product_review_insights" ON product_review_insights
    FOR SELECT USING (TRUE);

DROP POLICY IF EXISTS "Service role full product_review_insights" ON product_review_insights;
CREATE POLICY "Service role full product_review_insights" ON product_review_insights
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');


-- ============================================================================
-- 12. FYP PHASE 3: Examiner-Ready AI Evaluation & System Metrics Telemetry
-- ============================================================================

CREATE TABLE IF NOT EXISTS ai_metrics_logs (
    id SERIAL PRIMARY KEY,
    subsystem VARCHAR(50) NOT NULL,
    operation VARCHAR(100) NOT NULL DEFAULT '',
    latency_ms DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    success BOOLEAN NOT NULL DEFAULT TRUE,
    top1_similarity DOUBLE PRECISION,
    avg_top5_similarity DOUBLE PRECISION,
    tool_calls_count INTEGER,
    trust_score DOUBLE PRECISION,
    is_flagged_suspicious BOOLEAN,
    original_size_kb DOUBLE PRECISION,
    optimized_size_kb DOUBLE PRECISION,
    reduction_percent DOUBLE PRECISION,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ai_metrics_subsystem_created
    ON ai_metrics_logs (subsystem, created_at DESC);

ALTER TABLE ai_metrics_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role full ai_metrics_logs" ON ai_metrics_logs;
CREATE POLICY "Service role full ai_metrics_logs" ON ai_metrics_logs
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');



-- ============================================================================
-- 13. B2B / B2C COMMERCIAL UPGRADE: Variants, Add-Ons, Bulk Tiers & RFQ System
-- ============================================================================

ALTER TABLE products
    ADD COLUMN IF NOT EXISTS variants_json TEXT NOT NULL DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS bulk_tiers_json TEXT NOT NULL DEFAULT '[]';

ALTER TABLE orders
    ADD COLUMN IF NOT EXISTS subtotal_amount DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS discount_amount DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    ADD COLUMN IF NOT EXISTS tax_amount DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    ADD COLUMN IF NOT EXISTS promo_code VARCHAR(64),
    ADD COLUMN IF NOT EXISTS currency_code VARCHAR(12) NOT NULL DEFAULT 'USD';

ALTER TABLE order_items
    ADD COLUMN IF NOT EXISTS selected_variant VARCHAR(120),
    ADD COLUMN IF NOT EXISTS selected_addons TEXT NOT NULL DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS pricing_mode VARCHAR(32) NOT NULL DEFAULT 'B2C';

CREATE TABLE IF NOT EXISTS rfq_requests (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
    customer_email VARCHAR(254) NOT NULL,
    customer_name VARCHAR(150) NOT NULL DEFAULT '',
    company_name VARCHAR(150) NOT NULL DEFAULT '',
    product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    product_name VARCHAR(200) NOT NULL DEFAULT '',
    quantity INTEGER NOT NULL CHECK (quantity >= 5),
    target_unit_price DOUBLE PRECISION NOT NULL CHECK (target_unit_price > 0),
    customization_notes TEXT NOT NULL DEFAULT '',
    delivery_deadline VARCHAR(100) NOT NULL DEFAULT '',
    status VARCHAR(32) NOT NULL DEFAULT 'Pending',
    admin_quote_price DOUBLE PRECISION,
    admin_reply TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rfq_requests_email
    ON rfq_requests (customer_email, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_rfq_requests_status
    ON rfq_requests (status, created_at DESC);

ALTER TABLE rfq_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role full rfq_requests" ON rfq_requests;
CREATE POLICY "Service role full rfq_requests" ON rfq_requests
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');



-- ============================================================================
-- 14. FINAL PRODUCTION UPGRADE: Stripe Payment Lifecycle, Favorites & Indexes
-- ============================================================================

ALTER TABLE orders
    ADD COLUMN IF NOT EXISTS payment_method VARCHAR(32) NOT NULL DEFAULT 'COD',
    ADD COLUMN IF NOT EXISTS payment_status VARCHAR(32) NOT NULL DEFAULT 'pending',
    ADD COLUMN IF NOT EXISTS stripe_session_id VARCHAR(255),
    ADD COLUMN IF NOT EXISTS email_sent BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_orders_stripe_session
    ON orders (stripe_session_id)
    WHERE stripe_session_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS favorites (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    price_at_save DOUBLE PRECISION,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_favorites_user_product UNIQUE (user_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_favorites_user_created
    ON favorites (user_id, created_at DESC);

ALTER TABLE favorites ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role full favorites" ON favorites;
CREATE POLICY "Service role full favorites" ON favorites
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

-- Performance indexes for <100ms catalog & 3D showcase queries
CREATE INDEX IF NOT EXISTS idx_products_category
    ON products (category);

CREATE INDEX IF NOT EXISTS idx_products_price
    ON products (price);

CREATE INDEX IF NOT EXISTS idx_products_stock
    ON products (stock)
    WHERE stock > 0;

CREATE INDEX IF NOT EXISTS idx_products_featured
    ON products (is_featured, id DESC);

CREATE INDEX IF NOT EXISTS idx_product_3d_assets_active
    ON product_3d_assets (product_id, is_active)
    WHERE is_active = TRUE;


-- ============================================================================
-- 15. VOICE INTELLIGENCE & MULTIMODAL RRF SEARCH TELEMETRY
-- ============================================================================

ALTER TABLE ctrlx_audit_logs
    ADD COLUMN IF NOT EXISTS voice_transcript TEXT;

CREATE INDEX IF NOT EXISTS idx_ai_metrics_voice_multimodal
    ON ai_metrics_logs (subsystem, operation, created_at DESC);


-- ============================================================================
-- 16. PENGUIN VOICE CONCIERGE E2E LATENCY, DECISION & ACTION TELEMETRY
-- ============================================================================

ALTER TABLE ai_metrics_logs
    ADD COLUMN IF NOT EXISTS stt_latency_ms DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS db_retrieval_ms DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS llm_latency_ms DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS tools_called TEXT,
    ADD COLUMN IF NOT EXISTS decision_made BOOLEAN DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS action_executed TEXT;

CREATE INDEX IF NOT EXISTS idx_ai_metrics_voice_concierge
    ON ai_metrics_logs (action_executed, decision_made, created_at DESC);



-- ============================================================================
-- 17. PRODUCT ACTIVE LIFECYCLE, SOFT-DELETE & SERVICE-ROLE RLS POLICIES
-- ============================================================================

ALTER TABLE products
    ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE;

UPDATE products
SET is_active = TRUE
WHERE is_active IS NULL;

-- Cleanly mark any previously soft-archived ghost rows as inactive
UPDATE products
SET is_active = FALSE
WHERE name LIKE '[Archived] %' OR stock < 0;

CREATE INDEX IF NOT EXISTS idx_products_is_active
    ON products (is_active)
    WHERE is_active = TRUE;

-- Public read policy strictly hides soft-deleted / inactive products
DROP POLICY IF EXISTS "Public read products" ON products;
CREATE POLICY "Public read products" ON products
    FOR SELECT USING (COALESCE(is_active, TRUE) = TRUE);

-- Explicit service_role full-access policies on products & 3D assets
DROP POLICY IF EXISTS "Service role full products" ON products;
CREATE POLICY "Service role full products" ON products
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full product_3d_assets" ON product_3d_assets;
CREATE POLICY "Service role full product_3d_assets" ON product_3d_assets
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

-- ============================================================================
-- 18. FINAL PRODUCTION HARDENING: CIA TRIAD RLS, ATOMIC STOCK RPC & INDEXES
-- ============================================================================

-- 18.1 Idempotent order fulfillment timestamp + unique Stripe session guard
ALTER TABLE orders ADD COLUMN IF NOT EXISTS fulfilled_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_stripe_session_unique
    ON orders (stripe_session_id)
    WHERE stripe_session_id IS NOT NULL AND stripe_session_id <> '';

-- 18.2 Atomic Stock Decrement RPC (prevents race-condition overselling)
CREATE OR REPLACE FUNCTION decrement_product_stock_atomic(
    p_product_id INTEGER,
    p_qty INTEGER
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_remaining INTEGER;
BEGIN
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    UPDATE products
    SET stock = stock - p_qty
    WHERE id = p_product_id
      AND COALESCE(is_active, TRUE) = TRUE
      AND COALESCE(stock, 0) >= p_qty
    RETURNING stock INTO v_remaining;

    IF NOT FOUND THEN
        RETURN -1;
    END IF;

    RETURN v_remaining;
END;
$$;

-- 18.3 Least-Privilege Row-Level Security (RLS) across all user & commerce tables
ALTER TABLE IF EXISTS users ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS products ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS product_3d_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS cart_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS wishlists ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS rfq_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS reviews ENABLE ROW LEVEL SECURITY;

-- Service-role administrative policies (FastAPI backend service key)
DROP POLICY IF EXISTS "Service role full users" ON users;
CREATE POLICY "Service role full users" ON users
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full cart_items" ON cart_items;
CREATE POLICY "Service role full cart_items" ON cart_items
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full wishlists" ON wishlists;
CREATE POLICY "Service role full wishlists" ON wishlists
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full orders" ON orders;
CREATE POLICY "Service role full orders" ON orders
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full order_items" ON order_items;
CREATE POLICY "Service role full order_items" ON order_items
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full rfq_requests" ON rfq_requests;
CREATE POLICY "Service role full rfq_requests" ON rfq_requests
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "Service role full reviews" ON reviews;
CREATE POLICY "Service role full reviews" ON reviews
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

-- Public read-only access strictly scoped to active catalog & reviews
DROP POLICY IF EXISTS "Public read active 3d assets" ON product_3d_assets;
CREATE POLICY "Public read active 3d assets" ON product_3d_assets
    FOR SELECT USING (COALESCE(is_active, TRUE) = TRUE);

DROP POLICY IF EXISTS "Public read reviews" ON reviews;
CREATE POLICY "Public read reviews" ON reviews
    FOR SELECT USING (TRUE);

-- Authenticated user least-privilege ownership policies (Anti-IDOR at DB layer)
DROP POLICY IF EXISTS "Users read own profile" ON users;
CREATE POLICY "Users read own profile" ON users
    FOR SELECT USING (LOWER(email) = LOWER(COALESCE(auth.jwt() ->> 'email', '')));

DROP POLICY IF EXISTS "Users read own orders" ON orders;
CREATE POLICY "Users read own orders" ON orders
    FOR SELECT USING (LOWER(customer_email) = LOWER(COALESCE(auth.jwt() ->> 'email', '')));

DROP POLICY IF EXISTS "Users read own rfq_requests" ON rfq_requests;
CREATE POLICY "Users read own rfq_requests" ON rfq_requests
    FOR SELECT USING (LOWER(customer_email) = LOWER(COALESCE(auth.jwt() ->> 'email', '')));

DROP POLICY IF EXISTS "Users manage own wishlists" ON wishlists;
CREATE POLICY "Users manage own wishlists" ON wishlists
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM users
            WHERE users.id = wishlists.user_id
              AND LOWER(users.email) = LOWER(COALESCE(auth.jwt() ->> 'email', ''))
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM users
            WHERE users.id = wishlists.user_id
              AND LOWER(users.email) = LOWER(COALESCE(auth.jwt() ->> 'email', ''))
        )
    );

DROP POLICY IF EXISTS "Users manage own favorites" ON favorites;
CREATE POLICY "Users manage own favorites" ON favorites
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM users
            WHERE users.id = favorites.user_id
              AND LOWER(users.email) = LOWER(COALESCE(auth.jwt() ->> 'email', ''))
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM users
            WHERE users.id = favorites.user_id
              AND LOWER(users.email) = LOWER(COALESCE(auth.jwt() ->> 'email', ''))
        )
    );

-- 18.4 Composite High-Throughput Indexes for Sub-Second Catalog, Order & RFQ Reads
CREATE INDEX IF NOT EXISTS idx_products_active_id_desc
    ON products (is_active, id DESC)
    WHERE COALESCE(is_active, TRUE) = TRUE;

CREATE INDEX IF NOT EXISTS idx_products_active_category
    ON products (is_active, category)
    WHERE COALESCE(is_active, TRUE) = TRUE;

CREATE INDEX IF NOT EXISTS idx_products_active_price
    ON products (is_active, price)
    WHERE COALESCE(is_active, TRUE) = TRUE;

CREATE INDEX IF NOT EXISTS idx_orders_customer_email_created
    ON orders (LOWER(customer_email), id DESC);

CREATE INDEX IF NOT EXISTS idx_rfq_customer_email_id_desc
    ON rfq_requests (LOWER(customer_email), id DESC);

DROP INDEX IF EXISTS idx_wishlists_user_email_product;
CREATE INDEX IF NOT EXISTS idx_wishlists_user_product
    ON wishlists (user_id, product_id);

CREATE INDEX IF NOT EXISTS idx_favorites_user_product
    ON favorites (user_id, product_id);


-- ============================================================================
-- 19. Model Context Protocol (MCP 2026-07-28 / 2025-11-25) Infrastructure
-- Scoped API Key Store + Auditable Telemetry Persistence
-- ============================================================================

-- 19.1 Scoped MCP API Keys (`mcp_api_keys`)
CREATE TABLE IF NOT EXISTS mcp_api_keys (
    id BIGSERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    user_email VARCHAR(254) NOT NULL,
    name VARCHAR(80) NOT NULL DEFAULT 'MCP key',
    key_prefix VARCHAR(32) NOT NULL,
    key_hash VARCHAR(128) NOT NULL UNIQUE,
    scopes JSONB NOT NULL DEFAULT '[]'::jsonb,
    expires_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,
    last_used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_mcp_api_keys_hash ON mcp_api_keys (key_hash);
CREATE INDEX IF NOT EXISTS idx_mcp_api_keys_user ON mcp_api_keys (user_id, revoked_at);
CREATE INDEX IF NOT EXISTS idx_mcp_api_keys_email ON mcp_api_keys (LOWER(user_email));

-- 19.2 High-Throughput MCP Audit Telemetry (`mcp_audit_logs`)
CREATE TABLE IF NOT EXISTS mcp_audit_logs (
    id BIGSERIAL PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    source VARCHAR(24) NOT NULL DEFAULT 'http',
    method VARCHAR(128) NOT NULL,
    tool_name VARCHAR(128),
    protocol_version VARCHAR(16),
    principal_type VARCHAR(16) NOT NULL DEFAULT 'anonymous',
    user_id INTEGER,
    key_id BIGINT,
    latency_ms DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    success BOOLEAN NOT NULL DEFAULT TRUE,
    error_code INTEGER,
    http_status INTEGER,
    client_name VARCHAR(80),
    metadata_json JSONB
);

CREATE INDEX IF NOT EXISTS idx_mcp_audit_logs_created ON mcp_audit_logs (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mcp_audit_logs_tool ON mcp_audit_logs (tool_name, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mcp_audit_logs_user ON mcp_audit_logs (user_id, created_at DESC);

-- 19.3 Row-Level Security for MCP Tables
ALTER TABLE mcp_api_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE mcp_audit_logs ENABLE ROW LEVEL SECURITY;

-- Service role full access
DROP POLICY IF EXISTS "Service role manages mcp_api_keys" ON mcp_api_keys;
CREATE POLICY "Service role manages mcp_api_keys" ON mcp_api_keys
    FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS "Service role manages mcp_audit_logs" ON mcp_audit_logs;
CREATE POLICY "Service role manages mcp_audit_logs" ON mcp_audit_logs
    FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

-- Authenticated users manage own MCP keys
DROP POLICY IF EXISTS "Users manage own mcp_api_keys" ON mcp_api_keys;
CREATE POLICY "Users manage own mcp_api_keys" ON mcp_api_keys
    FOR ALL USING (LOWER(user_email) = LOWER(COALESCE(auth.jwt() ->> 'email', '')))
    WITH CHECK (LOWER(user_email) = LOWER(COALESCE(auth.jwt() ->> 'email', '')));

-- Admin access for audit logs
DROP POLICY IF EXISTS "Admins read mcp_audit_logs" ON mcp_audit_logs;
CREATE POLICY "Admins read mcp_audit_logs" ON mcp_audit_logs
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM users
            WHERE LOWER(users.email) = LOWER(COALESCE(auth.jwt() ->> 'email', ''))
              AND users.role = 'admin'
        )
    );


-- ============================================================================
-- 20. PRE-LAUNCH HIGH-CONCURRENCY, IDEMPOTENCY & FLAGSHIP REVIEWS HARDENING
-- Built for 100+ simultaneous shoppers: zero overselling, atomic cart upserts,
-- order idempotency keys, helpful review votes, and zero-template review cache.
-- ============================================================================

-- 20.1 Atomic Checkout Stock Decrement & Rollback Compensation RPCs
CREATE OR REPLACE FUNCTION decrement_stock_atomic(
    p_product_id INTEGER,
    p_qty INTEGER
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_remaining INTEGER;
BEGIN
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    UPDATE products
    SET stock = stock - p_qty
    WHERE id = p_product_id
      AND COALESCE(is_active, TRUE) = TRUE
      AND COALESCE(stock, 0) >= p_qty
    RETURNING stock INTO v_remaining;

    IF NOT FOUND THEN
        RETURN -1;
    END IF;

    RETURN v_remaining;
END;
$$;

CREATE OR REPLACE FUNCTION increment_stock_atomic(
    p_product_id INTEGER,
    p_qty INTEGER
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_remaining INTEGER;
BEGIN
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RETURN -1;
    END IF;

    UPDATE products
    SET stock = COALESCE(stock, 0) + p_qty
    WHERE id = p_product_id
    RETURNING stock INTO v_remaining;

    IF NOT FOUND THEN
        RETURN -1;
    END IF;

    RETURN v_remaining;
END;
$$;

-- 20.2 Atomic Cart Upsert RPC (prevents race-condition duplicate rows & stock overflow)
CREATE OR REPLACE FUNCTION upsert_cart_item_atomic(
    p_user_id INTEGER,
    p_product_id INTEGER,
    p_qty INTEGER,
    p_variant VARCHAR(100) DEFAULT '',
    p_mode VARCHAR(16) DEFAULT 'increment'
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_stock INTEGER;
    v_active BOOLEAN;
    v_existing INTEGER;
    v_target INTEGER;
    v_clean_variant VARCHAR(100);
BEGIN
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    SELECT COALESCE(stock, 50), COALESCE(is_active, TRUE)
    INTO v_stock, v_active
    FROM products
    WHERE id = p_product_id;

    IF NOT FOUND OR NOT v_active THEN
        RETURN -2; -- Product not found or inactive
    END IF;

    v_clean_variant := COALESCE(TRIM(p_variant), '');

    SELECT quantity INTO v_existing
    FROM cart_items
    WHERE user_id = p_user_id
      AND product_id = p_product_id
      AND selected_variant = v_clean_variant
    FOR UPDATE;

    IF p_mode = 'set' THEN
        v_target := LEAST(100, p_qty);
    ELSE
        v_target := LEAST(100, COALESCE(v_existing, 0) + p_qty);
    END IF;

    IF v_target > v_stock THEN
        RETURN -1; -- Insufficient stock
    END IF;

    INSERT INTO cart_items (user_id, product_id, quantity, selected_variant, updated_at)
    VALUES (p_user_id, p_product_id, v_target, v_clean_variant, NOW())
    ON CONFLICT (user_id, product_id, selected_variant)
    DO UPDATE SET
        quantity = EXCLUDED.quantity,
        updated_at = NOW()
    RETURNING quantity INTO v_target;

    RETURN v_target;
END;
$$;

-- 20.3 Order Idempotency Guard (prevents duplicate orders on double-tap or network retry)
ALTER TABLE orders
    ADD COLUMN IF NOT EXISTS idempotency_key VARCHAR(128);

CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_idempotency_key_unique
    ON orders (idempotency_key)
    WHERE idempotency_key IS NOT NULL AND idempotency_key <> '';

-- 20.4 Flagship Customer Reviews: Fit/Quality Tags & Persistent Helpful Votes
ALTER TABLE reviews
    ADD COLUMN IF NOT EXISTS helpful_count INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS tags_json TEXT NOT NULL DEFAULT '[]';

CREATE TABLE IF NOT EXISTS review_helpful_votes (
    id BIGSERIAL PRIMARY KEY,
    review_id INTEGER NOT NULL REFERENCES reviews(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_review_helpful_user UNIQUE (review_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_review_helpful_votes_review
    ON review_helpful_votes (review_id);
CREATE INDEX IF NOT EXISTS idx_review_helpful_votes_user
    ON review_helpful_votes (user_id);

CREATE OR REPLACE FUNCTION sync_review_helpful_count()
RETURNS TRIGGER AS $$
DECLARE
    target_review_id INTEGER;
BEGIN
    target_review_id := COALESCE(NEW.review_id, OLD.review_id);
    UPDATE reviews
    SET helpful_count = (
        SELECT COUNT(*)::integer
        FROM review_helpful_votes
        WHERE review_id = target_review_id
    )
    WHERE id = target_review_id;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_review_helpful_count ON review_helpful_votes;
CREATE TRIGGER trg_sync_review_helpful_count
AFTER INSERT OR DELETE ON review_helpful_votes
FOR EACH ROW EXECUTE FUNCTION sync_review_helpful_count();

ALTER TABLE review_helpful_votes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read review_helpful_votes" ON review_helpful_votes;
CREATE POLICY "Public read review_helpful_votes" ON review_helpful_votes
    FOR SELECT USING (TRUE);

DROP POLICY IF EXISTS "Service role full review_helpful_votes" ON review_helpful_votes;
CREATE POLICY "Service role full review_helpful_votes" ON review_helpful_votes
    FOR ALL USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

-- Purge any legacy fabricated zero-review insight rows so 0-review products stay 100% honest
DELETE FROM product_review_insights
WHERE review_count_at_generation = 0 OR total_reviews = 0;



