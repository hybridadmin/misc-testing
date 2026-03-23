#!/usr/bin/env bash
# =============================================================================
# demo-queries.sh — Run analytical queries against ClickHouse to explore
#                    the telemetry captured by pg_stat_ch.
#
# Usage:
#   ./demo-queries.sh                 # runs against local docker compose stack
#   ./demo-queries.sh <ch-host>       # runs against a remote ClickHouse
# =============================================================================
set -euo pipefail

CH_HOST="${1:-localhost}"
CH_PORT="${CH_PORT:-8123}"

run_query() {
    local title="$1"
    local sql="$2"
    echo ""
    echo "============================================================================"
    echo "  $title"
    echo "============================================================================"
    curl -sS "http://${CH_HOST}:${CH_PORT}/?database=pg_stat_ch" \
         --data-binary "$sql" \
         -H "Content-Type: text/plain"
    echo ""
}

# -------------------------------------------------------------------------
echo ""
echo "  pg_stat_ch  —  ClickHouse Telemetry Demo Queries"
echo "  ================================================="
echo ""
# -------------------------------------------------------------------------

run_query "1. Total events captured" \
"SELECT
    count()                    AS total_events,
    uniq(query_id)             AS unique_queries,
    min(ts_start)              AS first_event,
    max(ts_start)              AS last_event
FROM events_raw
FORMAT PrettyCompactMonoBlock"

run_query "2. Events by command type" \
"SELECT
    cmd_type,
    count()                    AS calls,
    round(avg(duration_us)/1000, 2) AS avg_ms,
    max(duration_us)/1000      AS max_ms,
    sum(rows)                  AS total_rows
FROM events_raw
GROUP BY cmd_type
ORDER BY calls DESC
FORMAT PrettyCompactMonoBlock"

run_query "3. Top 10 slowest queries (by p99 latency)" \
"SELECT
    query_id,
    cmd_type,
    count()                                AS calls,
    round(quantile(0.50)(duration_us)/1000, 2) AS p50_ms,
    round(quantile(0.95)(duration_us)/1000, 2) AS p95_ms,
    round(quantile(0.99)(duration_us)/1000, 2) AS p99_ms,
    substring(any(query), 1, 80)           AS sample_query
FROM events_raw
GROUP BY query_id, cmd_type
HAVING calls >= 1
ORDER BY p99_ms DESC
LIMIT 10
FORMAT PrettyCompactMonoBlock"

run_query "4. Cache hit ratio per query" \
"SELECT
    query_id,
    count()                                AS calls,
    sum(shared_blks_hit)                   AS total_hits,
    sum(shared_blks_read)                  AS total_reads,
    round(100.0 * sum(shared_blks_hit) /
          nullIf(sum(shared_blks_hit) + sum(shared_blks_read), 0), 2) AS hit_ratio_pct,
    substring(any(query), 1, 80)           AS sample_query
FROM events_raw
WHERE shared_blks_hit + shared_blks_read > 0
GROUP BY query_id
ORDER BY hit_ratio_pct ASC
LIMIT 10
FORMAT PrettyCompactMonoBlock"

run_query "5. Queries with temp file spills (work_mem pressure)" \
"SELECT
    query_id,
    count()                                AS calls,
    sum(temp_blks_written)                 AS total_temp_written,
    sum(temp_blks_read)                    AS total_temp_read,
    round(avg(duration_us)/1000, 2)        AS avg_ms,
    substring(any(query), 1, 80)           AS sample_query
FROM events_raw
WHERE temp_blks_written > 0
GROUP BY query_id
ORDER BY total_temp_written DESC
LIMIT 10
FORMAT PrettyCompactMonoBlock"

run_query "6. WAL generation by command type" \
"SELECT
    cmd_type,
    count()                    AS calls,
    sum(wal_records)           AS total_wal_records,
    sum(wal_fpi)               AS total_fpi,
    formatReadableSize(sum(wal_bytes)) AS total_wal_size
FROM events_raw
WHERE wal_bytes > 0
GROUP BY cmd_type
ORDER BY sum(wal_bytes) DESC
FORMAT PrettyCompactMonoBlock"

run_query "7. Errors captured" \
"SELECT
    err_sqlstate,
    err_elevel,
    count()                    AS occurrences,
    any(err_message)           AS sample_message,
    substring(any(query), 1, 80)   AS sample_query
FROM events_raw
WHERE err_elevel > 0
GROUP BY err_sqlstate, err_elevel
ORDER BY occurrences DESC
FORMAT PrettyCompactMonoBlock"

run_query "8. Load by database" \
"SELECT
    db,
    count()                                AS total_queries,
    round(sum(duration_us)/1000000, 2)     AS total_seconds,
    round(avg(duration_us)/1000, 2)        AS avg_ms,
    round(quantile(0.99)(duration_us)/1000, 2) AS p99_ms
FROM events_raw
GROUP BY db
ORDER BY total_seconds DESC
FORMAT PrettyCompactMonoBlock"

run_query "9. CPU time breakdown (top queries by user CPU)" \
"SELECT
    query_id,
    cmd_type,
    count()                                AS calls,
    round(sum(cpu_user_time_us)/1000, 2)   AS total_cpu_user_ms,
    round(sum(cpu_sys_time_us)/1000, 2)    AS total_cpu_sys_ms,
    round(avg(duration_us)/1000, 2)        AS avg_duration_ms,
    substring(any(query), 1, 80)           AS sample_query
FROM events_raw
WHERE cpu_user_time_us > 0
GROUP BY query_id, cmd_type
ORDER BY total_cpu_user_ms DESC
LIMIT 10
FORMAT PrettyCompactMonoBlock"

run_query "10. Queries per second (QPS) over time" \
"SELECT
    toStartOfMinute(ts_start) AS minute,
    count()                   AS queries,
    round(count() / 60, 2)   AS qps
FROM events_raw
GROUP BY minute
ORDER BY minute
FORMAT PrettyCompactMonoBlock"

echo ""
echo "Done. Connect directly for ad-hoc exploration:"
echo "  clickhouse-client --host ${CH_HOST} --port 9000 -d pg_stat_ch"
echo "  curl 'http://${CH_HOST}:${CH_PORT}/?database=pg_stat_ch' --data-binary 'SELECT * FROM events_raw LIMIT 5 FORMAT Vertical'"
echo ""
