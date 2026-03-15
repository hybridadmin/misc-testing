# pg_spock — PostgreSQL 18 Multi-Master with Spock

Active-active multi-master PostgreSQL 18 cluster using [Spock v5.0.6](https://github.com/pgEdge/spock) for bidirectional logical replication. Two R/W primaries replicate to each other via Spock, each with a streaming read-only replica, all behind HAProxy for load balancing. PostgreSQL tuning follows [autobase](https://github.com/vitabaks/autobase) best practices.

## Architecture

```
                        HAProxy
                       /       \
              R/W :15000       RO :15001
              /       \       /       \
         node1(R/W)  node2(R/W)  node3(RO)  node4(RO)
           |    \       /    |      |           |
           |     \     /     |      |           |
           |    Spock bi-    |      |           |
           |    directional  |      |           |
           |    replication  |      |           |
           |                 |      |           |
           +--- streams to --+---> node3       node4
                                  (from n1)   (from n2)
```

**5 containers total**, all native ARM64 Docker images (no Rosetta 2 emulation).

### How It Works

1. **Spock** provides bidirectional logical replication between node1 and node2. Both nodes accept reads and writes simultaneously (active-active multi-master).
2. **Streaming replication** provides read-only replicas: node3 streams from node1, node4 streams from node2. Replicas receive both local writes and Spock-replicated data from their primaries.
3. **HAProxy** routes R/W traffic (round-robin) to node1+node2, and RO traffic (round-robin) to node3+node4.
4. **Sequence offsets** prevent primary key conflicts: node1 generates odd IDs (1,3,5,...), node2 generates even IDs (2,4,6,...).
5. **DDL is not replicated** by Spock — schema changes must be applied manually to both primaries.

### Replication

- **Multi-master**: Both node1 and node2 accept writes. Spock replicates DML (INSERT/UPDATE/DELETE) bidirectionally.
- **Conflict avoidance**: BIGSERIAL sequences use `INCREMENT BY 2` with staggered start values (odd/even) to prevent PK collisions.
- **Streaming replicas**: node3 and node4 are traditional streaming replicas providing read scaling and redundancy.
- **`wal_level: logical`**: Required for Spock, also supports native PG logical replication if needed.
- **`track_commit_timestamp: on`**: Required by Spock for conflict resolution.

### Key Differences from pg_autobase

| Feature | pg_autobase | pg_spock |
|---------|-------------|----------|
| Replication model | Single primary + streaming replicas | Active-active multi-master (Spock) |
| Failover | Automatic (Patroni + etcd) | Manual (no DCS — both nodes are always primary) |
| Write scaling | Single writer | 2 writers (round-robin via HAProxy) |
| DDL replication | Automatic (streaming) | Manual (Spock limitation) |
| Connection pooling | PgBouncer | None (direct HAProxy) |
| Backup solution | pgBackRest | pgBackRest |
| DCS | etcd (3 nodes) | None required |
| Containers | 14 | 5 |
| PG extensions | pg_stat_statements | Spock + pg_stat_statements |

## Quick Start

```bash
# Start the cluster (first run builds PG 18.3 + Spock from source — ~5 min)
docker compose up -d

# Wait ~30-45s for all containers to become healthy, then run Spock setup
./scripts/setup-spock.sh

# Check cluster status
./scripts/manage.sh status

# Run integration tests (23 tests)
./scripts/manage.sh test

# Run pgbench benchmarks
./scripts/manage.sh bench
```

## Connection Info

| Service | Host | Port | Description |
|---------|------|------|-------------|
| **HAProxy R/W** | localhost | 15000 | Round-robin to node1 + node2 (read-write) |
| **HAProxy RO** | localhost | 15001 | Round-robin to node3 + node4 (read-only) |
| HAProxy Stats | localhost | 17000 | Web UI at `/` |
| Node 1 direct | localhost | 15432 | R/W (Spock primary, odd IDs) |
| Node 2 direct | localhost | 15433 | R/W (Spock primary, even IDs) |
| Node 3 direct | localhost | 15434 | RO (streams from node1) |
| Node 4 direct | localhost | 15435 | RO (streams from node2) |

### Default Credentials

| User | Password | Purpose |
|------|----------|---------|
| postgres | `postgres` | Superuser |
| replicator | `replicator` | Streaming replication |

### Connection Examples

```bash
# Via HAProxy R/W (recommended for writes — multi-master round-robin)
PGPASSWORD=postgres psql -h localhost -p 15000 -U postgres -d spockdb

# Via HAProxy RO (recommended for reads — replica round-robin)
PGPASSWORD=postgres psql -h localhost -p 15001 -U postgres -d spockdb

# Direct to a specific node
PGPASSWORD=postgres psql -h localhost -p 15432 -U postgres -d spockdb

# Or use manage.sh shortcuts
./scripts/manage.sh psql rw       # or: primary, master, p
./scripts/manage.sh psql ro       # or: replica, replicas, r
./scripts/manage.sh psql node1    # or: n1, 1
./scripts/manage.sh psql node2    # or: n2, 2
./scripts/manage.sh psql node3    # or: n3, 3
./scripts/manage.sh psql node4    # or: n4, 4
```

## manage.sh CLI Reference

```
Usage: ./scripts/manage.sh [command] [args...]

Info:
  status              Cluster health overview (nodes, Spock, HAProxy, replication)
  topology            Detailed Spock + streaming replication topology
  logs [target]       Stream logs (all|haproxy|node1..4|primaries|replicas)

Access:
  psql [target]       Interactive psql (rw|ro|node1..4)

Setup:
  setup               Run Spock setup (nodes, subscriptions, test data)
  reinit              Full cluster reinit (DESTROYS ALL DATA)

Backup (pgBackRest):
  backup [type] [node]  Run backup (type: full|diff|incr, default: diff, node: node1|node2)
  backup-info [node]    Show backup inventory
  backup-check [node]   Verify stanza and WAL archiving

Test & Benchmark:
  test                Run integration tests (23 tests)
  bench               Run pgbench benchmarks (TPC-B + SELECT-only)
```

## Spock Multi-Master

### How Spock Bidirectional Replication Works

Spock uses PostgreSQL's logical decoding infrastructure to replicate row-level changes:

1. Each primary is registered as a **Spock node** with a DSN reachable from the other node.
2. Tables are added to **replication sets** (the `default` set includes all public tables).
3. **Subscriptions** define the replication direction: node1 subscribes to node2's changes, and vice versa.
4. Spock uses `track_commit_timestamp` and origin tracking to prevent **replication loops** — changes received via replication are not re-replicated.

### Multi-Master Caveats

- **DDL not replicated**: `CREATE TABLE`, `ALTER TABLE`, etc. must be run on both nodes manually. Only DML (INSERT/UPDATE/DELETE) is replicated.
- **Sequence conflicts**: Mitigated by odd/even ID allocation. For more than 2 writers, use UUIDs or a global sequence service.
- **Conflict resolution**: Spock uses last-writer-wins based on commit timestamps. If the same row is updated on both nodes simultaneously, the later commit wins.
- **Schema must match**: Both primaries must have identical table schemas before replication starts.

### Adding New Tables

```sql
-- Step 1: Create the table on BOTH primaries
-- On node1:
CREATE TABLE products (id BIGSERIAL PRIMARY KEY, name TEXT, price NUMERIC);
ALTER SEQUENCE products_id_seq INCREMENT BY 2 RESTART WITH 1;

-- On node2:
CREATE TABLE products (id BIGSERIAL PRIMARY KEY, name TEXT, price NUMERIC);
ALTER SEQUENCE products_id_seq INCREMENT BY 2 RESTART WITH 2;

-- Step 2: Add to replication set on BOTH primaries
SELECT spock.repset_add_table('default', 'products');
```

## PostgreSQL Configuration (Autobase Best Practices)

Conservative settings for a Docker VM with 4 PG nodes sharing resources, with autobase-style tuning:

| Category | Parameter | Value | Notes |
|----------|-----------|-------|-------|
| **Memory** | shared_buffers | 128MB | Per node (4 nodes sharing Docker VM) |
| | effective_cache_size | 384MB | ~3x shared_buffers |
| | work_mem | 8MB | Per-sort operation memory |
| | maintenance_work_mem | 64MB | VACUUM, CREATE INDEX |
| | huge_pages | off | Not available in Docker |
| **WAL** | wal_buffers | 8MB | |
| | min_wal_size | 128MB | |
| | max_wal_size | 512MB | |
| | checkpoint_completion_target | 0.9 | Spread checkpoint I/O |
| | checkpoint_timeout | 10min | |
| | wal_compression | on | Reduce WAL volume |
| | wal_log_hints | on | Required for pg_rewind |
| | archive_mode | on | Continuous WAL archiving to pgBackRest |
| | archive_timeout | 300 | Force archive every 5 min (low-write periods) |
| | archive_command | pgbackrest archive-push | WAL segments archived to shared repo |
| **Replication** | wal_level | logical | Required for Spock |
| | max_wal_senders | 20 | |
| | max_replication_slots | 20 | |
| | hot_standby | on | |
| | hot_standby_feedback | on | Prevents vacuum conflicts |
| | track_commit_timestamp | on | Required by Spock |
| **Connections** | max_connections | 200 | Autobase default |
| | superuser_reserved_connections | 5 | |
| | idle_in_transaction_session_timeout | 10min | |
| | statement_timeout | 60s | |
| | tcp_keepalives_count | 10 | |
| | tcp_keepalives_idle | 300 | |
| | tcp_keepalives_interval | 30 | |
| **Query Planner** | random_page_cost | 1.1 | SSD-optimized |
| | seq_page_cost | 1 | |
| | effective_io_concurrency | 200 | SSD concurrency |
| | default_statistics_target | 500 | Better planner stats |
| | jit | off | Autobase recommendation (JIT overhead for OLTP) |
| **Autovacuum** | autovacuum_vacuum_scale_factor | 0.01 | Aggressive — vacuum at 1% dead tuples |
| | autovacuum_analyze_scale_factor | 0.01 | Aggressive — analyze at 1% changes |
| | autovacuum_max_workers | 3 | |
| | autovacuum_vacuum_cost_limit | 500 | Higher than default 200 |
| | autovacuum_vacuum_cost_delay | 2ms | Lower than default 20ms |
| | autovacuum_naptime | 1s | Much more frequent than default 1min |
| **Extensions** | shared_preload_libraries | spock,pg_stat_statements | |
| | pg_stat_statements.max | 10000 | |
| | pg_stat_statements.track | all | |
| **Security** | password_encryption | scram-sha-256 | |
| | data_checksums | on | Enabled at initdb |
| | max_locks_per_transaction | 512 | |
| **Logging** | log_min_duration_statement | 1000ms | Log slow queries >1s |
| | log_checkpoints | on | |
| | log_lock_waits | on | |
| | log_temp_files | 0 | Log all temp files |
| | track_io_timing | on | |
| | track_functions | all | |

### HAProxy Configuration

| Setting | Value | Notes |
|---------|-------|-------|
| maxconn | 10000 | Global max connections |
| Client/server timeout | 60 minutes | Long-running queries |
| Health check | pgsql-check | Every 3s, fast-interval 1s |
| on-marked-down | shutdown-sessions | Immediate client disconnect |
| fall / rise | 3 / 2 | Fast convergence |

## Docker Configuration

| Setting | Value | Notes |
|---------|-------|-------|
| shm_size | 256mb | Shared memory for PostgreSQL |
| init | true | Proper PID 1 signal handling |
| Static IPs | 172.37.0.x | Prevents Docker auto-assignment conflicts |
| Network subnet | 172.37.0.0/16 | Avoids conflicts with other clusters |
| Health checks | pg_isready | 5s interval, 30 retries, 30s start_period |

## Network Layout

- **Subnet**: 172.37.0.0/16
- Node 1: 172.37.0.10
- Node 2: 172.37.0.11
- Node 3: 172.37.0.12
- Node 4: 172.37.0.13
- HAProxy: 172.37.0.20

All containers have static IPs to prevent Docker auto-assignment conflicts.

## Benchmarks

Run benchmarks with:

```bash
./scripts/manage.sh bench
```

 The benchmark suite runs 3 tests matching the pg_autobase pattern:

| Test | Target | Duration | Clients | Description |
|------|--------|----------|---------|-------------|
| Part 1 | Direct node1 (:15432) | 60s | 10c/2j | TPC-B write on Spock primary #1 |
| Part 2 | HAProxy RO (:15001) | 60s | 10c/2j | SELECT-only read (round-robin across both replicas) |
| Part 3 | Direct node2 (:15433) | 60s | 10c/2j | TPC-B write on Spock primary #2 |

pgbench scale factor: 10 (~1M rows in pgbench_accounts). Tables are initialized independently on each primary.

**Note**: TPC-B writes target each primary directly (not via HAProxy R/W) because pgbench's standard TPC-B updates random rows by `aid` — round-robin across two masters would cause UPDATE/UPDATE conflicts on the same row. Running Part 1 and Part 3 against each primary separately confirms both masters perform equally.

## Integration Tests

Run tests with:

```bash
./scripts/manage.sh test
```

23 tests covering:

| # | Test | What it verifies |
|---|------|-----------------|
| 1 | HAProxy R/W routes to primary | R/W port connects to a primary node |
| 2 | HAProxy RO routes to replica | RO port connects to a replica node |
| 3 | Both node1 and node2 are primaries | Multi-master topology correct |
| 4 | Both node3 and node4 are replicas | Streaming replicas in recovery mode |
| 5 | Spock extension on both primaries | Extension loaded and functional |
| 6 | pg_stat_statements loaded | Monitoring extension available |
| 7 | Spock subscriptions active | Bidirectional replication configured |
| 8 | Write via HAProxy R/W | Data can be written through the proxy |
| 9 | Spock replication node1 -> node2 | Data written on node1 appears on node2 |
| 10 | Spock replication node2 -> node1 | Data written on node2 appears on node1 |
| 11 | Streaming replica node3 has data | node1's data (including Spock) streams to node3 |
| 12 | Streaming replica node4 has data | node2's data (including Spock) streams to node4 |
| 13 | Read via HAProxy RO | Replicated data readable through RO proxy |
| 14 | HAProxy R/W round-robin | Traffic distributed across both primaries |
| 15 | HAProxy RO round-robin | Traffic distributed across both replicas |
| 16 | Data checksums enabled | Autobase best practice |
| 17 | JIT disabled | Autobase best practice for OLTP |
| 18 | Autovacuum scale factor = 0.01 | Aggressive autovacuum (autobase) |
| 19 | SSD planner: random_page_cost = 1.1 | SSD-optimized query planner |
| 20 | Bulk writes via HAProxy R/W | 100-row bulk insert through proxy |
| 21 | pgBackRest stanza exists | Backup stanza configured and accessible |
| 22 | WAL archiving enabled | archive_mode=on for continuous archiving |
| 23 | pgBackRest has at least one backup | Initial full backup completed |

## File Structure

```
pg_spock/
├── .env                          # All config variables (ports, IPs, passwords)
├── .gitignore                    # Git ignore rules
├── .dockerignore                 # Docker build context exclusions
├── Dockerfile                    # Multi-stage: PG 18.3 + Spock v5.0.6 + pgBackRest
├── docker-compose.yml            # 5 services (4 PG nodes + HAProxy)
├── haproxy.cfg                   # R/W :5000 + RO :5001 + stats :7000
├── README.md                     # This file
├── pgbackrest/
│   └── pgbackrest.conf           # pgBackRest config (POSIX repo, lz4, async archiving)
└── scripts/
    ├── entrypoint.sh             # Container entrypoint (primary init or replica basebackup)
    ├── setup-spock.sh            # Post-startup Spock configuration
    └── manage.sh                 # CLI (status/test/bench/backup/psql/logs/topology/reinit)
```

## Docker Images

| Component | Image | Notes |
|-----------|-------|-------|
| PostgreSQL 18.3 | Built from source (`debian:bookworm-slim`) | Patched with 5 Spock patches |
| Spock v5.0.6 | Built from source (PGXS) | Compiled against patched PG 18 |
| pgBackRest 2.45 | `apt-get install pgbackrest` | From Debian bookworm repos |
| HAProxy | `haproxy:3.1-alpine` | Native ARM64 |

The Dockerfile uses a multi-stage build:
- **Stage 1 (builder)**: Clones PG 18.3 + Spock v5.0.6, applies patches, compiles PG with `--with-openssl --with-libxml --with-libxslt --with-lz4 --with-zstd --with-icu`, then builds Spock extension via PGXS.
- **Stage 2 (runtime)**: Slim Debian image with only runtime libraries + pgBackRest, copies PG + Spock binaries from builder.

## pgBackRest Backup & Archiving

Both primaries and all replicas have pgBackRest installed. WAL archiving is continuous via `archive_command`, and backups are stored in a shared Docker volume (`pgbackrest-repo`).

### Configuration

| Setting | Value | Notes |
|---------|-------|-------|
| Stanza | `pg-spock` | Matches cluster name |
| Repo type | POSIX (local) | Shared Docker volume at `/var/lib/pgbackrest` |
| Compression | lz4 (level 1) | Fast, low CPU; level 3 for archive-push |
| Archiving | Async | Spool at `/var/spool/pgbackrest` |
| Retention | 2 full, 3 diff | Archive retention anchored to full backups |
| `archive_timeout` | 300s | Force archive every 5 min |

### Backup Commands

```bash
# Run a differential backup (default)
./scripts/manage.sh backup

# Run a full backup
./scripts/manage.sh backup full

# Run an incremental backup
./scripts/manage.sh backup incr

# Show backup inventory
./scripts/manage.sh backup-info

# Verify stanza and WAL archiving
./scripts/manage.sh backup-check
```

Backups can target either primary: `./scripts/manage.sh backup full node2`

### Initial Setup

The stanza is created automatically during primary initialization. The first full backup runs in the background after `initdb`. Subsequent backups are manual via `manage.sh`.

### Shared Backup Volume

All 4 PG nodes mount the same `pgbackrest-repo` Docker volume at `/var/lib/pgbackrest`. This allows any node to access the backup repository without SSH or a dedicated backup server. Each node has its own spool and log volumes for async WAL archiving.

> **Production note**: For production use, replace the POSIX repository with a remote backend (S3, GCS, Azure Blob, or SFTP) to ensure backups survive host failure.

## Limitations

- **No automatic failover**: Unlike pg_autobase (Patroni), this cluster has no DCS or automatic leader election. Both primaries are always writable. If one dies, the other continues; when it returns, Spock catches up.
- **DDL not replicated**: Schema changes must be applied manually to both primaries. This is a fundamental Spock limitation.
- **No connection pooling**: No PgBouncer. For high-connection workloads, add PgBouncer in front of HAProxy.
- **Shared backup volume**: pgBackRest uses a shared Docker volume — backups are local to the Docker host, not off-site. For production, configure a remote repository (S3, GCS, Azure, or SFTP).
- **Memory constrained**: Running 4 PostgreSQL instances + HAProxy in a Docker VM. Not suitable for heavy workloads; designed for development and multi-master testing.
- **No TLS**: All connections are unencrypted within the Docker network. Suitable for local development only.
- **Sequence strategy**: Odd/even IDs work for exactly 2 writers. For more writers, switch to UUIDs or a different allocation strategy.
- **Conflict resolution**: Last-writer-wins. Simultaneous updates to the same row on both nodes will result in one update being lost silently.
