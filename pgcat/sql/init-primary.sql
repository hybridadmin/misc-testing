-- Primary PostgreSQL initialization script
-- Creates the benchmark database, user, and replication setup

-- Create benchmark user
CREATE USER bench_user WITH PASSWORD 'bench_password' LOGIN;

-- Create benchmark database
CREATE DATABASE benchdb OWNER bench_user;

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE benchdb TO bench_user;

-- Create replication user for streaming replication
CREATE USER replicator WITH REPLICATION LOGIN PASSWORD 'replicator_password';

-- Connect to benchdb and set up schema
\c benchdb

-- Grant schema privileges
GRANT ALL ON SCHEMA public TO bench_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO bench_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO bench_user;

-- Create a sample application table for custom benchmark tests
CREATE TABLE IF NOT EXISTS app_metrics (
    id BIGSERIAL PRIMARY KEY,
    metric_name VARCHAR(100) NOT NULL,
    metric_value DOUBLE PRECISION NOT NULL,
    tags JSONB DEFAULT '{}',
    recorded_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_app_metrics_name ON app_metrics (metric_name);
CREATE INDEX idx_app_metrics_recorded_at ON app_metrics (recorded_at);
CREATE INDEX idx_app_metrics_tags ON app_metrics USING GIN (tags);

-- Insert some seed data
INSERT INTO app_metrics (metric_name, metric_value, tags)
SELECT
    'cpu_usage',
    random() * 100,
    jsonb_build_object('host', 'server-' || (i % 10)::text, 'region', CASE WHEN i % 3 = 0 THEN 'us-east' WHEN i % 3 = 1 THEN 'us-west' ELSE 'eu-west' END)
FROM generate_series(1, 10000) AS i;

INSERT INTO app_metrics (metric_name, metric_value, tags)
SELECT
    'memory_usage',
    random() * 32768,
    jsonb_build_object('host', 'server-' || (i % 10)::text, 'region', CASE WHEN i % 3 = 0 THEN 'us-east' WHEN i % 3 = 1 THEN 'us-west' ELSE 'eu-west' END)
FROM generate_series(1, 10000) AS i;
