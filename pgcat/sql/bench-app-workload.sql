-- Custom application-style workload
-- Simulates real-world queries against the app_metrics table

\set metric_id random(1, 20000)

-- Point lookup by ID
SELECT id, metric_name, metric_value, tags, recorded_at
FROM app_metrics WHERE id = :metric_id;

-- Aggregation query (typical dashboard query)
SELECT
    metric_name,
    count(*) AS sample_count,
    avg(metric_value) AS avg_value,
    min(metric_value) AS min_value,
    max(metric_value) AS max_value,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY metric_value) AS p95
FROM app_metrics
WHERE recorded_at > now() - interval '1 hour'
GROUP BY metric_name;

-- JSONB filter query
SELECT count(*), avg(metric_value)
FROM app_metrics
WHERE tags @> '{"region": "us-east"}'
  AND metric_name = 'cpu_usage';

-- Insert a new metric (write)
INSERT INTO app_metrics (metric_name, metric_value, tags)
VALUES (
    'request_latency',
    random() * 500,
    jsonb_build_object('host', 'server-' || (random() * 10)::int::text, 'endpoint', '/api/data')
);
