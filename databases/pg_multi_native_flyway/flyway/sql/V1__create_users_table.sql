-- =============================================================================
-- V1__create_users_table.sql
-- Initial schema: users table with UUID primary keys
-- =============================================================================
-- In a multi-master setup, ALWAYS use UUID primary keys to prevent
-- insert conflicts between nodes (each node generates unique UUIDs).
-- =============================================================================

CREATE TABLE IF NOT EXISTS users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username text NOT NULL UNIQUE,
    email text,
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Index for common lookups
CREATE INDEX IF NOT EXISTS idx_users_username ON users (username);
CREATE INDEX IF NOT EXISTS idx_users_email ON users (email) WHERE email IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_active ON users (active) WHERE active = true;

COMMENT ON TABLE users IS 'Application users - managed by Flyway migrations';
