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
