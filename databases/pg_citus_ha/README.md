# pg_citus_ha — Citus 14.0 Distributed PostgreSQL 18 Cluster with HA

A horizontally-sharded PostgreSQL 18 cluster using **Citus 14.0** for distributed queries, with coordinator high availability via streaming replication and automatic failover, plus a Valkey 9 caching layer. This is a fundamentally different architecture from the multi-master logical replication variants — Citus shards data across workers and routes queries through a single coordinator.

## Architecture

```
        VIP: 172.34.0.100
             |
   +---------+---------+
   |                   |
   v                   v
+------------------+ +---------------------+
| cit-coordinator  | | cit-coordinator-    |
| PG 18 + Citus 14 | | standby             |
| PRIMARY          | | HOT STANDBY         |
| port 5941 (ext)  | | port 5942 (ext)     |
| failover-monitor | | failover-monitor    |
+--------+---------+ +---------------------+
         |              (streaming replication)
         |
   +-----+------+
   |            |
+--+----------+ +--+----------+
| cit-worker1 | | cit-worker2 |
| PG 18+Citus | | PG 18+Citus |
| port 5943   | | port 5944   |
+-------------+ +-------------+

+-------------------------------------------+
|          Valkey 9 Caching Layer            |
|  master (6879) + 2 replicas + 3 sentinels |
+-------------------------------------------+
```

**Key concepts:**
- **Coordinator**: Single entry point for all queries. Routes distributed queries to workers.
- **Coordinator Standby**: Hot standby via physical streaming replication. Auto-promotes if primary fails.
- **VIP (172.34.0.100)**: Virtual IP that floats between coordinator and standby. Applications connect to the VIP.
- **Workers**: Hold the sharded data. Each worker has a subset of shards.
- **Distributed tables**: Sharded by a partition key (e.g., `user_id`). Data is split across workers.
- **Reference tables**: Small lookup tables replicated to all workers for local joins.
- **DDL propagation**: Schema changes on coordinator are automatically applied to all workers.

### Services (10 containers)

| Container | Role | External Port | IP |
|-----------|------|---------------|----|
| cit-coordinator | Citus coordinator (primary) | 5941 | 172.34.0.10 |
| cit-coordinator-standby | Coordinator hot standby | 5942 | 172.34.0.11 |
| cit-worker1 | Citus worker | 5943 | 172.34.0.21 |
| cit-worker2 | Citus worker | 5944 | 172.34.0.22 |
| cit-valkey-master | Cache master | 6879 | — |
| cit-valkey-replica1 | Cache replica | 6880 | — |
| cit-valkey-replica2 | Cache replica | 6881 | — |
| cit-valkey-sentinel1 | Sentinel | 26879 | — |
| cit-valkey-sentinel2 | Sentinel | 26880 | — |
| cit-valkey-sentinel3 | Sentinel | 26881 | — |

### Network

- Subnet: `172.34.0.0/16`
- VIP: `172.34.0.100` (floats between coordinator and standby)
- Internal auth: `trust` within subnet (required for Citus inter-node communication and replication)
- External auth: `scram-sha-256`

## Quick Start

```bash
# Start the cluster
docker compose up -d

# Wait ~60-90s for full initialization (pg_basebackup, cluster setup, monitors)
./scripts/manage.sh status

# Run integration tests (9 tests)
./scripts/manage.sh test

# Open psql to coordinator
./scripts/manage.sh psql

# Check failover monitor logs
./scripts/manage.sh logs monitor
```

## High Availability

### How It Works

1. **Streaming replication**: The standby continuously receives WAL from the primary coordinator via physical streaming replication with a dedicated replication slot (`coordinator_standby`).

2. **Failover monitor**: A shell script (`failover-monitor.sh`) runs on both coordinator nodes:
   - **Primary**: Assigns VIP to itself, periodically verifies VIP is still present.
   - **Standby**: Polls primary every 3 seconds via `pg_isready`. After 3 consecutive failures (~10-15s), triggers failover.

3. **Automatic failover sequence**:
   - Standby detects primary is unreachable (3 x 3s checks)
   - Assigns VIP (172.34.0.100) to itself via `ip addr add`
   - Sends gratuitous ARP to update network caches
   - Calls `pg_promote()` to exit recovery mode
   - Re-registers itself as Citus coordinator via `citus_set_coordinator_host()`
   - Enters maintenance mode (no preemption — stays primary)

4. **Total failover time**: ~15-20 seconds (detection + promotion)

### Failover Commands

```bash
# Coordinated failover: stops primary, waits for standby to auto-promote
./scripts/manage.sh failover

# Manual promote: when primary is already dead
./scripts/manage.sh promote

# Reinitialize cluster after failover (wipes all data, fresh start)
./scripts/manage.sh reinit
```

### VIP Access

The VIP (172.34.0.100) is only accessible within the Docker network. From the host, use the published ports:
- Primary coordinator: `localhost:5941`
- Standby coordinator: `localhost:5942`

Within the Docker network (e.g., from workers), the VIP works for automatic failover transparency.

### Keepalived Note

This cluster uses a shell-based failover monitor instead of keepalived because **keepalived's VRRP raw sockets fail under Rosetta 2 emulation** on Apple Silicon (`IP_FREEBIND` returns EBADF on emulated sockets). The keepalived config template is preserved at `keepalived/keepalived.conf.tmpl` for reference.

In production on **native Linux (x86_64 or ARM)**, switch to keepalived with VRRP unicast for:
- Faster failover (~3s vs ~15-20s)
- Split-brain protection via VRRP advertisement protocol
- Preemption support (automatic failback when original primary recovers)

## Management Commands

```
./scripts/manage.sh <command> [args...]

Info commands:
  status            Show cluster status (nodes, replication, VIP, monitors)
  topology          Show detailed Citus topology (nodes, tables, shards, replication)
  logs [target] [n] Show logs (coordinator|standby|worker1|worker2|valkey|setup|monitor)

Access commands:
  psql [target]     Open psql to coordinator|standby|worker1|worker2
  ddl "SQL"         Execute DDL on coordinator (auto-propagated to workers)

HA commands:
  failover          Coordinated failover: stop primary, standby auto-promotes
  promote           Manual promote: promote standby (use when primary is already dead)
  reinit            Reinitialize cluster (wipe all data, start fresh)

Test commands:
  test              Run integration tests (9 tests)
  bench [dur] [cli] Run pgbench benchmark (default: 10s, 8 clients)

  help              Show this help
```

## Working with Distributed Tables

All DDL goes through the coordinator and auto-propagates to workers:

```sql
-- Create and distribute a table by user_id
CREATE TABLE events (
    id bigint GENERATED ALWAYS AS IDENTITY,
    user_id bigint NOT NULL,
    event_type text,
    payload jsonb,
    created_at timestamptz DEFAULT now(),
    PRIMARY KEY (user_id, id)
);
SELECT create_distributed_table('events', 'user_id');

-- Create a reference table (replicated to all nodes, for JOINs)
CREATE TABLE event_types (
    code text PRIMARY KEY,
    label text
);
SELECT create_reference_table('event_types');

-- Queries go through coordinator — Citus routes to correct shard(s)
INSERT INTO events (user_id, event_type, payload)
VALUES (42, 'login', '{"ip": "1.2.3.4"}');

-- Single-shard query (fast — routed to one worker)
SELECT * FROM events WHERE user_id = 42;

-- Cross-shard query (scatter-gather — coordinator fans out to all workers)
SELECT user_id, count(*) FROM events GROUP BY user_id ORDER BY count DESC LIMIT 10;

-- ALTER TABLE propagates automatically
ALTER TABLE events ADD COLUMN region text;
```

## Configuration

Key Citus-specific settings in `postgresql.conf`:

| Parameter | Value | Reason |
|-----------|-------|--------|
| `shared_preload_libraries` | `citus` | Required for Citus |
| `citus.shard_count` | `8` | Reduced from default 32 for Rosetta performance |
| `shared_buffers` | `128MB` | Conservative for 1.9GB Docker VM with 4 PG instances |
| `statement_timeout` | `300s` | Extended for slow distributed ops under Rosetta |
| `max_connections` | `200` | Per node |
| `wal_level` | `logical` | Required for Citus + supports streaming replication |
| `max_wal_senders` | `10` | Supports replication connections |
| `hot_standby` | `on` | Allows read queries on standby |

## Benchmark Results

Benchmarked on Apple Silicon (M-series) running Citus `linux/amd64` image under **Rosetta 2 emulation**. Duration: 10s, 8 clients.

### Part 1: Standard pgbench TPC-B (apples-to-apples comparison)

| Metric | Citus (this cluster) | Multi-master variants |
|--------|---------------------|-----------------------|
| Write TPS (TPC-B) | **~12** | 4,200 - 5,640 |
| Read TPS (SELECT-only) | **~194** | 25,500 - 31,900 per node |

### Part 2: Citus-optimized single-shard operations

| Operation | TPS |
|-----------|-----|
| Single-shard INSERT | ~14 |
| Single-shard point READ | ~4 |
| Single-shard aggregation | ~2 |

### Why so slow?

The numbers are **100-1000x slower** than the multi-master variants. This is **not** a reflection of Citus performance in production. The causes:

1. **Rosetta 2 emulation**: The `citusdata/citus:latest` image is `linux/amd64` only. On Apple Silicon, every instruction runs through Rosetta 2 translation, adding massive overhead. Native x86_64 or native ARM builds would be dramatically faster.

2. **Distributed transaction overhead**: TPC-B updates multiple tables in one transaction. With distributed tables, this requires 2-phase commit (2PC) across workers — already slow, and made worse by Rosetta.

3. **Coordinator bottleneck**: All queries route through the coordinator. In the multi-master variants, each node handles queries independently.

4. **Memory constraints**: 128MB shared_buffers per node (vs typical 1-4GB in production) in a 1.9GB Docker VM.

### Expected production performance (native x86_64/ARM)

On native hardware with proper resources, Citus typically achieves:
- Single-shard operations: sub-millisecond latency, 10,000+ TPS per worker
- Cross-shard aggregations: scales near-linearly with worker count
- Real advantage shows at scale (10+ workers, TB+ data) where single-node PG can't keep up

## Citus vs Multi-Master: When to Use Which

| Criterion | Citus (sharding) | Multi-master (logical replication) |
|-----------|-------------------|------------------------------------|
| **Write scaling** | Horizontal (add workers) | Each node handles all writes |
| **Data model** | Must choose partition key | Any schema |
| **Cross-shard joins** | Slow (scatter-gather) | N/A (each node has all data) |
| **DDL changes** | Auto-propagated | Manual per-node or via tooling |
| **Data size** | Scales to TB+ | Limited by single-node capacity |
| **Complexity** | Partition key design is critical | Conflict resolution is critical |
| **Best for** | Large datasets, partition-friendly workloads | Small-medium datasets, any workload |

## Limitations

### Current

- **No worker HA**: If a worker dies, shards on that worker are unavailable. Worker standbys are deferred due to Docker VM memory constraints (~1.9GB total, already running 4 PG instances).
- **Rosetta 2 overhead**: Unusable performance on Apple Silicon due to x86_64 emulation. Citus does not publish ARM images.
- **No preemption/failback**: After failover, the old primary must be manually reinitialized. The shell-based monitor has no automatic failback.
- **No split-brain protection**: The shell-based failover monitor doesn't have VRRP's split-brain protection. If network partitions occur, both nodes could briefly claim the VIP.
- **VIP only works inside Docker network**: The VIP (172.34.0.100) is not accessible from the host. Docker only port-maps the container's primary IP. Use `localhost:5941`/`5942` from the host.
- **No `citus.shard_replication_factor`**: Default is 1 (no shard replication). Worker failure = data unavailable.

### Architectural

- **Partition key required**: You must choose a good distribution column. Wrong choice = hot spots or excessive cross-shard queries.
- **Cross-shard transactions are slow**: Any transaction touching multiple shards uses 2PC.
- **No multi-master writes**: Only the coordinator accepts distributed writes. Workers handle their local shards.
- **Coordinator bottleneck at scale**: All query routing goes through coordinator. Can be mitigated with read replicas but adds complexity.

## TODO

- [ ] Worker standbys via streaming replication (needs more memory — 2 more PG instances)
- [ ] `citus.shard_replication_factor = 2` for built-in shard HA
- [ ] Connection pooling via PgBouncer on the VIP
- [ ] Monitoring/alerting integration (Prometheus + pg_stat_monitor)

## File Structure

```
pg_citus_ha/
├── .env                              # Environment variables (passwords, ports, subnet)
├── docker-compose.yml                # 10 services: coord + standby + 2 workers + Valkey
├── README.md                         # This file
├── postgres/
│   ├── Dockerfile.coordinator        # Citus image + iproute2/arping/gosu for HA
│   ├── Dockerfile.worker             # Citus image (minimal)
│   ├── postgresql.conf               # Shared PG config (all nodes)
│   └── pg_hba.conf                   # Auth rules (trust for subnet + replication)
├── keepalived/
│   └── keepalived.conf.tmpl          # VRRP config template (reference only — not used)
├── valkey/
│   └── sentinel.conf                 # Sentinel config for Valkey HA
└── scripts/
    ├── manage.sh                     # Management CLI (status, test, failover, etc.)
    ├── coord-entrypoint.sh           # Primary coordinator init + cluster setup
    ├── coord-standby-entrypoint.sh   # Standby init (pg_basebackup) + failover monitor
    ├── failover-monitor.sh           # Shell-based VIP management + auto-promotion
    ├── worker-entrypoint.sh          # Worker init
    ├── setup-cluster.sh              # Registers coordinator and adds workers
    ├── pg-healthcheck.sh             # Docker healthcheck
    ├── keepalived-check.sh           # Keepalived check script (reference only)
    ├── keepalived-notify.sh          # Keepalived notify script (reference only)
    └── sentinel-entrypoint.sh        # Sentinel entrypoint
```

## Technical Notes

### Standby Process Management

The standby entrypoint uses `start-stop-daemon` (from Debian's dpkg) to launch the failover monitor as a properly double-forked daemon. This is necessary because PostgreSQL's postmaster kills all server processes and reinitializes when it detects an "untracked child process" exiting with a non-zero code. A simple `bash &` subshell gets reparented to the postgres process tree when the entrypoint shell exits, triggering this behavior. `start-stop-daemon` creates a process that is a direct child of PID 1 (tini), completely outside PostgreSQL's process tree.

### Memory Budget

| Component | Approx. Memory |
|-----------|---------------|
| Coordinator (primary) | ~389 MB |
| Coordinator (standby) | ~300 MB |
| Worker 1 | ~300 MB |
| Worker 2 | ~300 MB |
| Valkey (master + replicas) | ~42 MB |
| **Total** | **~1,330 MB** of 1,960 MB |

This leaves ~630 MB headroom. Not enough for worker standbys (would add ~600 MB for 2 more PG instances).

## Credentials (Development Only)

Defined in `.env`:
- PostgreSQL: `postgres` / `changeme_postgres_2025`
- Replication: `replicator` / `changeme_repl_2025`
- Valkey: `changeme_valkey_2025`
