-- ============================================================
-- Base schema: runs on pg_node1, pg_node2, and pg_node3 via initdb
-- pglogical extension + application tables
-- ============================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS pglogical;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ─── Application tables ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS benchmark_table (
    id    SERIAL PRIMARY KEY,
    data  VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_benchmark_created_at ON benchmark_table(created_at);

CREATE TABLE IF NOT EXISTS users (
    id         SERIAL PRIMARY KEY,
    username   VARCHAR(100) UNIQUE NOT NULL,
    email      VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS posts (
    id         SERIAL PRIMARY KEY,
    user_id    INTEGER REFERENCES users(id) ON DELETE CASCADE,
    title      VARCHAR(500) NOT NULL,
    content    TEXT,
    published  BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_posts_user_id   ON posts(user_id);
CREATE INDEX IF NOT EXISTS idx_posts_published ON posts(published);

-- Tables have PRIMARY KEYs, so the default replica identity (PK-based)
-- is sufficient for pglogical to replicate UPDATEs and DELETEs.

-- NOTE: No seed data here. All nodes run this identical init script,
-- so any INSERT with a SERIAL PK would cause conflicts during
-- pglogical's initial data synchronization.
