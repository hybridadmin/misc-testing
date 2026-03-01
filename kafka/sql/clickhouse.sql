-------------------------------------------------------------------------------
-- ClickHouse schema for Nginx structured logs consumed from Kafka
--
-- Pipeline: kafka_log (Kafka engine) → log_mv (materialized view) → log (MergeTree)
--
-- The materialized view transforms ssl_session_reused from the Nginx string
-- value ('r' = reused, '.' = not reused) into a UInt8 boolean (1/0).
-------------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS nginx_logs;

USE nginx_logs;

-- Layer 1: Kafka engine table — reads raw JSON from the nginx-logs topic
CREATE TABLE IF NOT EXISTS kafka_log
(
    timestamp Float64,
    remote_addr String,
    host String,
    server_name String,
    server_addr String,
    protocol String,
    request_method String,
    request_uri String,
    request_length UInt32,
    status String,
    bytes_sent UInt32,
    body_bytes_sent UInt32,
    http_referer String,
    http_user_agent String,
    http_authorization String,
    request_time Float64,
    compression_used String,
    upstream_response_time Float64,
    upstream_addr String,
    upstream_status String,
    ssl_protocol String,
    ssl_cipher String,
    ssl_session_reused String,
    ssl_server_name String,
    connection UInt32,
    connection_requests UInt32,
    connection_time Float32,
    quic_sent UInt32,
    quic_received UInt32,
    tcpinfo_bytes_sent UInt32,
    tcpinfo_bytes_received UInt32,
    tcpinfo_segs_out UInt32,
    tcpinfo_segs_in UInt32,
    tcpinfo_data_segs_out UInt32,
    tcpinfo_data_segs_in UInt32
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka:9092',
    kafka_topic_list = 'nginx-logs',
    kafka_group_name = 'clickhouse',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1,
    kafka_max_block_size = 65536,
    kafka_skip_broken_messages = 10;

-- Layer 2: MergeTree storage table — optimised for analytical queries
CREATE TABLE IF NOT EXISTS log
(
    timestamp DateTime64(3),
    remote_addr IPv4,
    host LowCardinality(String),
    server_name LowCardinality(String),
    server_addr IPv4,
    ssl_server_name LowCardinality(String),
    protocol LowCardinality(String),
    request_method LowCardinality(String),
    request_uri String,
    request_length UInt32,
    status LowCardinality(String),
    bytes_sent UInt32,
    body_bytes_sent UInt32,
    http_referer String,
    http_user_agent String,
    http_authorization String,
    request_time Float32,
    compression_used LowCardinality(String),
    upstream_response_time Float32,
    upstream_addr String,
    upstream_status LowCardinality(String),
    ssl_protocol LowCardinality(String),
    ssl_cipher LowCardinality(String),
    ssl_session_reused UInt8,
    connection UInt32,
    connection_requests UInt32,
    connection_time Float32,
    quic_sent UInt32,
    quic_received UInt32,
    tcpinfo_bytes_sent UInt32,
    tcpinfo_bytes_received UInt32,
    tcpinfo_segs_out UInt32,
    tcpinfo_segs_in UInt32,
    tcpinfo_data_segs_out UInt32,
    tcpinfo_data_segs_in UInt32
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (server_addr, server_name, host, protocol, toDate(timestamp), request_method, request_uri);

-- Layer 3: Materialized view — transforms and routes kafka_log → log
-- Converts ssl_session_reused from string ('r'=reused) to UInt8 boolean
CREATE MATERIALIZED VIEW IF NOT EXISTS log_mv TO log AS
SELECT
    * EXCEPT(ssl_session_reused),
    ssl_session_reused = 'r' AS ssl_session_reused
FROM kafka_log;
