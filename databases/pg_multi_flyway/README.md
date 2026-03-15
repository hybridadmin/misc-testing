# PostgreSQL 18 Multi-Master Cluster with Flyway

A true multi-master PostgreSQL 18 cluster with **Flyway** for DDL management, using native logical replication (bidirectional pub/sub) with Docker Compose.

## Architecture

```
                    ┌─────────────────────────────┐
                    │          HAProxy             │
                    │   Write :5532 (round-robin)  │
                    │   Read  :5533 (leastconn)    │
                    │   Stats :7100                │
                    └──────┬──────┬──────┬─────────┘
                           │      │      │
              ┌────────────┘      │      └────────────┐
              ▼                   ▼                    ▼
     ┌─────────────┐    ┌─────────────┐     ┌─────────────┐
     │  pg-node1   │◄──►│  pg-node2   │◄───►│  pg-node3   │
     │  :5541      │    │  :5542      │     │  :5543      │
     │  (writer)   │◄──►│  (writer)   │◄───►│  (writer)   │
     └─────────────┘    └─────────────┘     └─────────────┘
           Full-mesh logical replication
           (pub/sub with origin=none)

     ┌─────────────┐    ┌─────────────┐     ┌─────────────┐
     │   Valkey     │    │   Valkey     │     │   Valkey     │
     │   Master     │───►│   Replica1   │     │   Replica2   │
     │   :6479      │    │   :6480      │     │   :6481      │
     └─────────────┘    └─────────────┘     └─────────────┘
           │
     ┌─────┴──────────────┬───────────────────┐
     ▼                    ▼                   ▼
  Sentinel1 :26479   Sentinel2 :26480   Sentinel3 :26481

     ┌─────────────────────────────────────────┐
     │   Flyway (on-demand via manage.sh)      │
     │   Runs DDL on each node sequentially    │
     └─────────────────────────────────────────┘
```

**Key Difference from `pg_multi/`:**
- Uses **Flyway** for DDL version control instead of manual `ddl` commands
- Each node maintains its own `flyway_schema_history` table (excluded from replication)
- Flyway runs via `manage.sh migrate` against each node sequentially

## Quick Start

```bash
# Build and start the cluster (Flyway service won't auto-start)
cd pg_multi_flyway
docker compose up -d --build

# Check status
./scripts/manage.sh status

# Run initial migrations (creates users, products, orders tables)
./scripts/manage.sh migrate

# Check migration status on each node
./scripts/manage.sh migrate info

# Run the replication test
./scripts/manage.sh test
```

## Flyway Migration Commands

```bash
# Run pending migrations on ALL nodes (sequential)
./scripts/manage.sh migrate

# Check migration status (no changes)
./scripts/manage.sh migrate info

# Repair schema history (if needed)
./scripts/manage.sh migrate repair

# DANGER: Clean (drop all tables) - use with caution!
./scripts/manage.sh migrate clean
```

## How Flyway Works in Multi-Master

1. **Flyway runs against each node sequentially** — not through HAProxy
2. **Each node maintains its own `flyway_schema_history` table** — this table is **excluded** from logical replication publications via `ALTER PUBLICATION ... DROP TABLE flyway_schema_history`
3. **Why exclude the tracking table?** If the tracking table replicated, Flyway on node2 would see migration rows from node1 and skip the DDL — but DDL doesn't replicate, so node2 would end up with migration history but no actual tables

## Adding New Migrations

1. Create a new SQL file in `flyway/sql/` following Flyway naming convention:
   ```
   flyway/sql/V4__new_feature.sql
   ```

2. Run the migration:
   ```bash
   ./scripts/manage.sh migrate
   ```

3. Flyway will apply the migration to each node in order:
   - node1 → node2 → node3
   - Each node independently tracks the migration in its own `flyway_schema_history`

## Why Flyway?

### The DDL Problem
Logical replication in PostgreSQL **only replicates DML** (INSERT, UPDATE, DELETE). DDL statements (`CREATE TABLE`, `ALTER TABLE`, `DROP TABLE`) are **not replicated**.

### Manual DDL Approach (pg_multi)
With the manual `ddl` command:
- You run DDL on each node explicitly
- No version tracking
- No rollback support
- Error-prone in CI/CD

### Flyway Approach (pg_multi_flyway)
- DDL is version-controlled in SQL files
- Each node tracks which migrations have been applied
- Idempotent — re-running is safe
- CI/CD friendly — just add migration files and run `migrate`
- Rollback support (via `flyway undo` in paid versions, or manual downgrade scripts)

## Commands Reference

| Command | Description |
|---------|-------------|
| `status` | Cluster overview: node health, pub/sub counts, replication lag |
| `replication` | Detailed publication and subscription info per node |
| `test` | Full replication test: INSERT/UPDATE/DELETE across all nodes |
| `migrate` | Run pending Flyway migrations on ALL nodes |
| `migrate info` | Show migration status per node (no changes) |
| `migrate repair` | Repair Flyway schema history |
| `conflicts` | Show conflict stats, disabled subs, apply errors |
| `repair enable` | Re-enable all disabled subscriptions |
| `repair skip <node>` | Skip errored transaction and re-enable |
| `repair resync <node>` | Drop + recreate subscriptions (full data resync) |
| `repair reset-stats` | Reset conflict counters to zero |
| `psql [port]` | Connect via psql (5532=write, 5533=read, 5541-5543=direct) |
| `valkey-cli` | Connect to Valkey CLI |
| `logs [service]` | Tail Docker logs |
| `bench [scale]` | Run pgbench benchmark (default scale=10) |

## Ports

| Service | Port | Purpose |
|---------|------|---------|
| HAProxy Write | 5532 | Round-robin writes to all PG nodes |
| HAProxy Read | 5533 | Least-connections reads from all PG nodes |
| HAProxy Stats | 7100 | Web dashboard |
| pg-node1 | 5541 | Direct access to node 1 |
| pg-node2 | 5542 | Direct access to node 2 |
| pg-node3 | 5543 | Direct access to node 3 |
| Valkey Master | 6479 | Cache (master) |
| Valkey Replica 1 | 6480 | Cache (replica) |
| Valkey Replica 2 | 6481 | Cache (replica) |
| Sentinel 1/2/3 | 26479-26481 | Valkey high-availability |

## Network

Uses subnet `172.30.0.0/16` to avoid conflicts with:
- `pg_patroni_hap/` (172.28.0.0/16)
- `pg_multi/` (172.29.0.0/16)

## Comparison: pg_multi vs pg_multi_flyway

| Feature | pg_multi (manual DDL) | pg_multi_flyway |
|---------|---------------------|-----------------|
| DDL approach | `manage.sh ddl` | Flyway migrations |
| Version control | None | SQL files in `flyway/sql/` |
| Migration tracking | None | `flyway_schema_history` per node |
| Idempotent runs | Manual | Automatic |
| CI/CD integration | Manual | Add file + run migrate |
| Rollback support | Manual | Via undo scripts (paid) or manual |
| Components | 10 services | 10 + Flyway on-demand |

## Conflict Resolution

Same as `pg_multi/` — see [pg_multi/README.md](../pg_multi/README.md) for details on:
- What PG18 can/cannot detect
- Best practices (UUID PKs, avoid concurrent row updates)
- Recovery procedures

## Initial Migrations

The cluster starts with 3 migrations:

1. **V1__create_users_table.sql** — Users table with UUID PK
2. **V2__create_products_table.sql** — Products catalog
3. **V3__create_orders_table.sql** — Orders + order_items with FKs

All use `gen_random_uuid()` for primary keys to avoid insert conflicts in multi-master.

## Flyway Concerns & Limitations

### Critical Limitations

#### 1. `FOR ALL TABLES` Publications Cannot Exclude Tables
PostgreSQL logical replication has a significant limitation: **you cannot drop tables from a `FOR ALL TABLES` publication**.

```sql
-- This FAILS:
ALTER PUBLICATION pub_pg_node1 DROP TABLE flyway_schema_history;
-- ERROR: publication "pub_pg_node1" is defined as FOR ALL TABLES
-- DETAIL: Tables cannot be added to or dropped from FOR ALL TABLES publications.
```

**Impact:** The `flyway_schema_history` table will replicate to all nodes. This is actually a **cosmetic issue** rather than a functional one:
- Each node's Flyway creates its own `flyway_schema_history` entry when running migrations
- The replicated rows from other nodes are just extra history entries
- Flyway queries its **own** table (local to that node) when checking migrations
- The actual schema (tables created by migrations) still needs to be replicated via DML — which doesn't happen, so migrations run on each node independently

**Workaround:** The setup script attempts to exclude the table but it's silently ignored. This is a known PostgreSQL limitation.

#### 2. Subscriptions May Need Resync After Initial Migration
When Flyway creates new tables, the subscription workers may not immediately sync the table data correctly, causing `sync_error_count` to increment and subscriptions to disable.

**Symptoms:**
- After `./scripts/manage.sh migrate`, subscriptions show `sync_errors` > 0
- Data doesn't replicate even after `repair enable`

**Workaround:**
```bash
# After migrations, if replication is broken:
./scripts/manage.sh repair resync mmf-pg-node1
./scripts/manage.sh repair resync mmf-pg-node2
./scripts/manage.sh repair resync mmf-pg-node3
```

#### 3. No Native Multi-Node Migration
Flyway doesn't have a built-in "run on cluster" mode. We simulate this by:
1. Running Flyway against each node sequentially (node1 → node2 → node3)
2. If node1 succeeds but node2 fails, node2's schema will be out of sync

**Workaround:** Always monitor migration output. If a node fails, fix the issue and re-run.

### Operational Concerns

#### 4. Migration Timing with Active Writes
If applications are actively writing to the database during migration:
- Migration runs on node1 (table created)
- Application writes to node1's new table
- Node2 hasn't run migration yet — write fails or replicates with errors

**Recommendation:** Schedule migrations during maintenance windows with minimal traffic.

#### 5. Column/Table Drops Are Risky
Dropping columns or tables in migrations can cause replication issues if:
1. Node1 runs migration: `ALTER TABLE users DROP COLUMN email;`
2. Node2 hasn't run yet, receives replicated DELETE for the dropped column
3. Replication error occurs

**Recommendation:** Use additive migrations (ADD COLUMN) rather than destructive ones (DROP COLUMN). If you must drop, follow the DROP TABLE safety procedure (disable subs → drop → re-enable).

#### 6. Rollback Requires Manual Intervention
Flyway Community (free) version doesn't support `undo` migrations. You must:
- Manually create a new migration to revert changes
- Or manually fix the schema on each node

### Best Practices

1. **Always use `gen_random_uuid()` for primary keys** — avoids insert conflicts
2. **Schedule migrations during low-traffic periods**
3. **Avoid destructive DDL** (DROP COLUMN, DROP TABLE) in migrations
4. **Run `./scripts/manage.sh repair resync` after initial migration** to ensure clean state
5. **Check `./scripts/manage.sh conflicts` after migrations** to verify replication health

## Troubleshooting

```bash
# Check migration status on all nodes
./scripts/manage.sh migrate info

# See what migrations ran on a specific node
docker exec mmf-pg-node1 psql -h localhost -U postgres -d appdb -c "SELECT * FROM flyway_schema_history ORDER BY installed_rank;"

# Check replication conflicts
./scripts/manage.sh conflicts

# View Docker logs
./scripts/manage.sh logs pg-node1

# If subscriptions broken after migration, resync each node:
./scripts/manage.sh repair resync mmf-pg-node1
./scripts/manage.sh repair resync mmf-pg-node2
./scripts/manage.sh repair resync mmf-pg-node3
```
