-- ============================================================================
-- ClickHouse schema for pg_stat_ch events
-- ============================================================================
-- Source: https://github.com/ClickHouse/pg_stat_ch/blob/main/docker/init/00-schema.sql
--
-- This file is applied automatically by ClickHouse on first boot via the
-- docker-entrypoint-initdb.d mechanism.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS pg_stat_ch;

DROP TABLE IF EXISTS pg_stat_ch.events_raw;

-- ============================================================================
-- events_raw: One row per query execution exported from PostgreSQL
-- ============================================================================
CREATE TABLE pg_stat_ch.events_raw
(
    -- Core identity and timing
    ts_start                DateTime64(6, 'UTC'),
    duration_us             UInt64,
    db                      LowCardinality(String),
    username                LowCardinality(String),
    pid                     Int32,
    query_id                Int64,
    cmd_type                LowCardinality(String),
    rows                    UInt64,
    query                   String,

    -- Shared buffer metrics
    shared_blks_hit         Int64,
    shared_blks_read        Int64,
    shared_blks_dirtied     Int64,
    shared_blks_written     Int64,

    -- Local buffer metrics (temp tables)
    local_blks_hit          Int64,
    local_blks_read         Int64,
    local_blks_dirtied      Int64,
    local_blks_written      Int64,

    -- Temp file metrics (work_mem spills)
    temp_blks_read          Int64,
    temp_blks_written       Int64,

    -- I/O timing (requires track_io_timing=on)
    shared_blk_read_time_us  Int64,
    shared_blk_write_time_us Int64,
    local_blk_read_time_us   Int64,
    local_blk_write_time_us  Int64,
    temp_blk_read_time_us    Int64,
    temp_blk_write_time_us   Int64,

    -- WAL metrics
    wal_records             Int64,
    wal_fpi                 Int64,
    wal_bytes               UInt64,

    -- CPU time
    cpu_user_time_us        Int64,
    cpu_sys_time_us         Int64,

    -- JIT compilation (PG15+)
    jit_functions           Int32,
    jit_generation_time_us  Int32,
    jit_deform_time_us      Int32,
    jit_inlining_time_us    Int32,
    jit_optimization_time_us Int32,
    jit_emission_time_us    Int32,

    -- Parallel workers (PG18+)
    parallel_workers_planned Int16,
    parallel_workers_launched Int16,

    -- Error information
    err_sqlstate            FixedString(5),
    err_elevel              UInt8,
    err_message             String,

    -- Client context
    app                     LowCardinality(String),
    client_addr             String
)
ENGINE = MergeTree
PARTITION BY toDate(ts_start)
ORDER BY ts_start;


-- ============================================================================
-- MV 1: events_recent_1h — fast access to recent events (1-hour TTL)
-- ============================================================================
DROP TABLE IF EXISTS pg_stat_ch.events_recent_1h;

CREATE MATERIALIZED VIEW pg_stat_ch.events_recent_1h
ENGINE = MergeTree
PARTITION BY toDate(ts_start)
ORDER BY ts_start
TTL toDateTime(ts_start) + INTERVAL 1 HOUR DELETE
AS
SELECT *
FROM pg_stat_ch.events_raw;


-- ============================================================================
-- MV 2: query_stats_5m — pre-aggregated query stats in 5-min buckets
-- ============================================================================
DROP TABLE IF EXISTS pg_stat_ch.query_stats_5m;

CREATE MATERIALIZED VIEW pg_stat_ch.query_stats_5m
(
    bucket              DateTime,
    db                  LowCardinality(String),
    query_id            Int64,
    cmd_type            LowCardinality(String),
    calls_state         AggregateFunction(count),
    duration_sum_state  AggregateFunction(sum, UInt64),
    duration_min_state  AggregateFunction(min, UInt64),
    duration_max_state  AggregateFunction(max, UInt64),
    duration_q_state    AggregateFunction(quantilesTDigest(0.95, 0.99), UInt64),
    rows_sum_state      AggregateFunction(sum, UInt64),
    shared_hit_sum_state  AggregateFunction(sum, Int64),
    shared_read_sum_state AggregateFunction(sum, Int64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMMDD(bucket)
ORDER BY (bucket, db, query_id, cmd_type)
AS
SELECT
    toStartOfInterval(toDateTime(ts_start), INTERVAL 5 MINUTE) AS bucket,
    db, query_id, cmd_type,
    countState()                                     AS calls_state,
    sumState(duration_us)                            AS duration_sum_state,
    minState(duration_us)                            AS duration_min_state,
    maxState(duration_us)                            AS duration_max_state,
    quantilesTDigestState(0.95, 0.99)(duration_us)   AS duration_q_state,
    sumState(rows)                                   AS rows_sum_state,
    sumState(shared_blks_hit)                        AS shared_hit_sum_state,
    sumState(shared_blks_read)                       AS shared_read_sum_state
FROM pg_stat_ch.events_raw
GROUP BY bucket, db, query_id, cmd_type;


-- ============================================================================
-- MV 3: db_app_user_1m — load by database/application/user (1-min buckets)
-- ============================================================================
DROP TABLE IF EXISTS pg_stat_ch.db_app_user_1m;

CREATE MATERIALIZED VIEW pg_stat_ch.db_app_user_1m
(
    bucket              DateTime,
    db                  LowCardinality(String),
    app                 LowCardinality(String),
    username            LowCardinality(String),
    cmd_type            LowCardinality(String),
    calls_state         AggregateFunction(count),
    duration_sum_state  AggregateFunction(sum, UInt64),
    duration_q_state    AggregateFunction(quantilesTDigest(0.95, 0.99), UInt64),
    errors_sum_state    AggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMMDD(bucket)
ORDER BY (bucket, db, app, username, cmd_type)
AS
SELECT
    toStartOfMinute(toDateTime(ts_start)) AS bucket,
    db, app, username, cmd_type,
    countState()                                     AS calls_state,
    sumState(duration_us)                            AS duration_sum_state,
    quantilesTDigestState(0.95, 0.99)(duration_us)   AS duration_q_state,
    sumState(toUInt64(err_elevel > 0))               AS errors_sum_state
FROM pg_stat_ch.events_raw
GROUP BY bucket, db, app, username, cmd_type;


-- ============================================================================
-- MV 4: errors_recent — errors with 7-day retention
-- ============================================================================
DROP TABLE IF EXISTS pg_stat_ch.errors_recent;

CREATE MATERIALIZED VIEW pg_stat_ch.errors_recent
ENGINE = MergeTree
PARTITION BY toDate(ts_start)
ORDER BY ts_start
TTL toDateTime(ts_start) + INTERVAL 7 DAY DELETE
AS
SELECT
    ts_start, db, username, app, client_addr, pid,
    query_id, err_sqlstate, err_elevel, err_message, query
FROM pg_stat_ch.events_raw
WHERE err_elevel > 0;
