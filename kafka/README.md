# Nginx → Kafka 4.2 → ClickHouse Structured Logging Stack

A production-oriented Docker Compose stack that runs **Nginx + Filebeat** in a
single combined container with JSON-formatted access logs, shipped into
**Apache Kafka 4.2** (KRaft mode, no ZooKeeper), and consumed by **ClickHouse**
into an optimised MergeTree table for real-time log analytics. An optional
**Kafka UI** is included for visual inspection of topics and messages.

---

## Architecture

```
┌─────────────────────────┐  Kafka protocol  ┌──────────────┐  Kafka engine  ┌──────────────┐
│   Nginx + Filebeat      │─────────────────▸│  Kafka 4.2   │◂──────────────│  ClickHouse  │
│      (port 8080)        │                   │ (KRaft mode) │               │ (port 8123)  │
│  nginx → log files      │                   └──────┬───────┘               └──────────────┘
│  filebeat → kafka       │                          │
└─────────────────────────┘                   ┌──────▼───────┐
                                              │   Kafka UI   │
                                              │  (port 9080) │
                                              └──────────────┘
```

### Data Pipeline

```
Nginx JSON access log
  → Filebeat (filestream + ndjson parser)
    → Kafka topic: nginx-logs (6 partitions, LZ4)
      → ClickHouse kafka_log (Kafka engine table)
        → log_mv (materialized view, transforms ssl_session_reused)
          → log (MergeTree, partitioned by month)
```

| Service       | Image                                  | Port(s)               | Purpose                                           |
|---------------|----------------------------------------|-----------------------|---------------------------------------------------|
| `kafka`       | `apache/kafka:4.2.0`                   | 9092, 9093, 9094      | Message broker (KRaft, no ZooKeeper)              |
| `kafka-init`  | `apache/kafka:4.2.0`                   | —                     | One-shot: creates the `nginx-logs` topic          |
| `nginx`       | `nginx-filebeat:latest` (custom build) | 8080                  | Nginx 1.29 + Filebeat 8.17 combined              |
| `clickhouse`  | `clickhouse/clickhouse-server:latest`  | 8123, 9000            | OLAP database consuming from Kafka                |
| `kafka-ui`    | `provectuslabs/kafka-ui:latest`        | 9080                  | Optional web UI for topic inspection              |

---

## Prerequisites

| Tool           | Minimum version |
|----------------|-----------------|
| Docker Engine  | 24.0+           |
| Docker Compose | v2 (plugin)     |

> **Note:** Ensure you have at least **4 GB of free RAM** for Kafka + ClickHouse.

---

## Quick Start

```bash
# 1. Clone / enter the project directory
cd nginx-kafka-logging

# 2. Start everything (builds the combined nginx-filebeat image)
docker compose up -d --build

# 3. Verify all services are healthy
docker compose ps

# 4. Generate some Nginx traffic
curl http://localhost:8080/
curl http://localhost:8080/nonexistent
for i in $(seq 1 50); do curl -s http://localhost:8080/ > /dev/null; done

# 5. Consume messages from the nginx-logs topic
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic nginx-logs \
  --from-beginning

# 6. Query logs in ClickHouse
docker compose exec clickhouse clickhouse-client \
  --query "SELECT timestamp, remote_addr, request_method, request_uri, status FROM nginx_logs.log ORDER BY timestamp DESC LIMIT 10"

# 7. Open Kafka UI (optional)
open http://localhost:9080
```

---

## Project Structure

```
.
├── docker-compose.yml          # Full stack definition
├── Dockerfile                  # Combined Nginx + Filebeat image
├── .env                        # Tunable environment variables
├── nginx/
│   ├── nginx.conf              # Main Nginx config (JSON log_format, 32 fields)
│   ├── default.conf            # Server block (health check, status)
│   └── entrypoint.sh           # Bash entrypoint running both processes
├── filebeat/
│   └── filebeat.yml            # Filebeat → Kafka pipeline (envelope stripped)
├── sql/
│   └── clickhouse.sql          # ClickHouse schema (kafka_log → log_mv → log)
└── README.md                   # This file
```

---

## Configuration Details

### Nginx JSON Log Format

The access log uses a structured JSON format (`log_format json_combined`) that
emits all **32 fields** matching the ClickHouse schema exactly:

```json
{
  "timestamp": 1750012345.678,
  "remote_addr": "172.20.0.1",
  "host": "localhost",
  "server_name": "_",
  "server_addr": "172.20.0.5",
  "protocol": "HTTP/1.1",
  "request_method": "GET",
  "request_uri": "/",
  "request_length": 78,
  "status": "200",
  "bytes_sent": 850,
  "body_bytes_sent": 612,
  "http_referer": "",
  "http_user_agent": "curl/8.5.0",
  "http_authorization": "",
  "request_time": 0.001,
  "compression_used": "",
  "upstream_response_time": 0,
  "upstream_addr": "",
  "upstream_status": "",
  "ssl_protocol": "",
  "ssl_cipher": "",
  "ssl_session_reused": ".",
  "ssl_server_name": "",
  "connection": 1,
  "connection_requests": 1,
  "connection_time": 0,
  "quic_sent": 0,
  "quic_received": 0,
  "tcpinfo_bytes_sent": 1234,
  "tcpinfo_bytes_received": 567,
  "tcpinfo_segs_out": 5,
  "tcpinfo_segs_in": 3,
  "tcpinfo_data_segs_out": 4,
  "tcpinfo_data_segs_in": 2
}
```

Key implementation details:
- **`timestamp`** uses `$msec` (Unix epoch with milliseconds as Float64) instead of ISO 8601 to match the ClickHouse `Float64` column type
- **`status`** is emitted as a quoted string to match the ClickHouse `String` type
- **`upstream_response_time`** uses a `map` directive to convert empty/`-` values to `0`
- **`compression_used`** maps to `$gzip_ratio` (empty when gzip is not applied)
- **`quic_sent`/`quic_received`** are hardcoded to `0` (QUIC/HTTP3 is not configured)
- **`tcpinfo_*`** fields require TCP_INFO support in the kernel (available in Linux)

### ClickHouse Schema

The schema (`sql/clickhouse.sql`) implements a 3-layer pipeline:

| Layer | Table/View | Engine | Purpose |
|-------|------------|--------|---------|
| 1 | `kafka_log` | Kafka | Reads raw JSON from the `nginx-logs` topic |
| 2 | `log_mv` | Materialized View | Transforms `ssl_session_reused` from string (`'r'`/`'.'`) to `UInt8` (1/0) |
| 3 | `log` | MergeTree | Final storage, partitioned by month, ordered for analytical queries |

The MergeTree table is partitioned by `toYYYYMM(timestamp)` and ordered by
`(server_addr, server_name, host, protocol, toDate(timestamp), request_method, request_uri)`
for efficient filtering on common query patterns.

**Example queries:**

```sql
-- Top 10 most requested URIs in the last hour
SELECT request_uri, count() AS hits
FROM nginx_logs.log
WHERE timestamp > now() - INTERVAL 1 HOUR
GROUP BY request_uri
ORDER BY hits DESC
LIMIT 10;

-- Error rate by status code
SELECT status, count() AS cnt,
       round(cnt * 100.0 / sum(cnt) OVER (), 2) AS pct
FROM nginx_logs.log
WHERE timestamp > now() - INTERVAL 24 HOUR
GROUP BY status
ORDER BY cnt DESC;

-- Slow requests (> 1 second)
SELECT timestamp, remote_addr, request_method, request_uri, request_time, status
FROM nginx_logs.log
WHERE request_time > 1.0
ORDER BY request_time DESC
LIMIT 20;

-- Traffic by hour
SELECT toStartOfHour(timestamp) AS hour,
       count() AS requests,
       sum(bytes_sent) AS total_bytes
FROM nginx_logs.log
GROUP BY hour
ORDER BY hour DESC;
```

### Kafka 4.2 (KRaft) Configuration

Kafka runs in **KRaft mode** — the consensus protocol that replaces
ZooKeeper (removed entirely as of Kafka 4.0). Key production settings applied:

| Setting                                | Value       | Rationale                                               |
|----------------------------------------|-------------|---------------------------------------------------------|
| `KAFKA_PROCESS_ROLES`                  | broker,controller | Combined mode (single-node); split in multi-broker |
| `KAFKA_NUM_PARTITIONS`                 | 6           | Default parallelism for auto-created topics             |
| `KAFKA_LOG_RETENTION_HOURS`            | 168         | 7-day retention                                         |
| `KAFKA_LOG_RETENTION_BYTES`            | 1 GiB       | Per-partition cap prevents unbounded growth              |
| `KAFKA_LOG_SEGMENT_BYTES`              | 512 MiB     | Balanced segment size for log rolling                   |
| `KAFKA_LOG_CLEANUP_POLICY`             | delete      | Time/size based deletion (not compaction)               |
| `KAFKA_COMPRESSION_TYPE`               | producer    | Respects producer-side compression (LZ4 from Filebeat)  |
| `KAFKA_MESSAGE_MAX_BYTES`              | 1 MiB       | Prevents oversized messages                             |
| `KAFKA_MIN_INSYNC_REPLICAS`            | 1           | Single-node; raise to 2 with 3+ brokers                 |
| `KAFKA_NUM_NETWORK_THREADS`            | 3           | Network I/O threads                                     |
| `KAFKA_NUM_IO_THREADS`                 | 8           | Disk I/O threads                                        |
| `KAFKA_GROUP_INITIAL_REBALANCE_DELAY`  | 3s          | Faster consumer group stabilisation                     |

#### Nginx-logs Topic Settings

Created explicitly by the `kafka-init` container:

| Property           | Value    |
|--------------------|----------|
| `partitions`       | 6        |
| `replication-factor` | 1      |
| `retention.ms`     | 7 days   |
| `retention.bytes`  | 1 GiB    |
| `compression.type` | lz4      |
| `max.message.bytes`| 1 MiB    |
| `segment.bytes`    | 512 MiB  |

### Combined Nginx + Filebeat Container

Nginx and Filebeat run in a single container managed by a bash entrypoint script
(`nginx/entrypoint.sh`). The entrypoint:

1. Replaces the default Nginx log symlinks (`/dev/stdout`) with real files
2. Starts Filebeat in the background
3. Starts Nginx in the foreground
4. Monitors both processes — if either exits, the other is terminated and the
   container stops (triggering Docker's restart policy)

The custom image is built from `nginx:1.29-trixie` with Filebeat 8.17 installed
as a standalone binary (no full Elastic stack required).

### Filebeat Pipeline

- **Input:** Uses `filestream` input to read `/var/log/nginx/access.log` (JSON, parsed with `ndjson` parser) and `error.log` (plain text with multiline support).
- **Processors:** Strips all Filebeat envelope fields (`@timestamp`, `agent`, `ecs`, `input`, `log`, `event`) so only flat Nginx JSON keys reach Kafka. This is critical for ClickHouse's `JSONEachRow` format which expects column names as top-level JSON keys.
- **Output:** Publishes to the `nginx-logs` Kafka topic with LZ4 compression, round-robin partitioning, and leader-ack durability (`required_acks: 1`).

---

## Operational Runbook

### Start the stack

```bash
docker compose up -d --build
```

### Stop the stack (preserves data)

```bash
docker compose down
```

### Stop and destroy all data

```bash
docker compose down -v
```

### View Kafka topic details

```bash
docker compose exec kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --describe --topic nginx-logs
```

### Consume messages in real time

```bash
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic nginx-logs \
  --from-beginning
```

### Consume from host machine (external listener)

```bash
kafka-console-consumer.sh \
  --bootstrap-server localhost:9093 \
  --topic nginx-logs \
  --from-beginning
```

### List all topics

```bash
docker compose exec kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list
```

### Check consumer group lag

```bash
docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --all-groups --describe
```

### Query ClickHouse

```bash
# Interactive client
docker compose exec clickhouse clickhouse-client -d nginx_logs

# One-shot query
docker compose exec clickhouse clickhouse-client \
  --query "SELECT count() FROM nginx_logs.log"

# Check Kafka consumer status
docker compose exec clickhouse clickhouse-client \
  --query "SELECT * FROM system.kafka_consumers FORMAT Vertical"
```

### View Filebeat logs (inside the nginx container)

```bash
docker compose logs -f nginx
```

### Produce a test message manually

```bash
echo '{"test":"hello"}' | docker compose exec -T kafka \
  /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic nginx-logs
```

### Generate load for testing

```bash
# Using curl in a loop
for i in $(seq 1 100); do curl -s http://localhost:8080/ > /dev/null; done

# Or with Apache Bench (if installed)
ab -n 1000 -c 10 http://localhost:8080/
```

---

## Scaling to Production (Multi-Broker)

This stack runs a single combined broker+controller for simplicity. To scale for
production workloads:

1. **Separate roles:** Run 3 dedicated controller nodes and N broker nodes.
2. **Update replication factors:**
   ```
   KAFKA_DEFAULT_REPLICATION_FACTOR=3
   KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=3
   KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=3
   KAFKA_MIN_INSYNC_REPLICAS=2
   KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=2
   ```
3. **Update `KAFKA_CONTROLLER_QUORUM_VOTERS`** to list all controller nodes:
   ```
   KAFKA_CONTROLLER_QUORUM_VOTERS=1@controller-1:9094,2@controller-2:9094,3@controller-3:9094
   ```
4. **Enable TLS/SASL** on all listeners for encryption and authentication.
5. **Use dedicated disks** for Kafka log dirs (mount separate volumes).
6. **Set `required_acks: -1`** in Filebeat for full ISR acknowledgement.
7. **Increase partition count** based on expected throughput.
8. **Enable JMX** and connect Prometheus/Grafana for monitoring.
9. **ClickHouse:** Increase `kafka_num_consumers` in the Kafka engine table to match partition count. Consider a ClickHouse cluster with `ReplicatedMergeTree` for HA.

---

## Network & Ports

| Port  | Protocol   | Listener   | Purpose                            |
|-------|------------|------------|------------------------------------|
| 8080  | HTTP       | —          | Nginx web server                   |
| 8123  | HTTP       | —          | ClickHouse HTTP interface          |
| 9000  | TCP        | —          | ClickHouse native client protocol  |
| 9092  | Kafka      | PLAINTEXT  | Internal broker communication      |
| 9093  | Kafka      | EXTERNAL   | Host-accessible client endpoint    |
| 9094  | Kafka      | CONTROLLER | KRaft controller quorum            |
| 9080  | HTTP       | —          | Kafka UI web console               |

---

## Security Considerations

This stack is configured for **development/staging** out of the box. For
production:

- [ ] Enable **TLS encryption** on all Kafka listeners
- [ ] Enable **SASL authentication** (SCRAM-SHA-512 recommended)
- [ ] Set **ACLs** to restrict topic access per client
- [ ] Place Nginx behind a **reverse proxy / load balancer** with TLS termination
- [ ] Restrict the Kafka UI with **authentication** or remove it entirely
- [ ] Set **ClickHouse users/passwords** and restrict network access
- [ ] Use Docker **secrets** or an external vault for credentials
- [ ] Set **resource limits** (`mem_limit`, `cpus`) on each container
- [ ] Enable **audit logging** on Kafka

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Kafka not starting | `docker compose logs kafka` — look for port conflicts or insufficient memory |
| No messages in topic | `docker compose logs nginx` — check Filebeat output in the combined container |
| Filebeat not starting | `docker exec nginx ps aux` — verify both nginx and filebeat processes are running |
| Topic not created | `docker compose logs kafka-init` — ensure Kafka was healthy before init ran |
| JSON parse errors in Filebeat | Check ndjson parser error key in consumed messages for details |
| High consumer lag | Increase partition count and add more consumers to the group |
| ClickHouse not ingesting | Check `SELECT * FROM system.kafka_consumers FORMAT Vertical` for errors |
| ClickHouse JSON parse error | Consume from Kafka directly and verify flat JSON keys match column names |
| ClickHouse `log` table empty | Verify the materialized view `log_mv` exists: `SHOW CREATE VIEW nginx_logs.log_mv` |
| IPv4 parse error in ClickHouse | Ensure `remote_addr`/`server_addr` contain valid IPv4 (not IPv6 `::1`) |

---

## Volumes

| Volume            | Mount point                  | Purpose                          |
|-------------------|------------------------------|----------------------------------|
| `kafka-data`      | `/var/lib/kafka/data`        | Kafka commit log (persistent)    |
| `filebeat-data`   | `/var/lib/filebeat`          | Filebeat registry (cursor state) |
| `clickhouse-data` | `/var/lib/clickhouse`        | ClickHouse data files            |
| `clickhouse-logs` | `/var/log/clickhouse-server` | ClickHouse server logs           |

---

## License

This configuration is provided as-is for educational and operational use.
Adapt security, replication, and resource settings to your environment before
deploying to production.
