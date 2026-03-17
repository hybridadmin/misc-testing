# PostgreSQL 18 High-Availability Cluster with pgBackRest

Production-ready PostgreSQL 18.3 cluster with automatic failover, load balancing,
distributed caching, and continuous backup/WAL archiving via pgBackRest.

## Architecture

```
                          Clients
                            |
                       +---------+
                       | HAProxy |
                       | LB      |
                       +---------+
                      /     |     \
               :5432 /   :5433|    \ :5434
             (write) /  (read)|     \(any)
                    /         |      \
          +--------+  +--------+  +--------+
          |pg-node1|  |pg-node2|  |pg-node3|
          |PRIMARY |  |SYNC    |  |SYNC    |
          |Patroni |  |REPLICA |  |REPLICA |
          |pgBackR.|  |pgBackR.|  |pgBackR.|
          +--------+  +--------+  +--------+
               \          |          /
            +------+  +------+  +------+
            |etcd1 |  |etcd2 |  |etcd3 |  (consensus)
            +------+  +------+  +------+

               +---------------------------+
               |  pgBackRest shared repo   |  (Docker volume)
               |  WAL archive + backups    |
               +---------------------------+

          +--------+  +--------+  +--------+
          |Valkey  |  |Valkey  |  |Valkey  |
          |Master  |  |Replica1|  |Replica2|  (cache)
          +--------+  +--------+  +--------+
               \          |          /
          +-----------+-----------+-----------+
          |Sentinel-1 |Sentinel-2 |Sentinel-3 |  (cache HA)
          +-----------+-----------+-----------+
```

## Components

| Component | Version | Count | Purpose |
|-----------|---------|-------|---------|
| PostgreSQL | 18.3 | 3 | Database (1 primary + 2 sync replicas) |
| Patroni | 4.0.x | 3 | Automatic failover & cluster management |
| etcd | 3.5.17 | 3 | Distributed consensus (leader election) |
| HAProxy | 3.1 | 1 | Load balancer & health-check routing |
| pgBackRest | 2.x | 3 | Backup & WAL archiving (co-installed in PG containers) |
| Valkey | 9.0.3 | 3 | Distributed cache (1 master + 2 replicas) |
| Valkey Sentinel | 9.0.3 | 3 | Cache automatic failover |

## Quick Start

### Prerequisites

- Docker Engine 24+ with Compose V2
- Minimum 4 GB RAM for development (16+ GB for production tuning)
- Minimum 2 CPU cores (4+ recommended)

### 1. Clone and Configure

```bash
# Review and modify passwords in .env
cp .env .env.backup
vim .env   # CHANGE ALL PASSWORDS before production use
```

### 2. Start the Cluster

```bash
docker compose up -d
```

First startup takes 1-2 minutes as Patroni bootstraps PostgreSQL and elects a
leader. Watch the logs:

```bash
docker compose logs -f pg-node1 pg-node2 pg-node3
```

Wait until you see Patroni report a leader elected:

```
pg-node1 | INFO: no action. I am (pg-node1), the leader with the lock
pg-node2 | INFO: no action. I am (pg-node2), a]secondary, and following a leader (pg-node1)
```

### 3. Verify Cluster Health

```bash
./scripts/manage.sh status

# Run integration tests (13 tests including pgBackRest verification)
./scripts/manage.sh test
```

### 4. Connect

```bash
# Write queries (routed to PRIMARY)
psql "host=localhost port=5432 user=postgres password=changeme_postgres_2025 dbname=appdb"

# Read queries (load-balanced across REPLICAS)
psql "host=localhost port=5433 user=postgres password=changeme_postgres_2025 dbname=appdb"

# Any healthy node
psql "host=localhost port=5434 user=postgres password=changeme_postgres_2025 dbname=appdb"
```

### 5. Connect to Valkey Cache

```bash
# Direct
valkey-cli -h localhost -p 6379 -a changeme_valkey_2025

# Via Docker
docker exec -it valkey-master valkey-cli -a changeme_valkey_2025 --no-auth-warning
```

## Port Map

| Port | Service | Description |
|------|---------|-------------|
| 5432 | HAProxy | **Write endpoint** -> PostgreSQL primary |
| 5433 | HAProxy | **Read endpoint** -> PostgreSQL replicas (load balanced) |
| 5434 | HAProxy | **Any healthy** -> Round-robin all healthy nodes |
| 7001 | HAProxy | Stats dashboard (http://localhost:7001/stats) |
| 5441-5443 | PostgreSQL | Direct node access (debugging only) |
| 8008-8010 | Patroni | REST API for each node |
| 6379 | Valkey | Cache master |
| 6380-6381 | Valkey | Cache replicas |
| 26379-26381 | Sentinel | Cache failover monitors |

## Management

### Cluster Management Script

```bash
# Full cluster status
./scripts/manage.sh status

# Manual failover (promote pg-node2)
./scripts/manage.sh failover pg-node2

# Reinitialize a failed node (wipes its data, re-syncs from primary)
./scripts/manage.sh reinit pg-node3

# Interactive psql to write endpoint
./scripts/manage.sh psql

# Interactive psql to read endpoint
./scripts/manage.sh psql 5433

# Valkey CLI
./scripts/manage.sh valkey-cli

# Tail all logs
./scripts/manage.sh logs

# Tail specific service
./scripts/manage.sh logs pg-node1

# Run pgbench benchmark
./scripts/manage.sh bench

# --- pgBackRest ---

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

### Patroni REST API

```bash
# Cluster state
curl -s http://localhost:8008/cluster | jq

# Current leader
curl -s http://localhost:8008/leader | jq

# Switchover (graceful)
curl -s -XPOST http://localhost:8008/switchover \
  -u patroni:changeme_patroni_2025 \
  -H "Content-Type: application/json" \
  -d '{"leader":"pg-node1","candidate":"pg-node2"}'

# Restart PostgreSQL on a node
curl -s -XPOST http://localhost:8008/restart \
  -u patroni:changeme_patroni_2025
```

### HAProxy Stats Dashboard

Open http://localhost:7001/stats in a browser.

- **Green** = healthy backend
- **Red** = backend down
- **Yellow** = backend in transition

Credentials: see `HAPROXY_STATS_USER` / `HAPROXY_STATS_PASSWORD` in `.env`

## How It Works

### Write Path

```
Client -> HAProxy:5432 -> pg-node (PRIMARY)
                          |
                          +--> synchronous replication to at least 1 replica
                          +--> commit acknowledged only after replica confirms
```

`synchronous_commit = on` with `synchronous_mode = true` guarantees **zero data
loss** on failover. A write is only acknowledged after at least one synchronous
replica has written it to WAL.

### Read Path

```
Client -> HAProxy:5433 -> pg-node2 or pg-node3 (REPLICAS, least-connections)
```

HAProxy health-checks each node's Patroni API (`GET /replica`). Only nodes
currently acting as replicas receive read traffic. If all replicas are down,
reads will have no available backend (this is intentional -- to avoid reading
stale data, use port 5434 if you want fallback to primary).

### Automatic Failover

1. Primary node dies
2. Patroni detects via heartbeat timeout (10s loop_wait + 30s TTL)
3. Patroni triggers leader election via etcd
4. Most up-to-date replica is promoted to primary
5. HAProxy detects via health check (3s interval, 3 failures = 9s)
6. **Total failover time: ~20-40 seconds**

### Caching Strategy

Valkey sits alongside PostgreSQL as a look-aside cache:

```
Application
    |
    +-- Cache HIT  --> Valkey (sub-millisecond)
    |
    +-- Cache MISS --> PostgreSQL --> write result to Valkey --> return
```

**Recommended caching patterns:**

| Pattern | Use Case | TTL |
|---------|----------|-----|
| Cache-aside | General queries | 60-300s |
| Write-through | Frequently read after write | 300-3600s |
| Cache invalidation | Data consistency critical | Event-driven |

**Valkey eviction policy: `allkeys-lfu`** (Least Frequently Used). This is
optimal for database caching because it keeps the most popular query results
cached and evicts rarely-accessed data.

### Valkey Sentinel Failover

If the Valkey master dies:

1. Sentinels detect master is unreachable (5s `down-after-milliseconds`)
2. Quorum of 2/3 sentinels agree master is down
3. One sentinel is elected to perform failover
4. Best replica is promoted to master
5. Other replicas reconfigure to follow new master
6. **Cache failover time: ~10-15 seconds**

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
| Stanza | `pg-patroni-hap` | Matches Patroni scope |
| Repo type | POSIX (local) | Shared Docker volume at `/var/lib/pgbackrest` |
| Compression | lz4 (level 1) | Fast, low CPU; level 3 for archive-push |
| archive-async | yes | Non-blocking WAL archiving with spool |
| delta | yes | Only restore changed files |
| Retention (full) | 2 | Keep last 2 full backups |
| Retention (diff) | 3 | Keep last 3 differential backups |
| Retention (archive) | 2 | Archive retention anchored to full backups |
| process-max | 2 | Parallel processes for backup/restore |

## Production Checklist

### Security

- [ ] Change ALL passwords in `.env` (every single one)
- [ ] Enable TLS for PostgreSQL connections (add SSL certs to Patroni config)
- [ ] Enable TLS for etcd peer/client communication
- [ ] Enable TLS for Valkey (`tls-port`, `tls-cert-file`, `tls-key-file`)
- [ ] Restrict HAProxy stats to internal network only
- [ ] Use Docker secrets instead of `.env` for passwords
- [ ] Set up firewall rules to restrict port access
- [ ] Enable `pg_hba.conf` IP whitelisting (currently allows `0.0.0.0/0`)

### Performance Tuning

- [ ] Adjust `shared_buffers` to 25% of available RAM per node (in `patroni_template.yml`)
- [ ] Adjust `effective_cache_size` to 75% of available RAM per node
- [ ] Adjust `max_connections` based on actual concurrency needs
- [ ] Increase `shm_size` in `docker-compose.yml` to match shared_buffers + overhead
- [ ] Set `VALKEY_MAXMEMORY` based on cache working set size
- [ ] Enable huge pages on host OS (`vm.nr_hugepages` in sysctl)
- [ ] Set `vm.overcommit_memory = 1` on host (for Valkey fork safety)
- [ ] Set `net.core.somaxconn = 65535` on host
- [ ] Set `vm.swappiness = 1` on host
- [ ] Mount data volumes on fast NVMe storage

### Monitoring

- [ ] Set up Prometheus + Grafana for metrics
- [ ] Monitor Patroni: `GET /metrics` on port 8008
- [ ] Monitor HAProxy: stats socket or `/stats` endpoint
- [ ] Monitor Valkey: `INFO` command metrics
- [ ] Set up alerting for: failover events, replication lag > 1MB, disk > 80%

### Backup

- [x] Configure pgBackRest for continuous WAL archiving (done)
- [x] Initial full backup created automatically on bootstrap (done)
- [ ] Set up automated scheduled backups (cron: daily diff, weekly full)
- [ ] Test restore procedure regularly
- [ ] Store backups in object storage (S3/GCS/MinIO) for production

### Host OS Sysctl (apply before production)

```bash
# /etc/sysctl.d/99-pg-cluster.conf
vm.overcommit_memory = 1
vm.swappiness = 1
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.core.netdev_max_backlog = 65535
# Huge pages (calculate: shared_buffers / 2MB hugepage size)
# For 2GB shared_buffers: 2048/2 = 1024 + 10% buffer = 1126
vm.nr_hugepages = 1126
```

Apply: `sysctl -p /etc/sysctl.d/99-pg-cluster.conf`

## Memory Requirements

The default configuration is tuned for development/testing on machines with 4-8 GB
RAM (256MB `shared_buffers` per node, 128MB Valkey). For production, scale up the
values in `patroni_template.yml` and `.env`:

| Component | Dev (default) | Production (example) | Count | Dev Total | Prod Total |
|-----------|--------------|---------------------|-------|-----------|------------|
| PostgreSQL | ~512 MB | ~3 GB | 3 | ~1.5 GB | ~9 GB |
| etcd | ~128 MB | ~256 MB | 3 | ~384 MB | ~768 MB |
| HAProxy | ~64 MB | ~128 MB | 1 | ~64 MB | ~128 MB |
| Valkey | ~128 MB | ~2 GB | 3 | ~384 MB | ~6 GB |
| Valkey Sentinel | ~32 MB | ~64 MB | 3 | ~96 MB | ~192 MB |
| **Total** | | | **16** | **~2.4 GB** | **~16 GB** |

## Scaling

### Adding More Read Replicas

1. Add a new `pg-node4` service to `docker-compose.yml` (copy `pg-node3` block)
2. Add `server pg-node4 pg-node4:5432 check port 8008` to `haproxy.cfg` backends
3. `docker compose up -d pg-node4` then `docker exec haproxy-pg kill -HUP 1`

### Scaling Valkey Cache

- **Vertical**: Increase `VALKEY_MAXMEMORY` in `.env`
- **Horizontal**: Add more Valkey replicas for read scaling
- **Sharding**: For cache sizes > 64GB, use Valkey Cluster mode (requires
  reconfiguration)

## Troubleshooting

### Patroni won't start / "etcd is not accessible"

```bash
# Check etcd health
docker exec etcd1 etcdctl endpoint health --cluster \
  --endpoints=http://etcd1:2379,http://etcd2:2379,http://etcd3:2379

# If etcd data is corrupted, reset:
docker compose down
docker volume rm pg-patroni-hap-cluster_etcd1-data pg-patroni-hap-cluster_etcd2-data pg-patroni-hap-cluster_etcd3-data
docker compose up -d
```

### Split-brain / multiple primaries

This should never happen with synchronous_mode + etcd consensus. If it does:

```bash
# Check who holds the leader lock
docker exec etcd1 etcdctl get /service/pg-patroni-hap/leader

# Force a specific node as leader
docker exec pg-node1 curl -s -XPATCH http://localhost:8008/config \
  -u patroni:changeme_patroni_2025 \
  -d '{"synchronous_mode": true}'
```

### Node stuck in "starting" state

```bash
# Check Patroni logs
docker logs pg-node1

# Force reinitialize (will re-clone from primary)
curl -s -XPOST http://localhost:8008/reinitialize \
  -u patroni:changeme_patroni_2025
```

### HAProxy shows all backends DOWN

```bash
# Verify Patroni API is responding
curl -s http://localhost:8008/patroni | jq
curl -s http://localhost:8009/patroni | jq
curl -s http://localhost:8010/patroni | jq

# Check HAProxy can reach Patroni
docker exec haproxy-pg wget -qO- http://pg-node1:8008/primary
```

### Replication lag is high

```bash
# Check lag on each replica
docker exec pg-node1 psql -U postgres -c \
  "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn,
   pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_lag_bytes
   FROM pg_stat_replication;"
```

## Tear Down

```bash
# Stop all containers (data preserved in volumes)
docker compose down

# Full reset (destroys ALL data)
docker compose down -v
```

## File Structure

```
pg_patroni_hap/
├── .env                          # Environment variables (passwords, versions)
├── docker-compose.yml            # Full cluster definition
├── patroni/
│   ├── Dockerfile                # PG18 + Patroni + pgBackRest image
│   └── patroni_template.yml      # Patroni configuration (incl. archive settings)
├── pgbackrest/
│   └── pgbackrest.conf           # pgBackRest configuration (stanza, retention, compression)
├── haproxy/
│   └── haproxy.cfg               # Load balancer configuration
├── valkey/
│   ├── valkey.conf               # Master configuration (reference)
│   ├── valkey-replica.conf       # Replica configuration (reference)
│   └── sentinel.conf             # Sentinel configuration
├── scripts/
│   ├── manage.sh                 # Cluster management CLI (incl. backup commands + tests)
│   ├── post-bootstrap.sh         # Stanza creation + initial full backup
│   ├── patroni-healthcheck.sh    # Docker health check
│   └── sentinel-entrypoint.sh    # Valkey Sentinel startup script
└── README.md                     # This file
```

## Why These Choices?

### HAProxy over PgBouncer (for this use case)

| Factor | HAProxy | PgBouncer |
|--------|---------|-----------|
| Health-check routing | Checks Patroni API, routes writes vs reads | No built-in health checks |
| Connection handling | 10k+ conn/s, event-driven C core | Connection pooling only |
| Read/write splitting | Native (separate frontends) | Requires external logic |
| Operational complexity | Single config file | Needs pairing with HAProxy anyway |
| Stats/monitoring | Built-in web dashboard | Basic `SHOW` commands |

PgBouncer excels at connection pooling (multiplexing 10k connections to 200 PG
backends). If you find you need both routing AND pooling, add PgBouncer between
HAProxy and PostgreSQL. For most workloads up to ~2000 actual concurrent queries,
HAProxy alone with tuned `max_connections` is sufficient.

### Valkey over Redis

- Valkey is the community fork under the Linux Foundation (BSD-3 license)
- Redis switched to RSALv2/SSPLv1 dual license (restricts cloud providers)
- API-compatible, same protocol, same client libraries
- Actively developed with performance improvements
- No licensing risk for any deployment model

### Patroni over manual replication

- Automatic failover without human intervention
- Consensus-based leader election (no split-brain)
- REST API for monitoring and management
- Handles replica re-cloning after failures
- Industry standard (used by GitLab, Zalando, many others)
