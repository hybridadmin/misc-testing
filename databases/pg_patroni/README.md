# pg_patroni — PostgreSQL 18 HA with Patroni + pgBackRest

Production-ready PostgreSQL 18 high-availability cluster using Patroni for automatic failover, etcd for distributed consensus, HAProxy for traffic routing, PgBouncer for connection pooling, pgBackRest for backup and WAL archiving, and Valkey for caching.

## Architecture

```
Clients --> PgBouncer(:6432) --> HAProxy(:5050 RW, :5051 RO)
                                     |
          +-------------+------------+------------+
          |             |                         |
      patroni1      patroni2      patroni3    (PG 18 + Patroni + pgBackRest)
     :5432/:8008   :5432/:8008   :5432/:8008
          |             |                         |
     etcd1:2379    etcd2:2379    etcd3:2379   (DCS cluster)

+ Valkey 9 (1 master + 2 replicas + 3 sentinels)
```

**14 containers total**, all native ARM64 Docker images (no Rosetta 2 emulation).

### How It Works

1. **Patroni** manages PostgreSQL on each node — handles bootstrap, replication setup, leader election, and automatic failover via etcd.
2. **etcd** (3-node cluster) stores the cluster state and leader lock. Patroni nodes compete for the leader key; the winner becomes primary.
3. **HAProxy** checks the Patroni REST API on each node (`GET /primary` returns 200 on the leader, `GET /replica` returns 200 on standbys) and routes traffic accordingly.
4. **PgBouncer** provides connection pooling in `transaction` mode in front of HAProxy.
5. **pgBackRest** handles WAL archiving (`archive_command`), backup creation, and replica provisioning (`create_replica_methods: [pgbackrest, basebackup]`). All nodes share a single backup repository via a Docker volume — no SSH or TLS required.
6. **Valkey** provides an independent caching layer with its own HA (sentinel-managed failover).

### Replication

- **Synchronous replication** is enabled (`synchronous_mode: true` in Patroni DCS config).
- One standby is always the `sync_standby` (synchronous commit guaranteed), the other is `async`.
- This provides **RPO=0** (zero data loss) on failover — the sync standby is always up-to-date.
- `pg_rewind` is enabled, allowing former primaries to rejoin as replicas without a full base backup.

## Quick Start

```bash
# Start the cluster (first run builds the Patroni Docker image)
docker compose up -d

# Wait ~30s for all containers to become healthy, then check status
./scripts/manage.sh status

# Run integration tests (15 tests including pgBackRest verification)
./scripts/manage.sh test
```

## Connection Info

| Service | Host | Port | Description |
|---------|------|------|-------------|
| **PgBouncer** | localhost | 6432 | Pooled connections (recommended) |
| HAProxy RW | localhost | 5050 | Direct to primary |
| HAProxy RO | localhost | 5051 | Load-balanced replicas |
| HAProxy Stats | localhost | 7070 | Web UI at `/stats` |
| Node 1 direct | localhost | 6041 | Bypass HAProxy (debugging) |
| Node 2 direct | localhost | 6042 | Bypass HAProxy (debugging) |
| Node 3 direct | localhost | 6043 | Bypass HAProxy (debugging) |
| Patroni API 1 | localhost | 8041 | REST API |
| Patroni API 2 | localhost | 8042 | REST API |
| Patroni API 3 | localhost | 8043 | REST API |
| Valkey | localhost | 6999 | Cache master |
| Valkey Sentinel | localhost | 26999 | Sentinel (discovery) |

### Default Credentials

| User | Password | Purpose |
|------|----------|---------|
| postgres | `changeme_postgres_2025` | Superuser |
| replicator | `changeme_repl_2025` | Replication |
| Valkey | `changeme_valkey_2025` | Cache auth |

### Connection Examples

```bash
# Via PgBouncer (recommended — pooled)
PGPASSWORD=changeme_postgres_2025 psql -h localhost -p 6432 -U postgres -d appdb

# Via HAProxy RW (primary)
PGPASSWORD=changeme_postgres_2025 psql -h localhost -p 5050 -U postgres -d appdb

# Via HAProxy RO (replica)
PGPASSWORD=changeme_postgres_2025 psql -h localhost -p 5051 -U postgres -d appdb

# Direct to a specific node
PGPASSWORD=changeme_postgres_2025 psql -h localhost -p 6041 -U postgres -d appdb

# Or use manage.sh shortcuts
./scripts/manage.sh psql primary   # or: rw, p
./scripts/manage.sh psql replica   # or: ro, r
./scripts/manage.sh psql bouncer   # or: pgb, b
./scripts/manage.sh psql node1     # or: n1, 1
```

## manage.sh CLI Reference

```
Usage: ./scripts/manage.sh [command] [args...]

Info:
  status              Cluster health overview
  topology            Detailed replication/etcd topology
  logs [target]       Stream logs (all|patroni|etcd|haproxy|pgbouncer|valkey|sentinel|node1..3)

Access:
  psql [target]       Interactive psql (primary|replica|bouncer|node1..3)
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
  test                Run integration tests (15 tests)
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
| Stanza | `pg-patroni` | Matches Patroni scope |
| Repo type | POSIX (local) | Shared Docker volume at `/var/lib/pgbackrest` |
| Compression | lz4 (level 1) | Fast, low CPU; level 3 for archive-push |
| archive-async | yes | Non-blocking WAL archiving with spool |
| delta | yes | Only restore changed files |
| Retention (full) | 2 | Keep last 2 full backups |
| Retention (diff) | 3 | Keep last 3 differential backups |
| Retention (archive) | 2 | Archive retention anchored to full backups |
| process-max | 2 | Parallel processes for backup/restore |

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

If the primary dies, Patroni automatically promotes the sync_standby within ~30 seconds. HAProxy detects the change via REST API health checks and re-routes traffic. No manual intervention required.

To simulate:
```bash
# Kill the primary
docker kill pat-node1   # (or whichever is currently primary)

# Watch the failover (takes ~30s)
watch -n2 'curl -s http://localhost:8041/cluster 2>/dev/null | jq -r ".members[] | \"\(.name): \(.role) (\(.state))\""'

# The killed node will rejoin as a replica when restarted
docker start pat-node1
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

- **Subnet**: 172.35.0.0/16
- etcd nodes: 172.35.0.2-4
- Patroni/PG nodes: 172.35.0.10-12
- HAProxy: 172.35.0.20
- PgBouncer: 172.35.0.21
- Valkey: 172.35.0.30-35

All containers have static IPs to prevent Docker auto-assignment conflicts.

## Configuration

### PostgreSQL Parameters (via Patroni DCS)

Conservative settings for a Docker VM with ~1.9GB RAM:

| Parameter | Value | Notes |
|-----------|-------|-------|
| shared_buffers | 128MB | Per node (3 nodes sharing Docker VM) |
| effective_cache_size | 256MB | |
| work_mem | 4MB | |
| maintenance_work_mem | 64MB | |
| max_connections | 100 | Per node |
| synchronous_commit | on | RPO=0 |
| wal_level | replica | |
| max_wal_senders | 10 | |
| max_replication_slots | 10 | Managed by Patroni |

To modify parameters at runtime:
```bash
./scripts/manage.sh patronictl edit-config
```

### PgBouncer

- Pool mode: `transaction`
- Max client connections: 400
- Default pool size: 25

### HAProxy

- Primary backend (port 5050): Routes to the node where `GET /primary` returns 200
- Replica backend (port 5051): Routes (round-robin) to nodes where `GET /replica` returns 200

## File Structure

```
pg_patroni/
├── .env                          # All config variables
├── docker-compose.yml            # 14 services, YAML anchors
├── postgres/
│   ├── Dockerfile                # FROM postgres:18 + Patroni + pgBackRest
│   ├── patroni.yml               # Patroni config (templated)
│   └── pg_hba.conf               # Base HBA template
├── pgbackrest/
│   └── pgbackrest.conf           # pgBackRest config (stanza: pg-patroni)
├── haproxy/
│   └── haproxy.cfg               # RW/RO routing + stats
├── pgbouncer/
│   ├── pgbouncer.ini             # Transaction pooling config
│   └── userlist.txt              # Auth credentials
├── valkey/
│   └── sentinel.conf             # Sentinel monitor config
└── scripts/
    ├── manage.sh                 # CLI (status/test/bench/psql/backup/etc.)
    ├── patroni-entrypoint.sh     # pgBackRest dirs + templates patroni.yml + starts Patroni
    ├── pg-healthcheck.sh         # Patroni API + pg_isready check
    ├── post-bootstrap.sh         # Creates appdb, pgBackRest stanza + initial backup
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
- **Valkey is independent**: The Valkey cluster is not integrated with PostgreSQL — it's a standalone caching layer. Applications must handle cache invalidation.
- **appdb not auto-created on first boot**: The `post_bootstrap` script handles this, but only on the very first cluster initialization. If you `docker compose down -v` and start fresh, Patroni will run the post-bootstrap script again.
- **Shared backup volume**: pgBackRest uses a shared Docker volume instead of a dedicated backup server. This means backups are local to the Docker host — not off-site. For production, configure a remote repository (S3, GCS, Azure, or SFTP).
