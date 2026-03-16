# PostgreSQL 18 Multi-Master Cluster with pglogical

A true multi-master PostgreSQL 18 cluster using the **pglogical** extension for logical replication with DDL replication support via `replicate_ddl_command()`, Docker Compose orchestration, and last-writer-wins conflict resolution.

## Architecture

```
                    ┌─────────────────────────────┐
                    │          HAProxy             │
                    │   Write :5632 (round-robin)  │
                    │   Read  :5633 (leastconn)    │
                    │   Stats :7200                │
                    └──────┬──────┬──────┬─────────┘
                           │      │      │
              ┌────────────┘      │      └────────────┐
              ▼                   ▼                    ▼
     ┌─────────────┐    ┌─────────────┐     ┌─────────────┐
     │  pg-node1   │◄──►│  pg-node2   │◄───►│  pg-node3   │
     │  :5641      │    │  :5642      │     │  :5643      │
     │  (writer)   │◄──►│  (writer)   │◄───►│  (writer)   │
     └─────────────┘    └─────────────┘     └─────────────┘
           Full-mesh pglogical replication
           (forward_origins='{}' prevents loops)

     ┌─────────────┐    ┌─────────────┐     ┌─────────────┐
     │   Valkey     │    │   Valkey     │     │   Valkey     │
     │   Master     │───►│   Replica1   │     │   Replica2   │
     │   :6579      │    │   :6580      │     │   :6581      │
     └─────────────┘    └─────────────┘     └─────────────┘
           │
     ┌─────┴──────────────┬───────────────────┐
     ▼                    ▼                   ▼
  Sentinel1 :26579   Sentinel2 :26580   Sentinel3 :26581
```

**10 services total:** 3 PostgreSQL nodes + 1 HAProxy + 1 Valkey master + 2 Valkey replicas + 3 Valkey Sentinels

## Key Advantages Over Native Logical Replication

| Feature | Native (pg_multi_native_hap) | pglogical (this cluster) |
|---------|-------------------|--------------------------|
| DDL replication | Not supported — must run DDL on each node manually | `replicate_ddl_command()` runs DDL once, propagates to all peers |
| Conflict resolution | None — apply errors crash the subscription worker | **Last-writer-wins** using real commit timestamps (`track_commit_timestamp`) |
| Replication sets | One publication per node | Named sets (`default`, `default_insert_only`, `ddl_sql`) |
| Table management | `FOR ALL TABLES` (cannot exclude individual tables) | Tables added to replication sets explicitly or via defaults |

## Quick Start

```bash
cd pg_multi_pglogical

# Build and start the cluster
docker compose up -d --build

# Wait ~60s for pglogical nodes and subscriptions to initialize
# (subscriptions are staggered by node number to avoid slot creation conflicts)
sleep 60

# Check cluster status
./scripts/manage.sh status

# Run the full replication test (DDL + DML + ALTER TABLE)
./scripts/manage.sh test
```

## DDL Replication

This is the primary feature of this cluster variant. DDL is replicated using pglogical's `replicate_ddl_command()` function.

### Using the `ddl` command

```bash
# Create a table — runs on node1, automatically replicates to node2 and node3
# IMPORTANT: Always use schema-qualified names (public.tablename)
# For CREATE TABLE, also add to the replication set so DML replicates:
./scripts/manage.sh ddl "CREATE TABLE public.users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL, email text); SELECT pglogical.replication_set_add_table('default', 'public.users', true);"

# Alter a table — same mechanism
./scripts/manage.sh ddl "ALTER TABLE public.users ADD COLUMN created_at timestamptz DEFAULT now();"

# Drop a table — needs CASCADE because of replication set membership
./scripts/manage.sh ddl "DROP TABLE public.users CASCADE;"

# From a SQL file (provide your own)
./scripts/manage.sh ddl -f my_migration.sql
```

### How it works

1. `manage.sh ddl` connects to **node1** only
2. It wraps the DDL in `SELECT pglogical.replicate_ddl_command('...');`
3. pglogical executes the DDL locally on node1
4. The DDL statement is replicated to all subscribers via the `ddl_sql` replication set
5. Each subscriber executes the DDL locally

### Critical details

- **Schema qualification required:** `replicate_ddl_command()` runs with an empty `search_path`. All table references must use explicit schema (e.g., `public.users` not `users`).
- **Replication set membership:** Creating a table via `replicate_ddl_command()` does **not** automatically add it to a replication set. You must include `SELECT pglogical.replication_set_add_table('default', 'public.tablename', true);` in the same `replicate_ddl_command()` call. This executes on all nodes, so the table is immediately ready for DML replication everywhere.
- **DROP TABLE needs CASCADE:** Tables in a replication set have a dependency on their replication set membership. Use `DROP TABLE public.tablename CASCADE;`.

### What `replicate_ddl_command()` can do

- `CREATE TABLE`, `ALTER TABLE`, `DROP TABLE`
- `CREATE INDEX`, `DROP INDEX`
- `CREATE SEQUENCE`, `ALTER SEQUENCE`
- Any DDL that PostgreSQL supports

### What it cannot do

- It is **not automatic** — you must explicitly wrap DDL in the function call (or use `manage.sh ddl`)
- The `pgl_ddl_deploy` extension (which provides automatic DDL capture via event triggers) is **not available for PostgreSQL 18** — only packages up to PG17 exist
- Complex DDL involving multiple statements may need to be wrapped in a single call

## Conflict Resolution

pglogical supports true **last-writer-wins** conflict resolution using PostgreSQL's `track_commit_timestamp` feature. This compares actual commit timestamps rather than arrival order.

### Configured mode: `last_update_wins`

```
pglogical.conflict_resolution = 'last_update_wins'
```

When two nodes update the same row concurrently:
1. Both changes replicate to the other node
2. pglogical compares the `commit_timestamp` of each transaction
3. The later timestamp wins — the earlier change is silently discarded
4. Conflicts are logged at `WARNING` level (`pglogical.conflict_log_level = 'warning'`)

### Available conflict resolution modes

| Mode | Behavior |
|------|----------|
| `last_update_wins` | Later commit timestamp wins (recommended for multi-master) |
| `first_update_wins` | Earlier commit timestamp wins |
| `apply_remote` | Always apply the incoming change |
| `keep_local` | Always keep the local version |
| `error` | Raise an error (breaks replication — not recommended) |

### Checking for conflicts

```bash
# View subscription status and conflict info
./scripts/manage.sh conflicts

# Check Docker logs for conflict messages
docker logs mmp-pg-node1 2>&1 | grep -i conflict
```

## Commands Reference

| Command | Description |
|---------|-------------|
| `status` | Cluster overview: node health, pglogical subscriptions, conflict resolution mode |
| `replication` | Detailed pglogical info: node interfaces, subscriptions, replication sets |
| `test` | Integration tests: replication + pgBackRest (13 tests) |
| `test-multimaster` | Detailed multi-master replication test (DDL + DML + HAProxy) |
| `ddl "SQL"` | Execute DDL via `pglogical.replicate_ddl_command()` — replicates to all nodes |
| `ddl -f file.sql` | Execute DDL from a file |
| `conflicts` | Show subscription statuses, conflict resolution mode, replication lag |
| `repair enable` | Re-enable all disabled pglogical subscriptions |
| `repair enable <node>` | Re-enable subscriptions on a specific node |
| `repair resync <node>` | Drop + recreate all subscriptions on a node (full resync) |
| `psql [port]` | Connect via psql (5632=write, 5633=read, 5641-5643=direct) |
| `valkey-cli` | Connect to Valkey CLI |
| `logs [service]` | Tail Docker logs |
| `bench [scale]` | Run pgbench benchmark (default scale=10) |
| `backup [type] [node]` | Run pgBackRest backup (full/diff/incr, default: full all) |
| `backup-info [node]` | Show pgBackRest backup info (default: all nodes) |
| `backup-check [node]` | Verify pgBackRest stanza + WAL archiving |

## Ports

| Service | Port | Purpose |
|---------|------|---------|
| HAProxy Write | 5632 | Round-robin writes to all PG nodes |
| HAProxy Read | 5633 | Least-connections reads from all PG nodes |
| HAProxy Stats | 7200 | Web dashboard (`admin`/`changeme_haproxy_2025`) |
| pg-node1 | 5641 | Direct access to node 1 |
| pg-node2 | 5642 | Direct access to node 2 |
| pg-node3 | 5643 | Direct access to node 3 |
| Valkey Master | 6579 | Cache (master) |
| Valkey Replica 1 | 6580 | Cache (replica) |
| Valkey Replica 2 | 6581 | Cache (replica) |
| Sentinel 1/2/3 | 26579-26581 | Valkey high-availability |

## Network

Uses subnet `172.31.0.0/16` to avoid conflicts with:
- `pg_patroni_hap/` (172.28.0.0/16) — single-writer Patroni cluster
- `pg_multi_native_hap/` (172.29.0.0/16) — native logical replication multi-master
- `pg_multi_native_flyway/` (172.30.0.0/16) — Flyway DDL management multi-master

All containers use the `mmp-` prefix (e.g., `mmp-pg-node1`, `mmp-valkey-master`).

## Benchmark Results

Tested on Docker Desktop (Apple Silicon) with ~2GB RAM, pgbench scale=10 (1M rows), 30s per test.
Benchmarks run with subscriptions disabled (each node tested independently):

| Metric | Per Node (avg) | Aggregate (3 nodes) |
|--------|---------------|---------------------|
| Write TPS | ~6,841 | ~20,523 |
| Read TPS | ~54,730 | ~164,190 |
| Failed txns | 0 | 0 |
| Write nodes | All 3 | All 3 |

For comparison with the other multi-master variants:

| Metric | pg_multi_native_hap (native) | pg_multi_pglogical |
|--------|-------------------|-------------------|
| Write TPS (per node) | ~6,167 | ~6,841 |
| Read TPS (per node) | ~37,829 | ~54,730 |

> **Note**: Benchmark numbers are raw per-node performance with replication disabled.
> Under normal operation with replication enabled, effective throughput is lower due to
> WAL shipping overhead. The `bench` command disables subscriptions because pgbench's
> TPC-B workload would cause conflicts across nodes. The `bench` command automatically
> enters maintenance mode to prevent the self-fencing watchdog from triggering while
> subscriptions are disabled.

## How pglogical Replication Works

### Node and subscription model

Each PostgreSQL instance registers itself as a **pglogical node** with a unique name (`pg_node1`, `pg_node2`, `pg_node3`). Nodes create **subscriptions** to each peer, forming a full-mesh topology:

```
pg_node1 subscribes to: pg_node2, pg_node3
pg_node2 subscribes to: pg_node1, pg_node3
pg_node3 subscribes to: pg_node1, pg_node2
```

### Preventing replication loops

Each subscription uses `forward_origins = '{}'` — this means a node will only replicate changes that **originated locally**, never forwarding changes received from other nodes. This is pglogical's equivalent of native logical replication's `origin = none`.

### Replication sets

Subscriptions subscribe to three replication sets:
- `default` — standard tables (INSERT/UPDATE/DELETE replicated)
- `default_insert_only` — tables where only INSERTs replicate
- `ddl_sql` — carries DDL commands from `replicate_ddl_command()`

### Startup sequence

1. Each node starts PostgreSQL with `shared_preload_libraries = 'pglogical'`
2. The init script creates the replication user and application database
3. A background process waits for all peers to be ready
4. Subscription creation is **staggered** by node number (node1 waits 20s, node2 waits 25s, node3 waits 30s) to avoid simultaneous `CREATE_REPLICATION_SLOT` crashes
5. Each node creates its pglogical node identity, then subscribes to each peer

## Limitations

### 1. DDL replication is explicit, not automatic

You must use `manage.sh ddl` or call `pglogical.replicate_ddl_command()` directly. If you run plain DDL (`CREATE TABLE ...`) without the wrapper, it will NOT replicate.

The `pgl_ddl_deploy` extension (which captures DDL automatically via event triggers) is not packaged for PostgreSQL 18 — only PG17 and earlier.

### 2. DDL must use schema-qualified names

`replicate_ddl_command()` executes DDL in a context where `search_path` is empty. All table references must use explicit schema qualification:

```sql
-- Correct:
SELECT pglogical.replicate_ddl_command($DDL$ CREATE TABLE public.users (...); $DDL$);

-- Wrong (fails with "no schema has been selected to create in"):
SELECT pglogical.replicate_ddl_command($DDL$ CREATE TABLE users (...); $DDL$);
```

### 3. New tables must be explicitly added to replication sets

`replicate_ddl_command()` creates the table on all nodes but does NOT add it to any replication set. Without replication set membership, DML (INSERT/UPDATE/DELETE) will not replicate.

The solution: include `replication_set_add_table` in the same `replicate_ddl_command()` call:

```sql
SELECT pglogical.replicate_ddl_command($DDL$
    CREATE TABLE public.my_table (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text);
    SELECT pglogical.replication_set_add_table('default', 'public.my_table', true);
$DDL$);
```

This executes on all nodes simultaneously, so the table is immediately ready for bidirectional DML replication.

### 4. DROP TABLE needs CASCADE

Tables in a replication set have a dependency on their set membership. Use `DROP TABLE public.tablename CASCADE;` to drop them.

### 5. pglogical 2.4.6 on PG18 is community-supported

The `postgresql-18-pglogical` package is available from Debian Trixie repos. It is not officially supported by the pglogical commercial team (2ndQuadrant/EDB) for PG18.

### 6. No automatic conflict resolution for INSERT/INSERT conflicts

`last_update_wins` resolves UPDATE/UPDATE and UPDATE/DELETE conflicts. For INSERT/INSERT conflicts (two nodes insert a row with the same primary key), the behavior depends on the conflict resolution mode. Using UUID primary keys (`gen_random_uuid()`) effectively eliminates INSERT/INSERT conflicts.

### 7. Schema must exist before data replication

If a table exists on node1 but not node2, replication of data to that table on node2 will fail. Always use `replicate_ddl_command()` to ensure schema consistency.

### 8. No built-in monitoring dashboard

pglogical exposes status via SQL functions (`pglogical.show_subscription_status()`) but doesn't provide a web UI. Use `manage.sh status` and `manage.sh conflicts` for monitoring.

## Best Practices

1. **Always use `gen_random_uuid()` for primary keys** — eliminates INSERT/INSERT conflicts
2. **Always use `manage.sh ddl` for schema changes** — ensures DDL replicates to all nodes
3. **Always use schema-qualified names** in DDL — `public.tablename`, not just `tablename`
4. **Include `replication_set_add_table()` when creating tables** — otherwise DML won't replicate
5. **Use CASCADE when dropping tables** — replication set membership creates a dependency
6. **Avoid concurrent updates to the same row on different nodes** — even with last-writer-wins, one update will be silently lost
7. **Monitor conflicts regularly** — `manage.sh conflicts` and Docker logs
8. **Use additive DDL** — prefer `ADD COLUMN` over `DROP COLUMN`; dropping columns while replication is active can cause errors

## Split-Brain Protection

pglogical has **zero built-in split-brain protection**. There is no quorum, no fencing, and no partition-awareness — a partitioned node continues accepting writes, which leads to divergent data that must be manually reconciled. This cluster implements several mitigations.

### Implemented mitigations

#### 1. Conflict logging at WARNING level

`pglogical.conflict_log_level` is set to `warning` (default is `log`) so conflicts are harder to miss in logs and monitoring.

#### 2. Quorum-aware self-fencing (watchdog)

Each node runs a background watchdog (every 10s) that checks TCP reachability to all peer nodes. With 3 nodes, **majority = 2** (self + at least 1 peer). If a node cannot reach enough peers to form a majority, it **self-fences**:

- Sets `default_transaction_read_only = on` via `ALTER SYSTEM` — blocks all writes, even on direct-access ports (5641-5643)
- Creates `/tmp/pglogical_fenced` with the reason
- Reports `down` to HAProxy (removes from load balancer pool)

The watchdog runs independently of HAProxy polling, so a partitioned node will self-fence even when HAProxy cannot reach it.

#### 3. Self-fencing on total subscription loss

If ALL pglogical subscriptions on a node are `down` (not `replicating`, `initializing`, or `copying`), the node self-fences with the same mechanism as above — even if TCP peer checks pass.

#### 4. Auto-unfencing on recovery

When quorum is restored AND subscriptions recover to a healthy state, the watchdog automatically:

- Runs `ALTER SYSTEM RESET default_transaction_read_only`
- Reloads the PostgreSQL configuration
- Removes the fence file
- Reports `ready up 100%` to HAProxy on the next agent-check

**Recovery is fully automatic** — no manual intervention needed.

### How it works in practice

**Scenario: node3 loses network connectivity**

| Time | Event |
|------|-------|
| T+0 | Node3 disconnected from Docker network |
| T+10-20s | Watchdog detects 0/2 peers reachable (need 1 for quorum) |
| T+10-20s | Node3 self-fences: `default_transaction_read_only = on` |
| T+10-20s | Any write attempt on node3 returns: `ERROR: cannot execute ... in a read-only transaction` |
| T+10-20s | HAProxy marks node3 `down`, routes all traffic to nodes 1 & 2 |
| — | Nodes 1 & 2 continue operating normally (they have quorum: 2/3) |
| T+reconnect | Node3 rejoins the network |
| T+reconnect+10-20s | Watchdog detects peers reachable, subscriptions recovering |
| T+reconnect+10-20s | Node3 auto-unfences: `default_transaction_read_only = off` |
| T+reconnect+10-20s | pglogical catches up — rows written during partition replicate to node3 |

### Testing partition behavior

```bash
# 1. Verify baseline — all nodes writable
for n in 1 2 3; do
  echo "--- Node $n ---"
  docker exec mmp-pg-node$n psql -U postgres -d appdb -tAc \
    "SHOW default_transaction_read_only;"
done

# 2. Partition node3
docker network disconnect pg-multimaster-pglogical-cluster_pg-cluster-net mmp-pg-node3

# 3. Wait 20-30s for watchdog to detect and fence
sleep 25

# 4. Verify node3 is fenced
docker exec mmp-pg-node3 psql -U postgres -d appdb -tAc \
  "SHOW default_transaction_read_only;"
# Expected: on

# 5. Verify writes to node3 are rejected
docker exec mmp-pg-node3 psql -U postgres -d appdb -c \
  "CREATE TABLE public.test (id int);"
# Expected: ERROR: cannot execute CREATE TABLE in a read-only transaction

# 6. Verify nodes 1 & 2 still accept writes
docker exec mmp-pg-node1 psql -U postgres -d appdb -c \
  "SELECT pglogical.replicate_ddl_command(\$DDL\$ CREATE TABLE public.test (id int); SELECT pglogical.replication_set_add_table('default', 'public.test', true); \$DDL\$);"

# 7. Reconnect node3
docker network connect pg-multimaster-pglogical-cluster_pg-cluster-net mmp-pg-node3

# 8. Wait 20-30s for auto-unfencing
sleep 25

# 9. Verify node3 is unfenced and data caught up
docker exec mmp-pg-node3 psql -U postgres -d appdb -tAc \
  "SHOW default_transaction_read_only;"
# Expected: off

docker exec mmp-pg-node3 psql -U postgres -d appdb -c \
  "SELECT * FROM public.test;"

# 10. Clean up
docker exec mmp-pg-node1 psql -U postgres -d appdb -c \
  "SELECT pglogical.replicate_ddl_command(\$DDL\$ DROP TABLE public.test CASCADE; \$DDL\$);"
```

### What is NOT protected (known gaps)

| Gap | Description | Possible future mitigation |
|-----|-------------|---------------------------|
| **Brief write window** | Writes accepted in the ~10-20s before the watchdog detects the partition | Synchronous commit to at least one peer (`synchronous_standby_names`) |
| **Direct-port writes after fencing** | A client already connected to a direct port before fencing can still execute reads (writes are blocked by `read_only`) | Application-level connection validation |
| **Symmetric partition** | If all 3 nodes are isolated from each other, all self-fence and the entire cluster becomes read-only | External arbiter (Valkey/Sentinel could serve as a tiebreaker) |
| **Clock skew** | `last_update_wins` depends on `track_commit_timestamp` — NTP desync can cause wrong winner | Use NTP with tight drift tolerance |
| **Application-level conflicts** | Two nodes can make logically conflicting changes (e.g., overdrawing an account) even if row-level conflict resolution works | Application-level optimistic locking (version columns) |

### Architecture of the fencing system

```
                  ┌─────────────────────────────────┐
                  │  pg-repl-health-agent.sh          │
                  │  (runs on every PG node)          │
                  ├─────────────────────────────────┤
                  │ 1. pg_isready? (local PG up?)    │
                  │ 2. pglogical extension loaded?    │
                  │ 3. Quorum check (TCP to peers)    │──► FAIL → fence_node() → "down"
                  │ 4. Subscription health check      │──► ALL down → fence_node() → "down"
                  │ 5. All OK → unfence_node()        │──► "ready up 100%"
                  │ 6. Replication lag check           │──► Lag → "ready up 75%"
                  └─────────────────────────────────┘
                           │                  │
                  Triggered by:        Triggered by:
                  socat (HAProxy         watchdog loop
                  agent-check :5480)     (every 10s)
```

## Comparison: All Multi-Master Variants

| Feature | pg_multi_native_hap (native) | pg_multi_native_flyway | pg_multi_pglogical |
|---------|-------------------|-----------------|-------------------|
| DDL approach | Manual on each node | Flyway migrations per node | `replicate_ddl_command()` — run once |
| Conflict resolution | None (apply error) | None (apply error) | **Last-writer-wins** (real timestamps) |
| DDL version control | None | Flyway SQL files | None (use git for SQL files) |
| Replication protocol | Native logical | Native logical | pglogical extension |
| Extra dependencies | None | Flyway container | pglogical package |
| Table management | `FOR ALL TABLES` | `FOR ALL TABLES` | Replication sets (explicit) |
| Container prefix | `mm-` | `mmf-` | `mmp-` |
| PG direct ports | 5441-5443 | 5541-5543 | 5641-5643 |
| HAProxy ports | 5432/5433 | 5532/5533 | 5632/5633 |

## Backup & Recovery (pgBackRest)

Each PG node has its own pgBackRest stanza because each is an independent `initdb` (different system-id). WAL archiving runs continuously via `archive_command`.

### Stanzas

| Stanza | Node | Description |
|--------|------|-------------|
| `pg-mmp-node1` | mmp-pg-node1 | Multi-master node 1 |
| `pg-mmp-node2` | mmp-pg-node2 | Multi-master node 2 |
| `pg-mmp-node3` | mmp-pg-node3 | Multi-master node 3 |

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

## Troubleshooting

```bash
# Check cluster status
./scripts/manage.sh status

# Detailed replication info (node interfaces, subscriptions, replication sets)
./scripts/manage.sh replication

# Check for conflicts or disabled subscriptions
./scripts/manage.sh conflicts

# View setup logs inside a container
docker exec mmp-pg-node1 cat /tmp/repl-setup.log

# View PostgreSQL logs
./scripts/manage.sh logs pg-node1

# Re-enable disabled subscriptions
./scripts/manage.sh repair enable

# Full resync of a node (drops and recreates subscriptions)
./scripts/manage.sh repair resync mmp-pg-node1

# Connect directly to a node
./scripts/manage.sh psql 5641

# Check pglogical extension version
docker exec mmp-pg-node1 psql -h localhost -U postgres -d appdb -c "SELECT * FROM pg_extension WHERE extname = 'pglogical';"
```

## Teardown

```bash
# Stop the cluster (preserves data volumes)
docker compose down

# Stop and destroy all data
docker compose down -v
```
