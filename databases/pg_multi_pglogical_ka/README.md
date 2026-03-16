# PostgreSQL 18 Multi-Master Cluster with pglogical + keepalived VIP

A true multi-master PostgreSQL 18 cluster using the **pglogical** extension for logical replication with DDL replication support, and **keepalived** for a floating Virtual IP (VIP) that provides automatic failover without HAProxy.

## Architecture

```
                    ┌───────────────────────────────────────┐
                    │         keepalived VIP                 │
                    │         172.32.0.100                   │
                    │   (floats between nodes — 1 active)    │
                    └──────┬──────┬──────┬──────────────────┘
                           │      │      │
              ┌────────────┘      │      └────────────┐
              ▼                   ▼                    ▼
     ┌─────────────┐    ┌─────────────┐     ┌─────────────┐
     │  pg-node1   │◄──►│  pg-node2   │◄───►│  pg-node3   │
     │  :5741      │    │  :5742      │     │  :5743      │
     │ 172.32.0.11 │    │ 172.32.0.12 │     │ 172.32.0.13 │
     │  (writer)   │◄──►│  (writer)   │◄───►│  (writer)   │
     │ +keepalived │    │ +keepalived │     │ +keepalived │
     └─────────────┘    └─────────────┘     └─────────────┘
           Full-mesh pglogical replication
           (forward_origins='{}' prevents loops)

     ┌─────────────┐    ┌─────────────┐     ┌─────────────┐
     │   Valkey     │    │   Valkey     │     │   Valkey     │
     │   Master     │───►│   Replica1   │     │   Replica2   │
     │   :6679      │    │   :6680      │     │   :6681      │
     └─────────────┘    └─────────────┘     └─────────────┘
           │
     ┌─────┴──────────────┬───────────────────┐
     ▼                    ▼                   ▼
  Sentinel1 :26679   Sentinel2 :26680   Sentinel3 :26681
```

**9 services total:** 3 PostgreSQL nodes (with keepalived) + 1 Valkey master + 2 Valkey replicas + 3 Valkey Sentinels

## How keepalived VIP Works

Instead of HAProxy sitting in front of the PG nodes, **keepalived runs on each PG node** and manages a floating Virtual IP address (VIP). Only one node holds the VIP at any time.

### VRRP Protocol

keepalived uses the **VRRP (Virtual Router Redundancy Protocol)** to elect which node holds the VIP:

1. All nodes start as `state BACKUP` with different **priorities** (node1=100, node2=95, node3=90)
2. The highest-priority healthy node wins the initial election and becomes MASTER, adding the VIP to its network interface
3. VRRP advertisements are sent every 1 second via **unicast** (Docker doesn't support multicast)
4. If the MASTER stops sending advertisements (crash, network partition), the next-highest-priority BACKUP takes over within **1-3 seconds**
5. `nopreempt` is configured — once a BACKUP takes over, it keeps the VIP even if the original higher-priority node recovers (prevents VIP flapping). This requires all nodes to use `state BACKUP` in the keepalived config; using `state MASTER` disables `nopreempt`.

### Health Check Integration

keepalived runs `/usr/local/bin/keepalived-check.sh` every 3 seconds. This script checks:

1. PostgreSQL is accepting connections
2. pglogical extension is loaded
3. Quorum: can reach a majority of peer nodes
4. pglogical subscriptions are not all down

If the check fails, keepalived reduces the node's VRRP priority by 30 points, causing VIP failover to a healthier node. The same script also performs **self-fencing** (`default_transaction_read_only = on`) — identical behavior to the HAProxy variant's watchdog.

### Tradeoffs vs HAProxy

| Aspect | HAProxy (pglogical variant) | keepalived (this variant) |
|--------|---------------------------|--------------------------|
| **Write distribution** | Round-robin across all 3 nodes | Single node (VIP holder only) |
| **Read distribution** | Least-connections across all 3 nodes | Single node (VIP holder only) |
| **Failover speed** | ~5s (agent-check interval) | **~1-3s** (VRRP advertisement) |
| **Services** | 10 (3 PG + 1 HAProxy + 6 Valkey) | **9** (3 PG + 6 Valkey) |
| **Stats dashboard** | HAProxy web UI (:7200) | None |
| **Complexity** | Moderate (HAProxy config + agent) | **Simpler** (no extra service) |
| **Write scaling** | 3x (all nodes accept writes) | **1x** (only VIP holder) |
| **Direct node access** | Yes (5641-5643) | Yes (5741-5743) |

**Key tradeoff:** You lose multi-master write distribution through the VIP. The VIP only points to one node at a time. However, all nodes still accept writes on their direct ports (5741-5743), and pglogical still replicates bidirectionally. The VIP is a convenience for applications that want a single connection endpoint.

## Quick Start

```bash
cd pg_multi_pglogical_ka

# Build and start the cluster
docker compose up -d --build

# Wait ~60s for pglogical nodes, subscriptions, and keepalived to initialize
sleep 60

# Check cluster status (includes VIP holder info)
./scripts/manage.sh status

# Run the full replication test (DDL + DML + VIP check)
./scripts/manage.sh test
```

## DDL Replication

Same as the pglogical variant — DDL is replicated using `replicate_ddl_command()`.

### Using the `ddl` command

```bash
# Create a table — runs on node1, replicates to all peers
./scripts/manage.sh ddl "CREATE TABLE public.users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text, email text); SELECT pglogical.replication_set_add_table('default', 'public.users', true);"

# Alter a table
./scripts/manage.sh ddl "ALTER TABLE public.users ADD COLUMN created_at timestamptz DEFAULT now();"

# Drop a table (CASCADE needed for replication set membership)
./scripts/manage.sh ddl "DROP TABLE public.users CASCADE;"

# From a SQL file (provide your own)
./scripts/manage.sh ddl -f my_migration.sql
```

### Critical details

- **Schema qualification required:** Use `public.tablename`, not `tablename`
- **Replication set membership:** Include `pglogical.replication_set_add_table('default', 'public.tablename', true);` when creating tables
- **DROP TABLE needs CASCADE:** Replication set membership creates a dependency

## Conflict Resolution

pglogical supports true **last-writer-wins** using `track_commit_timestamp`:

```
pglogical.conflict_resolution = 'last_update_wins'
```

When two nodes update the same row concurrently, the later commit timestamp wins. Conflicts are logged at `WARNING` level.

## Commands Reference

| Command | Description |
|---------|-------------|
| `status` | Cluster overview: nodes, pglogical, keepalived VIP, Valkey |
| `vip` | Show keepalived VIP status (which node holds VIP) |
| `replication` | Detailed pglogical info: nodes, subscriptions, replication sets |
| `test` | Full test: DDL + DML replication + VIP connectivity |
| `ddl "SQL"` | Execute DDL via `pglogical.replicate_ddl_command()` |
| `ddl -f file.sql` | Execute DDL from file |
| `conflicts` | Show subscription statuses, conflict resolution mode, lag |
| `repair enable` | Re-enable all disabled pglogical subscriptions |
| `repair resync <node>` | Drop + recreate subscriptions on a node |
| `psql [port]` | Connect via psql (5741-5743=direct) |
| `valkey-cli` | Connect to Valkey CLI |
| `logs [service]` | Tail Docker logs |
| `bench [scale]` | Run pgbench benchmark (default scale=10) |

## Ports

| Service | Port | Purpose |
|---------|------|---------|
| pg-node1 | 5741 | Direct access to node 1 |
| pg-node2 | 5742 | Direct access to node 2 |
| pg-node3 | 5743 | Direct access to node 3 |
| keepalived VIP | 172.32.0.100:5432 | Floating VIP (within Docker network) |
| Valkey Master | 6679 | Cache (master) |
| Valkey Replica 1 | 6680 | Cache (replica) |
| Valkey Replica 2 | 6681 | Cache (replica) |
| Sentinel 1/2/3 | 26679-26681 | Valkey high-availability |

### Connecting to the VIP

The VIP (`172.32.0.100`) lives on the Docker bridge network. To connect:

**From within Docker (other containers on the same network):**
```bash
psql -h 172.32.0.100 -p 5432 -U postgres -d appdb
```

**From the host (via direct node ports):**
```bash
# Connect to whichever node you want (all accept writes)
psql -h localhost -p 5741 -U postgres -d appdb

# Or use manage.sh
./scripts/manage.sh psql 5741
```

**From the host (via VIP — requires route):**
The VIP is on the Docker internal network. To reach it from the host, you may need to add a route:
```bash
# macOS (Docker Desktop uses a VM, so this may not work directly)
# Linux: sudo ip route add 172.32.0.100/32 via <docker-bridge-gateway>
```

For most development workflows, using the direct node ports (5741-5743) is simpler.

## Network

Uses subnet `172.32.0.0/16` to avoid conflicts with:
- `pg_patroni_hap/` (172.28.0.0/16) — single-writer Patroni cluster
- `pg_multi_native_hap/` (172.29.0.0/16) — native logical replication multi-master
- `pg_multi_native_flyway/` (172.30.0.0/16) — Flyway DDL management multi-master
- `pg_multi_pglogical/` (172.31.0.0/16) — pglogical with HAProxy

All containers use the `mmk-` prefix (e.g., `mmk-pg-node1`, `mmk-valkey-master`).

### Static IPs (required for keepalived unicast)

| Container | IP |
|-----------|-----|
| pg-node1 | 172.32.0.11 |
| pg-node2 | 172.32.0.12 |
| pg-node3 | 172.32.0.13 |
| VIP | 172.32.0.100 |

## Split-Brain Protection

Same as the pglogical variant — pglogical has **zero built-in split-brain protection**. This cluster implements the same mitigations.

### Implemented mitigations

#### 1. Conflict logging at WARNING level

`pglogical.conflict_log_level` is set to `warning` (default is `log`).

#### 2. Quorum-aware self-fencing

The keepalived health check script (`keepalived-check.sh`) runs every 3 seconds and serves as **both** the VRRP health check **and** the self-fencing watchdog. With 3 nodes, majority = 2 (self + at least 1 peer).

If a node cannot reach enough peers:
- Self-fences: `default_transaction_read_only = on`
- keepalived lowers VRRP priority, causing VIP migration to a healthy node
- The fenced node cannot accept writes even on its direct port (5741-5743)

#### 3. Self-fencing on total subscription loss

If ALL pglogical subscriptions are down, the node self-fences.

#### 4. Auto-unfencing on recovery

When quorum is restored and subscriptions recover, the watchdog automatically unfences the node.

### Scenario: VIP holder loses network

| Time | Event |
|------|-------|
| T+0 | Node1 (VIP holder) disconnected from network |
| T+1-3s | VRRP timeout — node2 or node3 takes over VIP |
| T+3-6s | keepalived-check.sh on node1 detects no quorum, self-fences |
| T+3-6s | Any write on node1 (direct port 5741) returns: `ERROR: read-only transaction` |
| — | Nodes 2 & 3 continue normally; VIP points to healthy node |
| T+reconnect | Node1 rejoins network |
| T+reconnect+3-6s | Health check passes, unfences node1 |
| T+reconnect+3-6s | pglogical catches up — rows written during partition replicate |

### Testing VIP failover

```bash
# 1. Check which node holds VIP
./scripts/manage.sh vip

# 2. Stop the VIP holder (e.g., node1)
docker stop mmk-pg-node1

# 3. Wait 3-5s, check VIP moved
sleep 5
./scripts/manage.sh vip

# 4. Restart node1
docker start mmk-pg-node1

# 5. Wait for recovery, check status
sleep 30
./scripts/manage.sh status
```

### What is NOT protected (known gaps)

| Gap | Description | Possible future mitigation |
|-----|-------------|---------------------------|
| **Brief write window** | Writes accepted in the ~3-6s before health check detects partition | Synchronous commit to at least one peer |
| **No write scaling via VIP** | VIP points to one node — only 1x write throughput via VIP | Use direct node ports for multi-node writes |
| **Symmetric partition** | All 3 nodes isolated from each other → all self-fence → read-only | External arbiter |
| **Clock skew** | `last_update_wins` depends on timestamps — NTP desync affects winner | Tight NTP tolerance |
| **Application-level conflicts** | Logically conflicting changes (e.g., overdrawing) not prevented | Application-level optimistic locking |

## How pglogical Replication Works

### Node and subscription model

Each node registers as a pglogical node and creates subscriptions to each peer:

```
pg_node1 subscribes to: pg_node2, pg_node3
pg_node2 subscribes to: pg_node1, pg_node3
pg_node3 subscribes to: pg_node1, pg_node2
```

### Preventing replication loops

Each subscription uses `forward_origins = '{}'` — nodes only replicate locally-originated changes.

### Replication sets

- `default` — standard tables (INSERT/UPDATE/DELETE)
- `default_insert_only` — INSERT-only tables
- `ddl_sql` — DDL commands from `replicate_ddl_command()`

### Startup sequence

1. Each node starts PostgreSQL with `shared_preload_libraries = 'pglogical'`
2. Init script creates replication user and application database
3. Background process waits for all peers
4. Subscriptions are staggered by node number to avoid slot creation conflicts
5. keepalived starts after a 30s delay (waits for replication setup)
6. VIP is assigned to the highest-priority healthy node

## Limitations

### 1. DDL replication is explicit, not automatic

Must use `manage.sh ddl` or `pglogical.replicate_ddl_command()`. Plain DDL does NOT replicate.

### 2. DDL must use schema-qualified names

`replicate_ddl_command()` runs with empty `search_path`:
```sql
-- Correct:
SELECT pglogical.replicate_ddl_command($DDL$ CREATE TABLE public.users (...); $DDL$);

-- Wrong:
SELECT pglogical.replicate_ddl_command($DDL$ CREATE TABLE users (...); $DDL$);
```

### 3. New tables must be added to replication sets

Include `replication_set_add_table` in the same `replicate_ddl_command()` call.

### 4. DROP TABLE needs CASCADE

Tables in replication sets have a dependency on set membership.

### 5. VIP only accessible within Docker network

The VIP (`172.32.0.100`) is on the Docker bridge network. From the host, use direct ports (5741-5743) instead. This is a development/testing cluster limitation; in production (real VMs), the VIP would be on the LAN.

### 6. Active/passive — no write scaling via VIP

Only one node holds the VIP. Applications connecting to the VIP get single-node write throughput. For multi-node writes, connect to individual nodes directly.

### 7. pglogical 2.4.6 on PG18 is community-supported

The `postgresql-18-pglogical` package is from Debian Trixie repos, not officially supported by 2ndQuadrant/EDB.

### 8. No automatic INSERT/INSERT conflict resolution

Using UUID primary keys (`gen_random_uuid()`) effectively eliminates this.

## Best Practices

1. **Always use `gen_random_uuid()` for primary keys** — eliminates INSERT/INSERT conflicts
2. **Always use `manage.sh ddl` for schema changes** — ensures DDL replicates
3. **Always use schema-qualified names** — `public.tablename`
4. **Include `replication_set_add_table()` when creating tables**
5. **Use CASCADE when dropping tables**
6. **Avoid concurrent updates to the same row on different nodes**
7. **Monitor conflicts regularly** — `manage.sh conflicts`
8. **Use additive DDL** — prefer `ADD COLUMN` over `DROP COLUMN`

## Comparison: All Multi-Master Variants

| Feature | pg_multi_native_hap (native) | pg_multi_native_flyway | pg_multi_pglogical | pg_multi_pglogical_ka |
|---------|-------------------|-----------------|--------------------|-----------------------|
| DDL approach | Manual each node | Flyway per node | `replicate_ddl_command()` | `replicate_ddl_command()` |
| Conflict resolution | None (error) | None (error) | Last-writer-wins | **Last-writer-wins** |
| Load balancer | HAProxy | HAProxy | HAProxy | **keepalived VIP** |
| Write distribution | All nodes (HAProxy) | All nodes (HAProxy) | All nodes (HAProxy) | **Single node (VIP)** |
| Failover speed | ~5s | ~5s | ~5s | **~1-3s** |
| Services | 10 | 11 (+ Flyway) | 10 | **9** |
| Container prefix | `mm-` | `mmf-` | `mmp-` | **`mmk-`** |
| PG direct ports | 5441-5443 | 5541-5543 | 5641-5643 | **5741-5743** |
| LB/VIP ports | 5432/5433 | 5532/5533 | 5632/5633 | **VIP:5432** |

## Troubleshooting

```bash
# Check cluster status (includes VIP info)
./scripts/manage.sh status

# Check which node holds the VIP
./scripts/manage.sh vip

# Detailed replication info
./scripts/manage.sh replication

# Check for conflicts or disabled subscriptions
./scripts/manage.sh conflicts

# View keepalived logs inside a container
docker exec mmk-pg-node1 cat /tmp/keepalived.log

# View replication setup logs
docker exec mmk-pg-node1 cat /tmp/repl-setup.log

# View PostgreSQL logs
./scripts/manage.sh logs pg-node1

# Check keepalived config
docker exec mmk-pg-node1 cat /etc/keepalived/keepalived.conf

# Re-enable disabled subscriptions
./scripts/manage.sh repair enable

# Full resync of a node
./scripts/manage.sh repair resync mmk-pg-node3

# Connect directly to a node
./scripts/manage.sh psql 5741
```

## Teardown

```bash
# Stop the cluster (preserves data volumes)
docker compose down

# Stop and destroy all data
docker compose down -v
```

## Benchmark Results

pgbench, scale=10 (1M rows), 30-second runs. Subscriptions disabled during benchmark (independent data per node). Docker Desktop on macOS with ~2GB RAM constraint.

### Write (TPC-B, 10 clients, 4 threads)

| Node | TPS | Avg Latency |
|------|-----|-------------|
| node1 | 4,938 | 2.03 ms |
| node2 | 6,164 | 1.62 ms |
| node3 | 6,218 | 1.61 ms |

### Read (SELECT-only, 20 clients, 4 threads)

| Node | TPS | Avg Latency |
|------|-----|-------------|
| node1 | 47,461 | 0.42 ms |
| node2 | 32,293 | 0.62 ms |
| node3 | 33,656 | 0.59 ms |

Performance is comparable to the HAProxy variant — the keepalived VIP adds no measurable overhead since it's just an IP alias on the network interface.
