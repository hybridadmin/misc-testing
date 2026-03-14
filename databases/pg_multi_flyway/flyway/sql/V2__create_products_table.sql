-- =============================================================================
-- V2__create_products_table.sql
-- Products table demonstrating multi-table schema management
-- =============================================================================

CREATE TABLE IF NOT EXISTS products (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    description text,
    price numeric(12,2) NOT NULL CHECK (price >= 0),
    sku text UNIQUE,
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_products_name ON products (name);
CREATE INDEX IF NOT EXISTS idx_products_sku ON products (sku) WHERE sku IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_products_active ON products (active) WHERE active = true;

COMMENT ON TABLE products IS 'Product catalog - managed by Flyway migrations';
