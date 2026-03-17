# PostgreSQL 18 Multi-Master Cluster

A true multi-master PostgreSQL 18 cluster where **all nodes accept writes**, using native logical replication (bidirectional pub/sub) with Docker Compose.

## Architecture

```
                    ┌─────────────────────────────┐
                    │          HAProxy             │
                    │   Write :5432 (round-robin)  │
                    │   Read  :5433 (leastconn)    │
                     │   Stats :7060                │
                    └──────┬──────┬──────┬─────────┘
                           │      │      │
              ┌────────────┘      │      └────────────┐
              ▼                   ▼                    ▼
     ┌─────────────┐    ┌─────────────┐     ┌─────────────┐
     │  pg-node1   │◄──►│  pg-node2   │◄───►│  pg-node3   │
     │  :5441      │    │  :5442      │     │  :5443      │
     │  (writer)   │◄──►│  (writer)   │◄───►│  (writer)   │
     └─────────────┘    └─────────────┘     └─────────────┘
           Full-mesh logical replication
           (pub/sub with origin=none)

     ┌─────────────┐    ┌─────────────┐     ┌─────────────┐
     │   Valkey     │    │   Valkey     │     │   Valkey     │
     │   Master     │───►│   Replica1   │     │   Replica2   │
     │   :6379      │    │   :6380      │     │   :6381      │
     └─────────────┘    └─────────────┘     └─────────────┘
           │
     ┌─────┴──────────────┬───────────────────┐
     ▼                    ▼                   ▼
  Sentinel1 :26379   Sentinel2 :26380   Sentinel3 :26381
```

**10 services total** — no Patroni, no etcd (all nodes are equal writers).

### How Replication Works

- Each node creates a **publication** (`FOR ALL TABLES`)
- Each node **subscribes** to the other two nodes' publications
- This creates a **full mesh**: 3 publications + 6 subscriptions
- `origin = none` on subscriptions prevents infinite replication loops
- `track_commit_timestamp = on` enables PG18's built-in conflict detection

### Conflict Resolution

> **Honest assessment**: PG18 native logical replication has **limited** conflict handling. Understanding the limitations is critical for production use.

**What PG18 can detect** (via `track_commit_timestamp = on`):
- `update_origin_differs` — an UPDATE arrived for a row that was also updated locally
- `delete_origin_differs` — a DELETE arrived for a row modified by another origin
- `insert_exists` — an INSERT arrived but the row already exists (PK conflict)
- `update_missing` / `delete_missing` — target row doesn't exist

**What PG18 does about conflicts**:
- For `update_origin_differs` and `delete_origin_differs`: **always applies the incoming change**. There is no timestamp comparison or "last-writer-wins" logic — the outcome depends on which subscription applies its change last, which is non-deterministic.
- For `insert_exists` and `update_exists`: **replication STOPS** with an error. The subscription worker crashes and, with `disable_on_error = true`, the subscription is disabled rather than crash-looping.
- For `update_missing` and `delete_missing`: the change is skipped (logged but no error).

**Practical implications**:
- If two nodes update the **same row** concurrently, different nodes may end up with different values (temporarily). Eventually one value "wins" but which one is non-deterministic.
- If two nodes INSERT with the **same PK** (extremely unlikely with UUIDs), replication stops on the receiving node until manually resolved.
- The cluster is **eventually consistent** under normal conditions (no concurrent writes to the same row).
- Use `./scripts/manage.sh conflicts` to monitor conflict stats and `./scripts/manage.sh repair` to recover.

**Best practices**:
- Use UUID primary keys (`gen_random_uuid()`) — avoids insert conflicts entirely
- Avoid concurrent updates to the same row from multiple nodes
- Partition writes by some domain key (e.g., user-owned data written via a consistent hash) if strong consistency is needed
- Monitor conflicts regularly — a non-zero `apply_error_count` means data may be missing

## Quick Start

```bash
# Build and start the cluster
docker compose up -d --build

# Check status
./scripts/manage.sh status

# Run integration tests (13 tests: replication + pgBackRest)
./scripts/manage.sh test

# Run detailed multi-master replication test (INSERT/UPDATE/DELETE across all nodes)
./scripts/manage.sh test-multimaster

# Run benchmarks
./scripts/manage.sh bench

# Connect via psql (write endpoint)
./scripts/manage.sh psql

# Connect to a specific node
./scripts/manage.sh psql 5441   # node1
./scripts/manage.sh psql 5442   # node2
./scripts/manage.sh psql 5443   # node3
```

## Important: DDL Does NOT Replicate

**Logical replication only replicates DML** (INSERT, UPDATE, DELETE). DDL statements (`CREATE TABLE`, `ALTER TABLE`, `DROP TABLE`, etc.) are **NOT replicated**. You must execute DDL on all nodes.

> **Warning**: `DROP TABLE` is especially dangerous — see [Critical Operational Notes](#critical-operational-notes) below. Always use the `ddl` command for drops; never drop tables manually on individual nodes.

Use the built-in DDL helper:

```bash
# Create a table on ALL nodes
./scripts/manage.sh ddl "CREATE TABLE users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    email text,
    created_at timestamptz DEFAULT now()
);"

# Alter a table on ALL nodes
./scripts/manage.sh ddl "ALTER TABLE users ADD COLUMN active boolean DEFAULT true;"

# Drop a table on ALL nodes
./scripts/manage.sh ddl "DROP TABLE IF EXISTS users;"

# Execute DDL from a file on ALL nodes (provide your own)
./scripts/manage.sh ddl -f my_migration.sql
```

The `ddl` command automatically refreshes all subscriptions when tables are created or dropped (subscriptions must be refreshed to learn about new tables).

## Commands

| Command | Description |
|---------|-------------|
| `status` | Cluster overview: node health, pub/sub counts, replication lag |
| `replication` | Detailed publication and subscription info per node |
| `test` | Integration tests: replication + pgBackRest (13 tests) |
| `test-multimaster` | Detailed multi-master replication test (INSERT/UPDATE/DELETE) |
| `ddl "SQL"` | Execute DDL on ALL nodes (canary test on node1 first) |
| `ddl -f file.sql` | Execute DDL from file on ALL nodes |
| `conflicts` | Show conflict stats, disabled subs, apply errors per node |
| `repair enable` | Re-enable all disabled subscriptions |
| `repair enable <node>` | Re-enable disabled subscriptions on one node |
| `repair skip <node>` | Skip stuck errored transaction and re-enable |
| `repair resync <node>` | Drop + recreate subscriptions (full data resync) |
| `repair reset-stats` | Reset conflict counters to zero |
| `backup [type] [node]` | Run pgBackRest backup (full/diff/incr, default: full all) |
| `backup-info [node]` | Show pgBackRest backup info (default: all nodes) |
| `backup-check [node]` | Verify pgBackRest stanza + WAL archiving |
| `psql [port]` | Connect via psql (5432=write, 5433=read, 5441-5443=direct) |
| `valkey-cli` | Connect to Valkey CLI |
| `logs [service]` | Tail Docker logs |
| `bench [scale]` | Run pgbench benchmark (default scale=10) |

## Monitoring & Recovery

### Health Checks

HAProxy uses two complementary health checks per node:

1. **`pgsql-check`** — verifies PostgreSQL is accepting connections (standard PG protocol check)
2. **`agent-check`** (port 5480) — replication health agent that checks:
   - All subscriptions are enabled (not disabled due to errors)
   - No apply errors in `pg_stat_subscription_stats`
   - Replication lag within threshold (default 30s)

If a node has disabled subscriptions, HAProxy **drains** it (stops sending new connections but lets existing ones finish). If apply errors exist, the node's weight is reduced to 50%.

### Conflict Monitoring

```bash
# View conflict stats across all nodes
./scripts/manage.sh conflicts

# Check Docker logs for conflict details
docker logs mm-pg-node1 2>&1 | grep -i conflict
```

### Recovery Procedures

```bash
# Scenario 1: Subscription disabled due to insert conflict
# (most common — usually caused by rare UUID collision or manual INSERT)
./scripts/manage.sh repair skip mm-pg-node2   # skip bad txn + re-enable

# Scenario 2: Subscription disabled, cause unknown
./scripts/manage.sh repair enable              # re-enable all disabled subs
./scripts/manage.sh conflicts                  # check if it sticks

# Scenario 3: Node is badly out of sync — nuclear option
./scripts/manage.sh repair resync mm-pg-node3  # full resync from peers

# Scenario 4: Clean up after investigation
./scripts/manage.sh repair reset-stats         # zero out conflict counters
```

## Ports

| Service | Port | Purpose |
|---------|------|---------|
| HAProxy Write | 5432 | Round-robin writes to all PG nodes |
| HAProxy Read | 5433 | Least-connections reads from all PG nodes |
| HAProxy Stats | 7060 | Web dashboard at http://localhost:7060/stats |
| pg-node1 | 5441 | Direct access to node 1 |
| pg-node2 | 5442 | Direct access to node 2 |
| pg-node3 | 5443 | Direct access to node 3 |
| Valkey Master | 6379 | Cache (master) |
| Valkey Replica 1 | 6380 | Cache (replica) |
| Valkey Replica 2 | 6381 | Cache (replica) |
| Sentinel 1/2/3 | 26379-26381 | Valkey high-availability |

## Benchmark Results

Tested on Docker Desktop with ~2GB RAM, pgbench scale=10 (1M rows), 30s per test.
Benchmarks run with subscriptions disabled (each node tested independently):

| Metric | Per Node (avg) | Aggregate (3 nodes) |
|--------|---------------|---------------------|
| Write TPS | ~6,167 | ~18,502 |
| Read TPS | ~37,829 | ~113,485 |
| Failed txns | 0 | 0 |
| Write nodes | All 3 | All 3 |

For comparison, the single-writer Patroni cluster (`pg_patroni_hap/`) achieved ~1,560 write TPS and ~22,700 read TPS — but writes are limited to a single primary node.

> **Note**: Benchmark numbers are raw per-node performance with replication disabled.
> Under normal operation with replication enabled, effective throughput is lower due to
> WAL shipping overhead. The `bench` command disables subscriptions because pgbench's
> TPC-B workload would cause conflicts across nodes.

## Network

Uses subnet `172.29.0.0/16` (the single-writer `pg_patroni_hap/` cluster uses `172.28.0.0/16`), so both clusters can run simultaneously.

## Comparison with Single-Writer (pg_patroni_hap/)

| Feature | Multi-Master (pg_multi_native_hap/) | Single-Writer (pg_patroni_hap/) |
|---------|-------------------------|---------------------|
| Write nodes | All 3 | Primary only |
| Failover | N/A (all nodes equal) | Patroni auto-failover |
| Replication | Logical (async) | Streaming (sync/async) |
| DDL replication | Manual (use `ddl` command) | Automatic |
| Conflict handling | Non-deterministic (see above) | N/A (single writer) |
| Components | PG + HAProxy + Valkey | PG + Patroni + etcd + HAProxy + Valkey |
| Services | 10 | 16 |
| Best for | Write-heavy distributed | Read-heavy, strong consistency |

## Critical Operational Notes

### Docker `init: true` is Required

All PG node containers use `init: true` in `docker-compose.yml`. This injects Docker's `tini` as PID 1 instead of PostgreSQL. Without this, background processes (like the socat-based health agent) create child processes that get reparented to PID 1 (PostgreSQL). When these children exit, PG interprets them as crashed backend processes and initiates a full server recovery, disabling all subscription workers. `init: true` completely eliminates this issue.

### DROP TABLE Requires Disabling Subscriptions First

**Dropping a table that exists in a `FOR ALL TABLES` publication generates WAL that will poison peer subscriptions.** If a subscriber tries to replay the DROP's associated WAL entries and the table was already dropped locally, the subscription worker errors out and gets disabled (`disable_on_error = true`).

**Safe procedure for dropping tables:**
1. Disable all subscriptions on all nodes
2. Drop the table on all nodes
3. Re-enable all subscriptions

The `ddl` command handles this automatically for `DROP TABLE` operations. The `test` and `bench` commands also follow this pattern.

### WAL Accumulates While Subscriptions Are Disabled

When subscriptions are disabled (manually or by `disable_on_error`), WAL from peer nodes **accumulates**. When the subscription is re-enabled, the worker tries to replay ALL accumulated WAL. If that WAL references tables that no longer exist, the worker will error out again immediately.

**If subscriptions were disabled during significant write activity** (e.g., bulk data loads, benchmarks), you must **drop and recreate** the subscriptions rather than simply re-enabling them. Recreating starts from the current LSN, skipping all accumulated WAL. The `bench` command does this automatically in its cleanup.

```bash
# If simple re-enable fails (subscription keeps getting disabled):
./scripts/manage.sh repair resync <node>  # drops + recreates subscriptions
```

## Backup & Recovery (pgBackRest)

Each PG node has its own pgBackRest stanza because each is an independent `initdb` (different system-id). WAL archiving runs continuously via `archive_command`.

### Stanzas

| Stanza | Node | Description |
|--------|------|-------------|
| `pg-mm-node1` | mm-pg-node1 | Multi-master node 1 |
| `pg-mm-node2` | mm-pg-node2 | Multi-master node 2 |
| `pg-mm-node3` | mm-pg-node3 | Multi-master node 3 |

### Configuration

| Setting | Value |
|---------|-------|
| `repo1-type` | `posix` (shared Docker volume) |
| `compress-type` | `lz4` |
| `archive-async` | `y` (with spool) |
| `repo1-retention-full` | `2` |
| `repo1-retention-diff` | `3` |
| `repo1-retention-archive` | `2` |
| `start-fast` | `y` |
| `process-max` | `2` |

### Usage

```bash
# Check backup info for all nodes
./scripts/manage.sh backup-info

# Check backup info for a specific node
./scripts/manage.sh backup-info node1

# Run a full backup on all nodes
./scripts/manage.sh backup full

# Run a differential backup on node2
./scripts/manage.sh backup diff node2

# Verify stanza + WAL archiving
./scripts/manage.sh backup-check
./scripts/manage.sh backup-check node3
```

### How It Works

1. **Stanza creation + initial full backup** run in background after PG starts
2. **WAL archiving** is continuous via `archive_command = 'pgbackrest --stanza=... archive-push %p'`
3. **Shared repo volume** (`pgbackrest-repo`) is mounted on all 3 nodes at `/var/lib/pgbackrest`
4. **Per-node spool/log volumes** keep async archive spool and logs separate
5. **Config is generated at runtime** by `pg-entrypoint.sh` using `PGBACKREST_STANZA` env var

## Configuration

Environment variables in `.env`:

- `POSTGRES_PASSWORD` — PostgreSQL superuser password
- `POSTGRES_DB` — Database name (default: `appdb`)
- `VALKEY_PASSWORD` — Valkey authentication password
- `HAPROXY_WRITE_PORT` / `HAPROXY_READ_PORT` — HAProxy ports
- `BACKUP_STANZA_NODE1/2/3` — pgBackRest stanza names per node
- `SUBNET` — Docker network subnet

PostgreSQL tuning in `postgres/postgresql.conf` is sized for a 2GB Docker VM:
- `shared_buffers = 256MB`
- `effective_cache_size = 768MB`
- `work_mem = 4MB`
- `wal_level = logical` (required for logical replication)
- `archive_mode = on` (WAL archiving for pgBackRest)
- `max_logical_replication_workers = 10`
- `track_commit_timestamp = on` (enables conflict detection)
