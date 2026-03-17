# PostgreSQL 18 High-Availability Cluster with Patroni Raft + keepalived VIP + pgBackRest

Production-ready PostgreSQL 18.3 cluster with automatic failover via a floating
virtual IP (keepalived VRRP), distributed caching, and continuous backup/WAL
archiving via pgBackRest.

**This project uses Patroni's built-in Raft consensus (`pysyncobj`).** It does
NOT require external DCS services like etcd or Consul, resulting in a simpler,
fully self-contained 3-node architecture.

## Architecture

```
                          Clients
                            |
                     +-------------+
                     | Floating VIP|
                     | 172.31.0.100|  (keepalived VRRP)
                     +-------------+
                            |
                        :5432 (write + read)
                            |
                   .--------+--------.
                  /         |         \
          +--------+  +--------+  +--------+
          |pg-node1|  |pg-node2|  |pg-node3|     only the current PRIMARY
          |Patroni |  |Patroni |  |Patroni |     holds the VIP
          | (Raft) |  | (Raft) |  | (Raft) |  <-- built-in consensus
          |keepalvd|  |keepalvd|  |keepalvd|
          |pgBackR.|  |pgBackR.|  |pgBackR.|
          +--------+  +--------+  +--------+

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

### Why Raft instead of etcd?

Patroni supports native Raft consensus (`pysyncobj`), meaning the 3 Patroni
nodes vote among themselves to elect a leader.
- **Pros**: Reduces cluster size by 3 containers. Less moving parts. No need
  to maintain a separate etcd/Consul cluster.
- **Cons**: Tighter coupling. If you need to restart the entire database engine,
  you also restart the consensus mechanism.

### How the VIP Works

Each PostgreSQL container runs keepalived as a background daemon alongside
Patroni. keepalived uses VRRP unicast mode on the Docker bridge network:

1. Every 3 seconds, each node's `keepalived-check.sh` queries the local Patroni
   REST API at `/primary`
2. Only the current Patroni leader returns HTTP 200 on `/primary`
3. If the check fails (node is a replica or Patroni/PG is down), keepalived
   forces the node into the `FAULT` state, immediately dropping the VIP
4. The healthy node with the highest VRRP priority claims the VIP (`172.31.0.100`)
5. On failover, Patroni promotes a new leader -> its check script starts
   returning 200 -> keepalived migrates the VIP instantly

## Components

| Component | Version | Count | Purpose |
|-----------|---------|-------|---------|
| PostgreSQL | 18.3 | 3 | Database (1 primary + 1 sync + 1 async replica) |
| Patroni | 4.0.x | 3 | Automatic failover & built-in Raft consensus |
| keepalived | 2.3.x | 3 | Floating VIP via VRRP (co-installed in PG containers) |
| pgBackRest | 2.x | 3 | Backup & WAL archiving (co-installed in PG containers) |
| Valkey | 9.x | 3 | Distributed cache (1 master + 2 replicas) |
| Valkey Sentinel | 9.x | 3 | Cache automatic failover |

**9 containers total** (vs 12-15 in other variants with external DCS/load balancers).

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

Wait until you see Patroni report a leader elected and keepalived acquire the
VIP:

```
pg-node1 | INFO: no action. I am (pg-node1), the leader with the lock
pg-node1 | === [keepalived] Starting keepalived daemon ===
```

### 3. Verify Cluster Health

```bash
./scripts/manage.sh status

# Run integration tests (13 tests including pgBackRest + VIP verification)
./scripts/manage.sh test
```

### 4. Connect

```bash
# Direct to individual nodes (primary varies — check ./scripts/manage.sh status)
psql "host=localhost port=5471 user=postgres password=changeme_postgres_2025 dbname=appdb"
psql "host=localhost port=5472 user=postgres password=changeme_postgres_2025 dbname=appdb"
psql "host=localhost port=5473 user=postgres password=changeme_postgres_2025 dbname=appdb"

# Via VIP (Docker-internal only — use from another container on the same network)
# The VIP (172.31.0.100) is a Docker bridge IP, not accessible from macOS host
./scripts/manage.sh psql vip
```

> **Note**: The keepalived VIP (`172.31.0.100`) is only routable within the
> Docker bridge network. From the host, use the direct node ports (5471-5473)
> and determine the primary via `./scripts/manage.sh status` or the Patroni API.

### 5. Connect to Valkey Cache

```bash
# Direct
valkey-cli -h localhost -p 6392 -a changeme_valkey_2025

# Via Docker
docker exec -it prf-valkey-master valkey-cli -a changeme_valkey_2025 --no-auth-warning
```

## Port Map

| Port | Service | Description |
|------|---------|-------------|
| 5471 | PostgreSQL | Direct access to pg-node1 |
| 5472 | PostgreSQL | Direct access to pg-node2 |
| 5473 | PostgreSQL | Direct access to pg-node3 |
| 8031 | Patroni | REST API for pg-node1 |
| 8032 | Patroni | REST API for pg-node2 |
| 8033 | Patroni | REST API for pg-node3 |
| 8009 | Raft | Internal Patroni consensus (internal only) |
| 6392 | Valkey | Cache master |
| 6393-6394 | Valkey | Cache replicas |
| 26392-26394 | Sentinel | Cache failover monitors |
| *(internal)* | keepalived | VIP 172.31.0.100 on Docker bridge |

## Management

### Cluster Management Script

```bash
# Full cluster status (Patroni topology, VIP location, pgBackRest info)
./scripts/manage.sh status

# Detailed topology (all nodes with roles + replication info)
./scripts/manage.sh topology

# Manual failover (promote pg-node2)
./scripts/manage.sh failover pg-node2

# Graceful switchover
./scripts/manage.sh switchover pg-node2

# Reinitialize a failed node (wipes its data, re-syncs from primary)
./scripts/manage.sh reinit pg-node3

# Interactive psql to primary
./scripts/manage.sh psql primary

# Interactive psql via VIP (from inside Docker network)
./scripts/manage.sh psql vip

# Interactive psql to specific node
./scripts/manage.sh psql node1

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
# Cluster state (use any node's API port)
curl -s http://localhost:8031/cluster | jq

# Check which node is leader
curl -s http://localhost:8031/leader | jq

# Switchover (graceful)
curl -s -XPOST http://localhost:8031/switchover \
  -u patroni:changeme_patroni_2025 \
  -H "Content-Type: application/json" \
  -d '{"leader":"pg-node3","candidate":"pg-node1"}'

# Restart PostgreSQL on a node
curl -s -XPOST http://localhost:8031/restart \
  -u patroni:changeme_patroni_2025
```

## How It Works

### Write Path

```
Client -> VIP:5432 -> pg-node (PRIMARY)
                      |
                      +--> synchronous replication to at least 1 replica
                      +--> commit acknowledged only after replica confirms
```

`synchronous_commit = on` with `synchronous_mode = true` guarantees **zero data
loss** on failover. A write is only acknowledged after at least one synchronous
replica has written it to WAL.

### Automatic Failover

1. Primary node dies
2. Patroni detects via heartbeat timeout (10s loop_wait + 30s TTL)
3. Patroni triggers leader election via Raft
4. Most up-to-date replica is promoted to primary
5. New primary's keepalived check starts returning 200
6. keepalived migrates VIP to new primary (~3-5 seconds)
7. **Total failover time: ~25-45 seconds** (Patroni election + VIP migration)

### keepalived VRRP Details

| Setting | Value | Notes |
|---------|-------|-------|
| VRRP Instance | `VIP_PG` | Single VRRP group for all 3 nodes |
| Virtual Router ID | 54 | Avoids conflicts with other keepalived projects |
| VIP Address | 172.31.0.100 | On `172.31.0.0/16` Docker bridge |
| Initial State | BACKUP (all nodes) | Required for `nopreempt` mode |
| Priority | node1=100, node2=95, node3=90 | Highest healthy priority wins |
| Check Script | `/primary` API poll | If fails, node drops to FAULT state |
| Check Interval | 3 seconds | VIP transitions quickly |
| Mode | Unicast | Docker bridges don't support multicast |

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

**Valkey eviction policy: `allkeys-lfu`** (Least Frequently Used). Optimal for
database caching -- keeps the most popular query results cached and evicts
rarely-accessed data.

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

pgBackRest is co-installed in each Patroni/PostgreSQL container. All 3 nodes
share a single backup repository via a Docker volume mounted at
`/var/lib/pgbackrest` -- no SSH or TLS needed.

- **WAL archiving**: PostgreSQL's `archive_command` pushes WAL segments to
  pgBackRest asynchronously (`archive-async=y`, `lz4` compression).
- **Stanza auto-creation**: The `post-bootstrap.sh` script creates the
  pgBackRest stanza and kicks off an initial full backup after Patroni
  bootstraps the cluster.
- **Replica provisioning**: New replicas try `pgbackrest --delta restore` first,
  falling back to `pg_basebackup` if no backup is available.

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
| Stanza | `pg-patroni-raft` | Matches Patroni scope |
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
- [ ] Enable TLS for Valkey (`tls-port`, `tls-cert-file`, `tls-key-file`)
- [ ] Use Docker secrets instead of `.env` for passwords
- [ ] Set up firewall rules to restrict port access
- [ ] Enable `pg_hba.conf` IP whitelisting (currently allows `0.0.0.0/0`)
- [ ] In production, use a real network (not Docker bridge) for VRRP

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
- [ ] Monitor Valkey: `INFO` command metrics
- [ ] Set up alerting for: failover events, replication lag > 1MB, disk > 80%
- [ ] Monitor keepalived VIP transitions (check `/tmp/keepalived.log` in containers)

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
| PostgreSQL + keepalived | ~512 MB | ~3 GB | 3 | ~1.5 GB | ~9 GB |
| Valkey | ~128 MB | ~2 GB | 3 | ~384 MB | ~6 GB |
| Valkey Sentinel | ~32 MB | ~64 MB | 3 | ~96 MB | ~192 MB |
| **Total** | | | **9** | **~2.0 GB** | **~15 GB** |

## Troubleshooting

### VIP not reachable / VIP on wrong node

```bash
# Check which node holds the VIP
for n in prf-pg-node1 prf-pg-node2 prf-pg-node3; do
  echo -n "$n: "
  docker exec $n ip addr show eth0 | grep "172.31.0.100" && echo "HAS VIP" || echo "no VIP"
done

# Check keepalived logs inside a container
docker exec prf-pg-node1 cat /tmp/keepalived.log

# Verify the check script returns correct status
docker exec prf-pg-node1 /usr/local/bin/keepalived-check.sh && echo "OK (is primary)" || echo "FAIL (not primary)"
```

### Split-brain / multiple primaries

This should never happen with synchronous_mode + Raft consensus. If it does:

```bash
# Check Patroni topology
docker exec prf-pg-node1 patronictl -c /etc/patroni/patroni.yml list

# Force a specific node as leader
docker exec prf-pg-node1 curl -s -XPATCH http://localhost:8008/config \
  -u patroni:changeme_patroni_2025 \
  -d '{"synchronous_mode": true}'
```

### Node stuck in "starting" state

```bash
# Check Patroni logs
docker logs prf-pg-node1

# Force reinitialize (will re-clone from primary)
curl -s -XPOST http://localhost:8031/reinitialize \
  -u patroni:changeme_patroni_2025
```

### Replication lag is high

```bash
# Check lag on each replica
docker exec prf-pg-node1 psql -U postgres -c \
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
