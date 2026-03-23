# pg_stat_ch Docker Compose Demo

A self-contained Docker Compose stack demonstrating [pg_stat_ch](https://github.com/ClickHouse/pg_stat_ch) — the PostgreSQL extension that exports **raw per-query execution telemetry** to ClickHouse in real-time.

## What is pg_stat_ch?

Unlike `pg_stat_statements` which stores aggregated statistics inside PostgreSQL, `pg_stat_ch` exports **every query execution as a raw event** to ClickHouse. This gives you:

- **Per-execution detail** — p50/p95/p99 percentiles, time-series trends, individual outliers
- **Zero network I/O on the query path** — events queue in shared memory (~5us overhead)
- **Full telemetry** — timing, row counts, buffer/IO/WAL/CPU/JIT/parallel worker stats
- **Error capture** — SQLSTATE codes and messages for every failed query
- **ClickHouse-powered analytics** — materialized views for dashboards, drill-downs, alerting

## Architecture

```
PostgreSQL Hooks (foreground)
        │
        ▼
  Shared Memory Ring Buffer (MPSC, bounded)
        │
        ▼
  Background Worker (batched flush every 250ms)
        │
        ▼
  ClickHouse (events_raw table + 4 materialized views)
```

## Stack Components

| Service     | Image                               | Ports                          |
|-------------|-------------------------------------|--------------------------------|
| PostgreSQL  | Custom (postgres:18 + pg_stat_ch)   | `5432` (standard PG)          |
| ClickHouse  | clickhouse/clickhouse-server:latest | `9000` (native), `8123` (HTTP)|

## Quick Start

```bash
cd docker

# Build the custom PostgreSQL image and start both services
docker compose up -d --build

# Watch PostgreSQL logs (you'll see pg_stat_ch background worker start)
docker compose logs -f postgres

# Wait ~10 seconds for init scripts to complete, then run the demo queries
./demo-queries.sh
```

## Connecting

### PostgreSQL

```bash
# Via docker
docker compose exec postgres psql -U postgres -d demo

# Or directly (if you have psql installed)
psql -h localhost -U postgres -d demo
# Password: postgres
```

```sql
-- Verify the extension is loaded
SELECT pg_stat_ch_version();

-- Check queue and exporter stats
SELECT * FROM pg_stat_ch_stats();

-- Force an immediate flush of queued events
SELECT pg_stat_ch_flush();
```

### ClickHouse

```bash
# Via docker
docker compose exec clickhouse clickhouse-client -d pg_stat_ch

# Via HTTP (curl)
curl 'http://localhost:8123/?database=pg_stat_ch' \
  --data-binary 'SELECT count() FROM events_raw FORMAT Pretty'
```

## What the Demo Seeds

The PostgreSQL init script (`init/postgres/01-seed.sql`) automatically:

1. Enables the `pg_stat_ch` extension
2. Creates a small e-commerce schema (customers, products, orders)
3. Seeds 200 customers, 50 products, and 5,000+ orders
4. Runs a variety of queries to generate telemetry:
   - Point lookups (SELECT by id)
   - Aggregations (GROUP BY, ORDER BY)
   - Joins with filters
   - Time-series aggregations
   - CTEs / subqueries
   - Write operations (INSERT, UPDATE, DELETE)
   - Intentional errors (undefined table, unique violation)
   - work_mem pressure (forced temp file spills)

All of these are captured by `pg_stat_ch` and exported to ClickHouse.

## Demo Queries (ClickHouse)

Run the included script to see 10 pre-built analytical queries:

```bash
./demo-queries.sh
```

Or run them interactively:

### Total events captured
```sql
SELECT count() AS total_events, uniq(query_id) AS unique_queries
FROM pg_stat_ch.events_raw;
```

### Top slowest queries by p99 latency
```sql
SELECT
    query_id,
    cmd_type,
    count()                                AS calls,
    round(quantile(0.95)(duration_us)/1000, 2) AS p95_ms,
    round(quantile(0.99)(duration_us)/1000, 2) AS p99_ms,
    substring(any(query), 1, 80)           AS sample_query
FROM pg_stat_ch.events_raw
GROUP BY query_id, cmd_type
ORDER BY p99_ms DESC
LIMIT 10;
```

### Cache hit ratio per query
```sql
SELECT
    query_id,
    sum(shared_blks_hit) AS hits,
    sum(shared_blks_read) AS reads,
    round(100.0 * sum(shared_blks_hit) /
          nullIf(sum(shared_blks_hit) + sum(shared_blks_read), 0), 2) AS hit_pct,
    substring(any(query), 1, 80) AS sample
FROM pg_stat_ch.events_raw
WHERE shared_blks_hit + shared_blks_read > 0
GROUP BY query_id
ORDER BY hit_pct ASC
LIMIT 10;
```

### Queries with temp file spills (work_mem pressure)
```sql
SELECT query_id, sum(temp_blks_written) AS temp_written,
       round(avg(duration_us)/1000, 2) AS avg_ms,
       substring(any(query), 1, 80) AS sample
FROM pg_stat_ch.events_raw
WHERE temp_blks_written > 0
GROUP BY query_id
ORDER BY temp_written DESC;
```

### WAL generation by command type
```sql
SELECT cmd_type, count() AS calls,
       sum(wal_records) AS wal_records,
       formatReadableSize(sum(wal_bytes)) AS wal_size
FROM pg_stat_ch.events_raw
WHERE wal_bytes > 0
GROUP BY cmd_type
ORDER BY sum(wal_bytes) DESC;
```

### Errors captured
```sql
SELECT err_sqlstate, count() AS occurrences,
       any(err_message) AS sample_message
FROM pg_stat_ch.events_raw
WHERE err_elevel > 0
GROUP BY err_sqlstate
ORDER BY occurrences DESC;
```

### QPS over time
```sql
SELECT toStartOfMinute(ts_start) AS minute,
       count() AS queries,
       round(count()/60, 2) AS qps
FROM pg_stat_ch.events_raw
GROUP BY minute
ORDER BY minute;
```

## Using the Pre-Aggregated Materialized Views

The ClickHouse schema includes 4 materialized views that automatically aggregate incoming events:

| View                  | Granularity | Purpose                                     |
|-----------------------|-------------|---------------------------------------------|
| `events_recent_1h`   | Raw (1h TTL)| Real-time debugging, "what just happened?"  |
| `query_stats_5m`     | 5 minutes   | QPS trends, latency percentiles, dashboards |
| `db_app_user_1m`     | 1 minute    | Load by app/user, error rates               |
| `errors_recent`      | Raw (7d TTL)| Error investigation and alerting            |

Example using the `query_stats_5m` aggregated view:

```sql
SELECT
    query_id,
    countMerge(calls_state) AS calls,
    round(sumMerge(duration_sum_state) / countMerge(calls_state) / 1000, 2) AS avg_ms,
    round(quantilesTDigestMerge(0.95, 0.99)(duration_q_state)[1] / 1000, 2) AS p95_ms,
    round(quantilesTDigestMerge(0.95, 0.99)(duration_q_state)[2] / 1000, 2) AS p99_ms
FROM pg_stat_ch.query_stats_5m
WHERE bucket >= now() - INTERVAL 1 HOUR
GROUP BY query_id
ORDER BY p99_ms DESC
LIMIT 10;
```

## Generate More Traffic

To generate additional telemetry, run ad-hoc queries against PostgreSQL:

```bash
# Run some queries in a loop
docker compose exec postgres bash -c '
for i in $(seq 1 100); do
  psql -U postgres -d demo -c "SELECT * FROM orders WHERE customer_id = $((RANDOM % 200 + 1));" > /dev/null
  psql -U postgres -d demo -c "SELECT category, count(*) FROM products GROUP BY category;" > /dev/null
done
'

# Then flush and check ClickHouse
docker compose exec postgres psql -U postgres -d demo -c "SELECT pg_stat_ch_flush();"
sleep 2
./demo-queries.sh
```

## Configuration Reference

All `pg_stat_ch` GUC parameters are set in `docker-compose.yml` via the postgres `command:` section:

| Parameter                         | Value       | Description                              |
|-----------------------------------|-------------|------------------------------------------|
| `pg_stat_ch.enabled`              | `on`        | Enable telemetry collection              |
| `pg_stat_ch.clickhouse_host`      | `clickhouse`| ClickHouse hostname (docker service)     |
| `pg_stat_ch.clickhouse_port`      | `9000`      | ClickHouse native protocol port          |
| `pg_stat_ch.clickhouse_database`  | `pg_stat_ch`| Target database in ClickHouse            |
| `pg_stat_ch.flush_interval_ms`    | `250`       | Batch flush interval (ms)                |
| `pg_stat_ch.batch_max`            | `1000`      | Max events per ClickHouse insert         |
| `track_io_timing`                 | `on`        | Enable I/O timing columns                |
| `compute_query_id`                | `on`        | Enable query_id computation              |

## Tear Down

```bash
docker compose down -v   # removes containers AND volumes
```

## File Structure

```
pg_stat_ch/
├── docker/
│   ├── docker-compose.yml          # Stack definition
│   ├── Dockerfile.postgres         # Multi-stage build: PG18 + pg_stat_ch
│   ├── demo-queries.sh             # 10 analytical queries against ClickHouse
│   └── init/
│       ├── clickhouse/
│       │   └── 00-schema.sql       # ClickHouse tables + materialized views
│       └── postgres/
│           └── 01-seed.sql         # Extension setup + demo data + sample queries
└── postgres_operator.md            # Notes on using pg_stat_ch with Crunchy PGO
```
