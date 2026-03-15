# pg_autobase — PostgreSQL 18 HA with Patroni + pgBackRest

Production-ready PostgreSQL 18 high-availability cluster inspired by [vitabaks/autobase](https://github.com/vitabaks/autobase) patterns. Patroni for automatic failover, etcd for distributed consensus, HAProxy with 4 backends (master/replicas/sync/async), PgBouncer for connection pooling, pgBackRest for backup and WAL archiving, and Valkey for caching.

## Architecture

```
Clients --> PgBouncer(:6432) --> HAProxy(:5050 RW, :5051 RO, :5052 sync, :5053 async)
                                     |
          +-------------+------------+------------+
          |             |                         |
     patroni1      patroni2      patroni3    (PG 18 + Patroni + pgBackRest)
     :5432/:8008   :5432/:8008   :5432/:8008
          |             |                         |
          +-------------+------------+------------+
                        |
                 shared backups volume (/var/lib/pgbackrest)
          |             |                         |
     etcd1:2379    etcd2:2379    etcd3:2379   (DCS cluster)

+ Valkey 9 (1 master + 2 replicas + 3 sentinels)
```

**14 containers total**, all native ARM64 Docker images (no Rosetta 2 emulation).

### How It Works

1. **Patroni** manages PostgreSQL on each node — handles bootstrap, replication setup, leader election, and automatic failover via etcd.
2. **etcd** (3-node cluster) stores the cluster state and leader lock. Patroni nodes compete for the leader key; the winner becomes primary.
3. **HAProxy** checks the Patroni REST API using `OPTIONS` method (autobase pattern) against 4 endpoints (`/primary`, `/replica`, `/sync`, `/async`) and routes traffic to the appropriate backend.
4. **PgBouncer** provides connection pooling in `transaction` mode in front of HAProxy, with 5 database aliases (appdb, appdb_ro, appdb_sync, appdb_async, postgres).
5. **pgBackRest** handles WAL archiving (`archive_command`), backup creation, and replica provisioning (`create_replica_methods: [pgbackrest, basebackup]`). All nodes share a single backup repository via a Docker volume — no SSH or TLS required.
6. **Valkey** provides an independent caching layer with its own HA (sentinel-managed failover).

### Replication

- **Synchronous replication** is enabled (`synchronous_mode: true`, `synchronous_commit: on`).
- One standby is always the `sync_standby` (synchronous commit guaranteed), the other is `async`.
- This provides **RPO=0** (zero data loss) on failover — the sync standby is always up-to-date.
- `pg_rewind` is enabled, allowing former primaries to rejoin as replicas without a full base backup.
- `wal_level: logical` — supports logical replication if needed.

### Key Differences from pg_patroni

| Feature | pg_patroni | pg_autobase |
|---------|-----------|-------------|
| HAProxy backends | 2 (RW/RO) | 4 (master/replicas/sync/async) |
| Health check method | `GET` | `OPTIONS` (autobase pattern) |
| Backup solution | None | pgBackRest (WAL archiving + full/diff/incr backups) |
| Replica creation | `basebackup` only | `pgbackrest` first, `basebackup` fallback |
| wal_level | `replica` | `logical` |
| max_connections | 100 | 200 |
| Autovacuum | Default | Aggressive (autobase tuning) |
| pg_stat_statements | No | Yes (preloaded) |
| Data checksums | No | Yes |
| JIT | Default | Off (autobase recommendation) |

## Quick Start

```bash
# Start the cluster (first run builds the Patroni+pgBackRest Docker image)
docker compose up -d

# Wait ~30-45s for all containers to become healthy, then check status
./scripts/manage.sh status

# Run integration tests (17 tests including pgBackRest verification)
./scripts/manage.sh test
```

## Connection Info

| Service | Host | Port | Description |
|---------|------|------|-------------|
| **PgBouncer** | localhost | 6433 | Pooled connections (recommended) |
| HAProxy Master | localhost | 5050 | Direct to primary (read-write) |
| HAProxy Replicas | localhost | 5051 | Load-balanced replicas (read-only) |
| HAProxy Sync | localhost | 5052 | Sync replicas only |
| HAProxy Async | localhost | 5053 | Async replicas only |
| HAProxy Stats | localhost | 7080 | Web UI at `/stats` |
| Node 1 direct | localhost | 6051 | Bypass HAProxy (debugging) |
| Node 2 direct | localhost | 6052 | Bypass HAProxy (debugging) |
| Node 3 direct | localhost | 6053 | Bypass HAProxy (debugging) |
| Patroni API 1 | localhost | 8051 | REST API |
| Patroni API 2 | localhost | 8052 | REST API |
| Patroni API 3 | localhost | 8053 | REST API |
| Valkey | localhost | 7010 | Cache master |
| Valkey Sentinel | localhost | 27010 | Sentinel (discovery) |

### Default Credentials

| User | Password | Purpose |
|------|----------|---------|
| postgres | `changeme_postgres_2025` | Superuser |
| replicator | `changeme_repl_2025` | Replication |
| admin | `changeme_admin_2025` | App admin (createrole, createdb) |
| Valkey | `changeme_valkey_2025` | Cache auth |

### Connection Examples

```bash
# Via PgBouncer (recommended — pooled, routes to primary)
PGPASSWORD=changeme_postgres_2025 psql -h localhost -p 6433 -U postgres -d appdb

# Via HAProxy Master (read-write)
PGPASSWORD=changeme_postgres_2025 psql -h localhost -p 5050 -U postgres -d appdb

# Via HAProxy Replicas (read-only, round-robin)
PGPASSWORD=changeme_postgres_2025 psql -h localhost -p 5051 -U postgres -d appdb

# Via HAProxy Sync (sync replica only)
PGPASSWORD=changeme_postgres_2025 psql -h localhost -p 5052 -U postgres -d appdb

# PgBouncer read-only alias (routes to HAProxy replicas backend)
PGPASSWORD=changeme_postgres_2025 psql -h localhost -p 6433 -U postgres -d appdb_ro

# Direct to a specific node
PGPASSWORD=changeme_postgres_2025 psql -h localhost -p 6051 -U postgres -d appdb

# Or use manage.sh shortcuts
./scripts/manage.sh psql primary   # or: master, rw, p
./scripts/manage.sh psql replica   # or: replicas, ro, r
./scripts/manage.sh psql sync      # or: s
./scripts/manage.sh psql async     # or: a
./scripts/manage.sh psql bouncer   # or: pgb, b
./scripts/manage.sh psql node1     # or: n1, 1
```

## manage.sh CLI Reference

```
Usage: ./scripts/manage.sh [command] [args...]

Info:
  status              Cluster health overview (all components + pgBackRest)
  topology            Detailed replication/etcd topology
  logs [target]       Stream logs (all|patroni|etcd|haproxy|pgbouncer|valkey|sentinel|node1..3)

Access:
  psql [target]       Interactive psql (primary|replica|sync|async|bouncer|node1..3)
  patronictl [args]   Run patronictl commands (e.g., list, show-config, edit-config)

HA Operations:
  switchover          Graceful primary switchover (zero downtime)
  failover            Emergency failover (promotes best candidate)
  reinit              Full cluster reinit (DESTROYS ALL DATA)

pgBackRest:
  backup [type]       Run backup (full|diff|incr, default: diff)
  backup-info         Show backup inventory
  backup-check        Verify stanza and WAL archiving

Test & Benchmark:
  test                Run integration tests (17 tests)
  bench               Run pgbench benchmarks (TPC-B + SELECT-only + PgBouncer)
```

## pgBackRest

### How Backups Work

pgBackRest is co-installed in each Patroni/PostgreSQL container. All 3 nodes share a single backup repository via a Docker volume mounted at `/var/lib/pgbackrest` — no SSH or TLS needed.

- **WAL archiving**: PostgreSQL's `archive_command` pushes WAL segments to pgBackRest asynchronously (`archive-async=y`, `lz4` compression).
- **Stanza auto-creation**: The `post-bootstrap.sh` script creates the pgBackRest stanza and kicks off an initial full backup after Patroni bootstraps the cluster.
- **Replica provisioning**: New replicas try `pgbackrest --delta restore` first, falling back to `pg_basebackup` if no backup is available.

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

### pgBackRest Configuration

| Setting | Value | Notes |
|---------|-------|-------|
| Repo type | POSIX (local) | Shared Docker volume |
| Compression | lz4 | Fast, low CPU |
| archive-async | yes | Non-blocking WAL archiving |
| repo1-bundle | yes | Bundle small files together |
| repo1-block | yes | Block-level deduplication |
| delta | yes | Only restore changed files |
| Retention (full) | 2 | Keep last 2 full backups |
| Retention (diff) | 3 | Keep last 3 differential backups |

## HA Operations

### Graceful Switchover

Moves the primary role to a specific replica with zero downtime:

```bash
# Interactive (prompts for confirmation and target)
./scripts/manage.sh switchover

# Or via patronictl directly
./scripts/manage.sh patronictl switchover --leader patroni1 --candidate patroni2 --force
```

### Automatic Failover

If the primary dies, Patroni automatically promotes the sync_standby within ~30 seconds (`ttl=30`, `failsafe_mode=true`). HAProxy detects the change via REST API health checks and re-routes traffic. No manual intervention required.

To simulate:
```bash
# Kill the primary
docker kill ab-node1   # (or whichever is currently primary)

# Watch the failover (takes ~30s)
watch -n2 'curl -s http://localhost:8051/cluster 2>/dev/null | jq -r ".members[] | \"\(.name): \(.role) (\(.state))\""'

# The killed node will rejoin as a replica when restarted
docker start ab-node1
```

### patronictl

Full access to Patroni's management tool:

```bash
./scripts/manage.sh patronictl list
./scripts/manage.sh patronictl show-config
./scripts/manage.sh patronictl edit-config   # edit DCS config live
./scripts/manage.sh patronictl history       # timeline history
```

## Network Layout

- **Subnet**: 172.36.0.0/16
- etcd nodes: 172.36.0.2-4
- Patroni/PG nodes: 172.36.0.10-12
- HAProxy: 172.36.0.20
- PgBouncer: 172.36.0.21
- Valkey: 172.36.0.30-35

All containers have static IPs to prevent Docker auto-assignment conflicts.

## Configuration

### PostgreSQL Parameters (via Patroni DCS)

Conservative settings for a Docker VM with ~1.9GB RAM, with autobase-style tuning:

| Parameter | Value | Notes |
|-----------|-------|-------|
| shared_buffers | 128MB | Per node (3 nodes sharing Docker VM) |
| effective_cache_size | 384MB | |
| work_mem | 8MB | |
| maintenance_work_mem | 64MB | |
| max_connections | 200 | Per node (autobase default) |
| synchronous_commit | on | RPO=0 |
| wal_level | logical | Supports logical replication |
| max_wal_senders | 20 | |
| max_replication_slots | 20 | Managed by Patroni |
| password_encryption | scram-sha-256 | |
| jit | off | Autobase recommendation |
| shared_preload_libraries | pg_stat_statements | Query statistics |
| autovacuum_vacuum_scale_factor | 0.01 | Aggressive (autobase) |
| autovacuum_analyze_scale_factor | 0.01 | Aggressive (autobase) |
| random_page_cost | 1.1 | SSD-optimized |

To modify parameters at runtime:
```bash
./scripts/manage.sh patronictl edit-config
```

### PgBouncer

- Pool mode: `transaction`
- Max client connections: 1000
- Default pool size: 50
- 5 database aliases: `appdb`, `appdb_ro`, `appdb_sync`, `appdb_async`, `postgres`

### HAProxy

4 backends using Patroni REST API `OPTIONS` method:

| Backend | Port | Endpoint | Description |
|---------|------|----------|-------------|
| postgres_master | 5050 | `OPTIONS /primary` | Read-write (single primary) |
| postgres_replicas | 5051 | `OPTIONS /replica` | Read-only (all replicas, round-robin) |
| postgres_replicas_sync | 5052 | `OPTIONS /sync` | Sync replicas only |
| postgres_replicas_async | 5053 | `OPTIONS /async` | Async replicas only |

## File Structure

```
pg_autobase/
├── .env                          # All config variables (ports, IPs, passwords)
├── docker-compose.yml            # 14 services, YAML anchors
├── postgres/
│   ├── Dockerfile                # FROM postgres:18 + Patroni + pgBackRest
│   └── patroni.yml               # Patroni config (autobase-style tuning)
├── pgbackrest/
│   └── pgbackrest.conf           # Local POSIX repo, lz4, async archiving
├── haproxy/
│   └── haproxy.cfg               # 4-backend routing + stats
├── pgbouncer/
│   ├── pgbouncer.ini             # Transaction pooling, 5 DB aliases
│   └── userlist.txt              # Auth credentials
├── valkey/
│   └── sentinel.conf             # Sentinel monitor config
└── scripts/
    ├── manage.sh                 # CLI (status/test/bench/psql/backup/etc.)
    ├── patroni-entrypoint.sh     # pgBackRest dirs + templates patroni.yml + starts Patroni
    ├── pg-healthcheck.sh         # Patroni API + pg_isready check
    ├── post-bootstrap.sh         # Creates appdb, pg_stat_statements, pgBackRest stanza + initial backup
    └── sentinel-entrypoint.sh    # Copies/configures sentinel.conf
```

## Docker Images

All images are native ARM64 — no Rosetta 2 emulation:

| Component | Image | Arch |
|-----------|-------|------|
| PostgreSQL 18 | `postgres:18` | arm64 native |
| Patroni | pip install into venv (arch-agnostic Python) | n/a |
| pgBackRest | `apt install pgbackrest` (in PG image) | arm64 native |
| etcd | `quay.io/coreos/etcd:v3.5.17` | arm64 native |
| HAProxy | `haproxy:3.1-alpine` | arm64 native |
| PgBouncer | `edoburu/pgbouncer:latest` | arm64 native |
| Valkey | `valkey/valkey:9` | arm64 native |

## Limitations

- **Memory constrained**: Running 3 PostgreSQL instances + etcd + HAProxy + PgBouncer + pgBackRest + Valkey in a Docker VM with ~1.9GB RAM. Not suitable for heavy workloads; designed for development and HA testing.
- **No TLS**: All connections are unencrypted within the Docker network. Suitable for local development only.
- **PgBouncer auth**: Uses plaintext passwords in `userlist.txt` with `scram-sha-256` auth type. For production, use `auth_query` against PostgreSQL.
- **Single Docker host**: All containers run on one machine. A real production deployment would spread nodes across separate hosts/availability zones.
- **Shared backup volume**: pgBackRest uses a shared Docker volume instead of a dedicated backup server. This means backups are local to the Docker host — not off-site. For production, configure a remote repository (S3, GCS, Azure, or SFTP).
- **Valkey is independent**: The Valkey cluster is not integrated with PostgreSQL — it's a standalone caching layer. Applications must handle cache invalidation.
- **Backup runs on any node**: The `manage.sh backup` command runs pgBackRest on the first available Patroni node. In production, you'd typically run backups from a dedicated standby or backup host.
