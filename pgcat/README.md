# PgCat Connection Pooler - Benchmark & Testing Setup

A complete Docker-based environment for testing [PgCat](https://github.com/postgresml/pgcat), a PostgreSQL connection pooler and load balancer written in Rust. This setup includes a PostgreSQL primary/replica pair with streaming replication, PgCat configured for connection pooling and read/write splitting, and a comprehensive pgbench test suite.

## Architecture

```
                         ┌─────────────────────┐
                         │     Application      │
                         │   (pgbench client)   │
                         └──────────┬───────────┘
                                    │
                              port 6432
                                    │
                         ┌──────────▼───────────┐
                         │        PgCat          │
                         │  (connection pooler)  │
                         │                       │
                         │  - Transaction mode   │
                         │  - R/W splitting      │
                         │  - Load balancing     │
                         └───┬──────────────┬────┘
                             │              │
                     writes  │              │  reads
                             │              │
                  ┌──────────▼──┐    ┌──────▼──────────┐
                  │ PG Primary  │───▶│   PG Replica     │
                  │  port 5432  │    │   port 5433      │
                  │  (read/write│    │   (read-only)    │
                  │   + WAL)    │    │   hot standby    │
                  └─────────────┘    └─────────────────-┘
                        streaming replication
```

## Components

| Service | Container | Port | Description |
|---------|-----------|------|-------------|
| `pg-primary` | `pgcat-primary` | 5432 | PostgreSQL 16 primary (read/write) |
| `pg-replica` | `pgcat-replica` | 5433 | PostgreSQL 16 replica (streaming replication, hot standby) |
| `pgcat` | `pgcat-pooler` | 6432 | PgCat connection pooler and load balancer |
| `pgbench` | `pgcat-pgbench` | - | pgbench runner container (on-demand) |

## Prerequisites

- Docker and Docker Compose (v2)
- `psql` client (optional, for manual queries)
- ~1 GB free disk space

## Quick Start

```bash
# 1. Start the environment
./scripts/setup.sh

# 2. Verify everything is working
./scripts/quick-test.sh

# 3. Run benchmarks
./scripts/bench.sh

# 4. Check status
./scripts/status.sh

# 5. Tear down when done
./scripts/teardown.sh
```

## Directory Structure

```
pgcat/
├── docker-compose.yml              # Service definitions
├── README.md                       # This file
├── config/
│   ├── pgcat.toml                  # PgCat configuration
│   ├── primary-postgresql.conf     # PostgreSQL primary settings
│   └── pg_hba_primary.conf         # Client authentication rules
├── scripts/
│   ├── setup.sh                    # Start the environment
│   ├── teardown.sh                 # Stop and clean up
│   ├── bench.sh                    # Run benchmarks (host-side entry point)
│   ├── run-benchmarks.sh           # Benchmark suite (runs inside container)
│   ├── status.sh                   # Show environment status
│   ├── quick-test.sh               # Connectivity smoke test
│   └── results/                    # Benchmark output (auto-created)
└── sql/
    ├── init-primary.sql            # Database initialization
    ├── bench-read-heavy.sql        # Custom read-heavy workload
    ├── bench-write-heavy.sql       # Custom write-heavy workload
    └── bench-app-workload.sql      # Application-style mixed workload
```

## Configuration Details

### PgCat (`config/pgcat.toml`)

Key settings:

| Setting | Value | Description |
|---------|-------|-------------|
| `pool_mode` | `transaction` | Connections returned to pool after each transaction |
| `pool_size` | 30 | Max server connections per user |
| `min_pool_size` | 5 | Minimum idle connections maintained |
| `query_parser_enabled` | `true` | Enables SQL parsing for routing |
| `query_parser_read_write_splitting` | `true` | SELECTs go to replicas, writes to primary |
| `default_role` | `any` | Queries can be routed to any server by default |
| `healthcheck_delay` | 30000ms | Interval between server health checks |
| `ban_time` | 60s | How long to ban a misbehaving server |

### PostgreSQL Primary (`config/primary-postgresql.conf`)

Tuned for benchmarking:

| Setting | Value | Purpose |
|---------|-------|---------|
| `max_connections` | 200 | Headroom for pooled connections |
| `shared_buffers` | 256MB | In-memory page cache |
| `wal_level` | `replica` | Required for streaming replication |
| `max_wal_senders` | 5 | Concurrent replication connections |
| `wal_keep_size` | 256MB | WAL retention for replica catch-up |
| `work_mem` | 8MB | Per-operation sort/hash memory |

### Streaming Replication

The replica is configured automatically on first start:
1. `pg_basebackup` creates a full copy from the primary
2. `standby.signal` and `primary_conninfo` are set via the `-R` flag
3. The replica runs in `hot_standby` mode (accepts read queries)

## Benchmark Suite

### Running Benchmarks

```bash
# Default settings (scale=10, clients=10, duration=30s)
./scripts/bench.sh

# Quick smoke test
./scripts/bench.sh --quick

# Custom parameters
./scripts/bench.sh --scale 50 --clients 25 --duration 60

# All options
./scripts/bench.sh --help
```

### Benchmark Tests

The suite runs 8 tests, comparing direct PostgreSQL access vs PgCat:

| # | Test | Description |
|---|------|-------------|
| 1 | **pgbench init** | Initializes pgbench tables at the configured scale factor |
| 2 | **TPC-B read-write** | Standard pgbench TPC-B (UPDATE + SELECT + INSERT) - direct vs PgCat |
| 3 | **Select-only** | Read-only workload (`-S` flag) - direct vs PgCat |
| 4 | **Custom read-heavy** | Point lookups, range scans, aggregations through PgCat |
| 5 | **Custom write-heavy** | Multi-statement transactions with UPDATEs and INSERTs |
| 6 | **Mixed workload** | Combined read + write scripts (simulates real traffic) |
| 7 | **Connection scalability** | Tests 1, 5, 10, 25, 50 concurrent clients |
| 8 | **Latency distribution** | Per-statement latency breakdown with `-r` flag |

### Custom SQL Workloads

**`sql/bench-read-heavy.sql`** - Read-focused queries:
- Random point lookups on `pgbench_accounts`
- Range scans with aggregation
- Branch and teller lookups
- Recent history count

**`sql/bench-write-heavy.sql`** - Write-focused transactions:
- Account balance updates
- Teller and branch balance updates
- History inserts
- All wrapped in a single transaction

**`sql/bench-app-workload.sql`** - Application-style queries:
- Point lookups on `app_metrics`
- Dashboard-style aggregations with percentiles
- JSONB filter queries
- Metric inserts

### Interpreting Results

Key metrics to compare between direct and PgCat runs:

- **TPS (transactions per second)**: Higher is better. PgCat adds slight overhead but should be close to direct for transaction-mode pooling.
- **Latency (avg/stddev)**: Lower is better. Expect 0.1-0.5ms overhead from PgCat.
- **Connection scalability**: PgCat should maintain stable TPS as client count increases, since it multiplexes onto a fixed pool of server connections.

Example output interpretation:
```
tps = 5432.123456 (without initial connection establishing)
latency average = 1.841 ms
latency stddev = 0.923 ms
```

## Manual Operations

### Connect through PgCat

```bash
# As benchmark user
psql -h localhost -p 6432 -U bench_user benchdb

# As postgres superuser
psql -h localhost -p 6432 -U postgres benchdb
```

### Connect directly to PostgreSQL

```bash
# Primary
psql -h localhost -p 5432 -U bench_user benchdb

# Replica
psql -h localhost -p 5433 -U bench_user benchdb
```

### PgCat Admin Commands

```bash
# Connect to PgCat admin database
PGPASSWORD=pgcat_admin psql -h localhost -p 6432 -U pgcat pgcat

# Show pool statistics
SHOW POOLS;

# Show server status
SHOW SERVERS;

# Show connected clients
SHOW CLIENTS;

# Show PgCat version
SHOW VERSION;

# Show configuration
SHOW CONFIG;

# Show general stats
SHOW STATS;
```

### Check Replication Status

```bash
# On primary - check replication slots
psql -h localhost -p 5432 -U postgres -c \
  "SELECT pid, state, sent_lsn, write_lsn, replay_lsn, replay_lag
   FROM pg_stat_replication;"

# On replica - confirm standby mode
psql -h localhost -p 5433 -U postgres -c "SELECT pg_is_in_recovery();"
```

### Run a Single pgbench Test Manually

```bash
# Initialize pgbench tables (scale factor 10)
docker compose exec pgbench pgbench -i -s 10 \
  -h pgcat -p 6432 -U bench_user benchdb

# Run a 30-second read-write test with 10 clients
docker compose exec pgbench pgbench -c 10 -j 4 -T 30 -P 5 \
  -h pgcat -p 6432 -U bench_user benchdb

# Run select-only test
docker compose exec pgbench pgbench -c 10 -j 4 -T 30 -S -P 5 \
  -h pgcat -p 6432 -U bench_user benchdb

# Run custom workload
docker compose exec pgbench pgbench -c 10 -j 4 -T 30 -P 5 \
  -f /sql/bench-app-workload.sql \
  -h pgcat -p 6432 -U bench_user benchdb
```

## Tuning Guide

### PgCat Pool Size

The pool size determines how many actual PostgreSQL connections PgCat maintains. Adjust based on your PostgreSQL `max_connections`:

```
pool_size (per user) * number_of_users < max_connections - reserved_connections
```

With the defaults: `30 * 2 = 60`, well within the 200 `max_connections`.

### Pool Mode

| Mode | Description | Use Case |
|------|-------------|----------|
| `transaction` | Connection returned after each transaction | Most applications (default) |
| `session` | Connection held for entire client session | Apps using session-level features (LISTEN/NOTIFY, temp tables) |

### Scaling Benchmarks

For more realistic testing:

```bash
# Large dataset (1M rows in pgbench_accounts)
./scripts/bench.sh --scale 100

# High concurrency
./scripts/bench.sh --clients 100 --threads 8

# Extended duration for stable results
./scripts/bench.sh --duration 300
```

## Troubleshooting

### PgCat won't start
```bash
# Check logs
docker compose logs pgcat

# Validate config syntax
docker compose exec pgcat cat /etc/pgcat/pgcat.toml
```

### Replica not replicating
```bash
# Check primary WAL senders
docker compose exec pg-primary psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# Check replica recovery status
docker compose exec pg-replica psql -U postgres -c "SELECT pg_last_wal_replay_lsn();"

# Rebuild replica from scratch
docker compose stop pg-replica
docker volume rm pgcat_pg_replica_data
docker compose up -d pg-replica
```

### Connection refused through PgCat
```bash
# Verify PgCat is listening
docker compose exec pgcat ss -tlnp | grep 6432

# Check PgCat can reach PostgreSQL
docker compose exec pgcat pg_isready -h pg-primary -p 5432 -U bench_user

# Review PgCat logs for auth errors
docker compose logs pgcat --tail 50
```

### pgbench errors
```bash
# "relation pgbench_accounts does not exist"
# -> Initialize pgbench tables first:
docker compose exec pgbench pgbench -i -s 10 -h pgcat -p 6432 -U bench_user benchdb

# "password authentication failed"
# -> Verify password in pgcat.toml matches init-primary.sql
```

## Credentials Reference

| User | Password | Purpose |
|------|----------|---------|
| `postgres` | `postgres` | PostgreSQL superuser |
| `bench_user` | `bench_password` | Benchmark application user |
| `replicator` | `replicator_password` | Streaming replication |
| `pgcat` | `pgcat_admin` | PgCat admin interface |

## License

This testing setup is provided as-is for benchmarking and evaluation purposes.
