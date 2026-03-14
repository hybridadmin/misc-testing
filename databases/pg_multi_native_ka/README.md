# PostgreSQL 18 Multi-Master Cluster with Native Logical Replication + keepalived VIP

A true multi-master PostgreSQL 18 cluster using **native PG18 logical replication** (`CREATE PUBLICATION` / `CREATE SUBSCRIPTION` with `origin = none`) and **keepalived** for a floating Virtual IP (VIP) that provides automatic failover. No pglogical extension, no HAProxy.

## Architecture

```
                    ┌───────────────────────────────────────┐
                    │         keepalived VIP                 │
                    │         172.33.0.100                   │
                    │   (floats between nodes — 1 active)    │
                    └──────┬──────┬──────┬──────────────────┘
                           │      │      │
              ┌────────────┘      │      └────────────┐
              ▼                   ▼                    ▼
     ┌─────────────┐    ┌─────────────┐     ┌─────────────┐
     │  pg-node1   │◄──►│  pg-node2   │◄───►│  pg-node3   │
     │  :5841      │    │  :5842      │     │  :5843      │
     │ 172.33.0.11 │    │ 172.33.0.12 │     │ 172.33.0.13 │
     │  (writer)   │◄──►│  (writer)   │◄───►│  (writer)   │
     │ +keepalived │    │ +keepalived │     │ +keepalived │
     └─────────────┘    └─────────────┘     └─────────────┘
           Full-mesh native logical replication
           (origin=none prevents replication loops)

     ┌─────────────┐    ┌─────────────┐     ┌─────────────┐
     │   Valkey     │    │   Valkey     │     │   Valkey     │
     │   Master     │───►│   Replica1   │     │   Replica2   │
     │   :6779      │    │   :6780      │     │   :6781      │
     └─────────────┘    └─────────────┘     └─────────────┘
           │
     ┌─────┴──────────────┬───────────────────┐
     ▼                    ▼                   ▼
  Sentinel1 :26779   Sentinel2 :26780   Sentinel3 :26781
```

**9 services total:** 3 PostgreSQL nodes (with keepalived) + 1 Valkey master + 2 Valkey replicas + 3 Valkey Sentinels

## How It Works

### Native Logical Replication

Each node creates a `PUBLICATION ... FOR ALL TABLES` and subscribes to each peer's publication:

```
pg-node1 publishes:    pub_pg_node1
pg-node1 subscribes:   sub_pg_node2_to_pg_node1, sub_pg_node3_to_pg_node1
(same pattern for node2 and node3)
```

Key subscription options:
- `origin = none` — prevents replication loops (don't re-replicate data received from other nodes)
- `disable_on_error = true` — auto-disables subscription on conflict instead of crash-looping
- `streaming = parallel` — streams large in-progress transactions in parallel
- `copy_data = false` — nodes start in sync, no initial bulk copy

**No `shared_preload_libraries` needed** — native logical replication is built into PG18.

### keepalived VIP

Instead of HAProxy, **keepalived runs on each PG node** and manages a floating VIP. Only one node holds the VIP at any time.

1. All nodes start as `state BACKUP` with different priorities (node1=100, node2=95, node3=90)
2. The highest-priority healthy node wins the initial election and becomes MASTER
3. VRRP advertisements are sent every 1 second via **unicast** (Docker doesn't support multicast)
4. If the MASTER stops sending advertisements, the next-highest-priority BACKUP takes over within **1-3 seconds**
5. `nopreempt` is configured — once a BACKUP takes over, it keeps the VIP even if the original node recovers

### Health Check Integration

keepalived runs `/usr/local/bin/keepalived-check.sh` every 3 seconds, checking:

1. PostgreSQL is accepting connections
2. Subscriptions are set up (waits during startup)
3. Quorum: can reach a majority of peer nodes (2 of 3)
4. Native subscriptions are not all disabled/dead

If the check fails, keepalived lowers the node's VRRP priority, causing VIP failover. The same script also **self-fences** the node (`default_transaction_read_only = on`) so it cannot accept writes even on its direct port.

### Tradeoffs vs HAProxy Variants

| Aspect | HAProxy (pg_multi) | keepalived (this variant) |
|--------|-------------------|--------------------------|
| **Write distribution** | Round-robin across 3 nodes | Single node (VIP holder) |
| **Read distribution** | Least-connections across 3 nodes | Single node (VIP holder) |
| **Failover speed** | ~5s (agent-check interval) | **~1-3s** (VRRP advertisement) |
| **Services** | 10 (3 PG + 1 HAProxy + 6 Valkey) | **9** (3 PG + 6 Valkey) |
| **Stats dashboard** | HAProxy web UI | None |
| **Complexity** | Moderate (HAProxy config + agent) | **Simpler** (no extra service) |
| **Write scaling via LB** | 3x (all nodes accept writes) | **1x** (only VIP holder) |
| **Direct node access** | Yes (5441-5443) | Yes (5841-5843) |
| **Conflict resolution** | `disable_on_error` (manual) | `disable_on_error` (manual) |

**Key tradeoff:** You lose multi-master write distribution through the VIP. However, all nodes still accept writes on their direct ports (5841-5843), and native replication still replicates bidirectionally.

## Quick Start

```bash
cd pg_multi_native_ka

# Build and start the cluster
docker compose up -d --build

# Wait ~60s for replication setup and keepalived initialization
sleep 60

# Check cluster status (includes VIP holder info)
./scripts/manage.sh status

# Run the full replication test (DDL + DML + VIP check)
./scripts/manage.sh test
```

## DDL Management

**Native logical replication does NOT replicate DDL.** Use `manage.sh ddl` to execute DDL on all 3 nodes simultaneously, with canary testing on node1 first.

### Using the `ddl` command

```bash
# Create a table (executed on ALL 3 nodes, subscriptions refreshed automatically)
./scripts/manage.sh ddl "CREATE TABLE users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text, email text);"

# Alter a table
./scripts/manage.sh ddl "ALTER TABLE users ADD COLUMN created_at timestamptz DEFAULT now();"

# Drop a table
./scripts/manage.sh ddl "DROP TABLE IF EXISTS users;"

# From a SQL file
./scripts/manage.sh ddl -f my_migration.sql
```

### How `ddl` works

1. Executes the DDL on node1 first (canary test)
2. If node1 succeeds, applies to node2 and node3
3. If any node fails, reports which nodes succeeded/failed
4. If the DDL creates or drops tables, automatically refreshes subscriptions so replication picks up the new tables

### After DDL, subscriptions must know about new tables

When you `CREATE TABLE`, the subscriptions (which use `FOR ALL TABLES` publications) need to be told about the new table. The `ddl` command handles this automatically via `ALTER SUBSCRIPTION ... REFRESH PUBLICATION`. If you run DDL manually, call:

```bash
# Manually refresh subscriptions (manage.sh ddl does this automatically)
# Or just re-run: ./scripts/manage.sh ddl "SELECT 1;"  -- no-op DDL triggers refresh
```

## Conflict Handling

Native PG18 logical replication does **NOT** have built-in last-writer-wins conflict resolution (that's pglogical-only). Instead:

- `disable_on_error = true` — subscription auto-disables on conflict
- You must manually inspect and resolve via `manage.sh conflicts` and `manage.sh repair`
- **Prevention is the best strategy:** use `gen_random_uuid()` for PKs to eliminate INSERT/INSERT conflicts

### When conflicts happen

```bash
# Check for disabled subscriptions and conflict stats
./scripts/manage.sh conflicts

# Re-enable a disabled subscription (if you've resolved the conflict)
./scripts/manage.sh repair enable mmn-pg-node2

# Skip the errored transaction and re-enable
./scripts/manage.sh repair skip mmn-pg-node2

# Nuclear option: drop and recreate all subscriptions on a node
./scripts/manage.sh repair resync mmn-pg-node3
```

## Commands Reference

| Command | Description |
|---------|-------------|
| `status` | Cluster overview: nodes, subscriptions, keepalived VIP, Valkey |
| `vip` | Show keepalived VIP status (which node holds VIP) |
| `replication` | Detailed info: publications, subscriptions, connection strings |
| `test` | Full test: DDL on all nodes + DML replication + VIP check |
| `ddl "SQL"` | Execute DDL on ALL nodes (canary test on node1 first) |
| `ddl -f file.sql` | Execute DDL from file on ALL nodes |
| `conflicts` | Show conflict stats, disabled subs, worker status |
| `repair enable` | Re-enable all disabled subscriptions |
| `repair skip <node>` | Skip errored transaction and re-enable |
| `repair resync <node>` | Drop + recreate subscriptions (full resync) |
| `repair reset-stats` | Reset conflict counters to zero |
| `psql [port]` | Connect via psql (default: 5841) |
| `valkey-cli` | Connect to Valkey CLI |
| `logs [service]` | Tail Docker logs |
| `bench [scale]` | Run pgbench benchmark (default scale=10) |

## Ports

| Service | Port | Purpose |
|---------|------|---------|
| pg-node1 | 5841 | Direct access to node 1 |
| pg-node2 | 5842 | Direct access to node 2 |
| pg-node3 | 5843 | Direct access to node 3 |
| keepalived VIP | 172.33.0.100:5432 | Floating VIP (within Docker network) |
| Valkey Master | 6779 | Cache (master) |
| Valkey Replica 1 | 6780 | Cache (replica) |
| Valkey Replica 2 | 6781 | Cache (replica) |
| Sentinel 1/2/3 | 26779-26781 | Valkey high-availability |

### Connecting to the VIP

The VIP (`172.33.0.100`) lives on the Docker bridge network.

**From within Docker (other containers on the same network):**
```bash
psql -h 172.33.0.100 -p 5432 -U postgres -d appdb
```

**From the host (via direct node ports):**
```bash
# Connect to whichever node you want (all accept writes)
psql -h localhost -p 5841 -U postgres -d appdb

# Or use manage.sh
./scripts/manage.sh psql 5841
```

For most development workflows, using the direct node ports (5841-5843) is simpler. The VIP is primarily useful for applications running inside Docker that need a single connection endpoint.

## Network

Uses subnet `172.33.0.0/16` to avoid conflicts with:
- `pg/` (172.28.0.0/16)
- `pg_multi/` (172.29.0.0/16)
- `pg_multi_flyway/` (172.30.0.0/16)
- `pg_multi_pglogical/` (172.31.0.0/16)
- `pg_multi_pglogical_ka/` (172.32.0.0/16)

All containers use the `mmn-` prefix (e.g., `mmn-pg-node1`, `mmn-valkey-master`).

### Static IPs (required for keepalived unicast)

| Container | IP |
|-----------|-----|
| pg-node1 | 172.33.0.11 |
| pg-node2 | 172.33.0.12 |
| pg-node3 | 172.33.0.13 |
| VIP | 172.33.0.100 |

## Split-Brain Protection

### Implemented mitigations

#### 1. Quorum-aware self-fencing

The keepalived health check script runs every 3 seconds and doubles as the self-fencing watchdog. With 3 nodes, majority = 2 (self + at least 1 peer).

If a node cannot reach enough peers:
- Self-fences: `default_transaction_read_only = on`
- keepalived lowers VRRP priority, causing VIP migration
- The fenced node cannot accept writes even on its direct port

#### 2. Self-fencing on subscription failure

If ALL native subscriptions are disabled or have no active workers (and maintenance mode is not active), the node self-fences.

#### 3. Auto-unfencing on recovery

When quorum is restored and subscriptions recover, the node automatically unfences.

#### 4. Maintenance mode

Touch `/tmp/native_maintenance` inside a container to skip fencing checks during intentional operations (benchmarks, bulk loads). The `bench` command handles this automatically.

### Scenario: VIP holder loses network

| Time | Event |
|------|-------|
| T+0 | Node1 (VIP holder) disconnected from network |
| T+1-3s | VRRP timeout — node2 or node3 takes over VIP |
| T+3-6s | keepalived-check.sh on node1 detects no quorum, self-fences |
| T+3-6s | Any write on node1 (direct port 5841) returns: `ERROR: read-only transaction` |
| — | Nodes 2 & 3 continue normally; VIP points to healthy node |
| T+reconnect | Node1 rejoins network |
| T+reconnect+3-6s | Health check passes, unfences node1 |
| T+reconnect+6s+ | Replication catches up |

### Testing VIP failover

```bash
# 1. Check which node holds VIP
./scripts/manage.sh vip

# 2. Stop the VIP holder (e.g., node1)
docker stop mmn-pg-node1

# 3. Wait 3-5s, check VIP moved
sleep 5
./scripts/manage.sh vip

# 4. Restart node1
docker start mmn-pg-node1

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
| **No last-writer-wins** | Native replication disables on conflict, requires manual repair | pglogical variant has automatic LWW |
| **Application-level conflicts** | Logically conflicting changes (e.g., overdrawing) not prevented | Application-level optimistic locking |

## Limitations

### 1. DDL does NOT replicate

Must use `manage.sh ddl` to execute DDL on all nodes. Plain `CREATE TABLE` only affects the node you're connected to.

### 2. No last-writer-wins conflict resolution

Unlike pglogical, native logical replication has no built-in `last_update_wins`. Conflicts cause the subscription to disable. Use UUID primary keys to prevent most conflicts.

### 3. Subscription refresh needed after DDL

After creating new tables, subscriptions must be refreshed to learn about them. `manage.sh ddl` handles this automatically.

### 4. VIP only accessible within Docker network

The VIP (`172.33.0.100`) is on the Docker bridge network. From the host, use direct ports (5841-5843). In production on real VMs, the VIP would be on the LAN.

### 5. Active/passive — no write scaling via VIP

Only one node holds the VIP. Applications connecting to the VIP get single-node write throughput. For multi-node writes, connect to individual nodes directly.

### 6. No automatic INSERT/INSERT conflict resolution

Using UUID primary keys (`gen_random_uuid()`) effectively eliminates this.

## Best Practices

1. **Always use `gen_random_uuid()` for primary keys** — eliminates INSERT/INSERT conflicts
2. **Always use `manage.sh ddl` for schema changes** — ensures DDL is applied to all nodes
3. **Avoid concurrent updates to the same row on different nodes** — native replication has no LWW
4. **Monitor conflicts regularly** — `manage.sh conflicts`
5. **Use additive DDL** — prefer `ADD COLUMN` over `DROP COLUMN`
6. **Use `IF NOT EXISTS` / `IF EXISTS`** — makes DDL idempotent and re-runnable

## Comparison: All Multi-Master Variants

| Feature | pg_multi (native) | pg_multi_flyway | pg_multi_pglogical | pg_multi_pglogical_ka | **pg_multi_native_ka** |
|---------|-------------------|-----------------|--------------------|-----------------------|----------------------|
| Replication | Native PG18 | Native PG18 | pglogical | pglogical | **Native PG18** |
| DDL approach | Manual each node | Flyway per node | `replicate_ddl_command()` | `replicate_ddl_command()` | **Manual each node** |
| Conflict resolution | disable_on_error | disable_on_error | Last-writer-wins | Last-writer-wins | **disable_on_error** |
| Load balancer | HAProxy | HAProxy | HAProxy | keepalived VIP | **keepalived VIP** |
| Write distribution | All nodes (HAProxy) | All nodes (HAProxy) | All nodes (HAProxy) | Single node (VIP) | **Single node (VIP)** |
| Failover speed | ~5s | ~5s | ~5s | ~1-3s | **~1-3s** |
| Services | 10 | 11 (+ Flyway) | 10 | 9 | **9** |
| Container prefix | `mm-` | `mmf-` | `mmp-` | `mmk-` | **`mmn-`** |
| PG direct ports | 5441-5443 | 5541-5543 | 5641-5643 | 5741-5743 | **5841-5843** |
| Extensions needed | None | None | pglogical | pglogical | **None** |
| Subnet | 172.29.0.0/16 | 172.30.0.0/16 | 172.31.0.0/16 | 172.32.0.0/16 | **172.33.0.0/16** |

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
docker exec mmn-pg-node1 cat /tmp/keepalived.log

# View replication setup logs
docker exec mmn-pg-node1 cat /tmp/repl-setup.log

# View PostgreSQL logs
./scripts/manage.sh logs pg-node1

# Check keepalived config
docker exec mmn-pg-node1 cat /etc/keepalived/keepalived.conf

# Re-enable disabled subscriptions
./scripts/manage.sh repair enable

# Skip errored transaction on a node
./scripts/manage.sh repair skip mmn-pg-node2

# Full resync of a node
./scripts/manage.sh repair resync mmn-pg-node3

# Connect directly to a node
./scripts/manage.sh psql 5841
```

## Teardown

```bash
# Stop the cluster (preserves data volumes)
docker compose down

# Stop and destroy all data
docker compose down -v
```

## Benchmark Results

pgbench, scale=10, Docker Desktop (Apple Silicon, ~2GB RAM limit)

### Write Performance (TPC-B, 10 clients, 30s)

| Node | TPS | Avg Latency | Transactions |
|------|-----|-------------|-------------|
| mmn-pg-node1 | 5,590 | 1.789ms | 167,647 |
| mmn-pg-node2 | 5,640 | 1.773ms | 169,088 |
| mmn-pg-node3 | 4,229 | 2.365ms | 126,740 |

### Read Performance (SELECT-only, 20 clients, 30s)

| Node | TPS | Avg Latency | Transactions |
|------|-----|-------------|-------------|
| mmn-pg-node1 | 31,918 | 0.627ms | 953,488 |
| mmn-pg-node2 | 25,542 | 0.783ms | 764,733 |
| mmn-pg-node3 | 26,770 | 0.747ms | 800,489 |

**Note:** Benchmarks run with subscriptions disabled (independent pgbench per node). These numbers reflect raw PG performance without replication overhead. Real multi-master write throughput will be slightly lower due to WAL shipping.
