#!/bin/bash
###############################################################################
# setup-spock.sh
#
# Run AFTER all 4 nodes are up and healthy.
# Sets up:
#   1. Spock nodes + replication sets on node1 and node2
#   2. Bidirectional subscriptions (node1 <-> node2)
#   3. Sequence offsets for multi-master PK conflict avoidance
#   4. Sample tables + test data to verify replication
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source .env if available
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a; source "$PROJECT_DIR/.env"; set +a
fi

PGUSER="${POSTGRES_USER:-postgres}"
PGPASSWORD="${POSTGRES_PASSWORD:-postgres}"
PGDB="${POSTGRES_DB:-spockdb}"

NODE1_HOST="${NODE1_HOST:-localhost}"
NODE1_PORT="${PG_NODE1_PORT:-15432}"
NODE2_HOST="${NODE2_HOST:-localhost}"
NODE2_PORT="${PG_NODE2_PORT:-15433}"

export PGPASSWORD

log() { echo "=== [setup-spock] $* ==="; }

psql_node1() { psql -h "$NODE1_HOST" -p "$NODE1_PORT" -U "$PGUSER" -d "$PGDB" -v ON_ERROR_STOP=1 "$@"; }
psql_node2() { psql -h "$NODE2_HOST" -p "$NODE2_PORT" -U "$PGUSER" -d "$PGDB" -v ON_ERROR_STOP=1 "$@"; }

# ──────────────────────────────────────────────────────────────
log "Step 1: Verify Spock extension on both nodes"
# ──────────────────────────────────────────────────────────────
psql_node1 -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'spock';"
psql_node2 -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'spock';"

# ──────────────────────────────────────────────────────────────
log "Step 2: Create sample schema on BOTH nodes"
# ──────────────────────────────────────────────────────────────
# Spock requires identical schemas; DDL is NOT auto-replicated
for run_psql in psql_node1 psql_node2; do
  $run_psql <<-'SQL'
    CREATE TABLE IF NOT EXISTS users (
      id    BIGSERIAL PRIMARY KEY,
      name  TEXT NOT NULL,
      email TEXT,
      node  TEXT DEFAULT 'unknown',
      ts    TIMESTAMPTZ DEFAULT now()
    );

    CREATE TABLE IF NOT EXISTS orders (
      id         BIGSERIAL PRIMARY KEY,
      user_id    BIGINT REFERENCES users(id),
      product    TEXT NOT NULL,
      quantity   INT DEFAULT 1,
      node       TEXT DEFAULT 'unknown',
      created_at TIMESTAMPTZ DEFAULT now()
    );
SQL
done

# ──────────────────────────────────────────────────────────────
log "Step 2b: Configure sequences for multi-master (avoid PK conflicts)"
# ──────────────────────────────────────────────────────────────
# node1 gets odd IDs (1,3,5,...), node2 gets even IDs (2,4,6,...)
psql_node1 <<-'SQL'
  ALTER SEQUENCE users_id_seq INCREMENT BY 2 RESTART WITH 1;
  ALTER SEQUENCE orders_id_seq INCREMENT BY 2 RESTART WITH 1;
SQL

psql_node2 <<-'SQL'
  ALTER SEQUENCE users_id_seq INCREMENT BY 2 RESTART WITH 2;
  ALTER SEQUENCE orders_id_seq INCREMENT BY 2 RESTART WITH 2;
SQL

# ──────────────────────────────────────────────────────────────
log "Step 3: Create Spock nodes"
# ──────────────────────────────────────────────────────────────
# node_create registers this PG instance as a Spock node.
# The DSN must be reachable FROM the other node (inside Docker network).

psql_node1 -c "
  SELECT spock.node_create(
    node_name := 'node1',
    dsn := 'host=node1 port=5432 dbname=${PGDB} user=${PGUSER} password=${PGPASSWORD}'
  );
"

psql_node2 -c "
  SELECT spock.node_create(
    node_name := 'node2',
    dsn := 'host=node2 port=5432 dbname=${PGDB} user=${PGUSER} password=${PGPASSWORD}'
  );
"

# ──────────────────────────────────────────────────────────────
log "Step 4: Add tables to the default replication set"
# ──────────────────────────────────────────────────────────────
for run_psql in psql_node1 psql_node2; do
  $run_psql <<-'SQL'
    SELECT spock.repset_add_all_tables('default', '{public}');
SQL
done

# ──────────────────────────────────────────────────────────────
log "Step 5: Create bidirectional subscriptions"
# ──────────────────────────────────────────────────────────────
# node1 subscribes to node2 (receives changes FROM node2)
psql_node1 -c "
  SELECT spock.sub_create(
    subscription_name := 'sub_node1_from_node2',
    provider_dsn := 'host=node2 port=5432 dbname=${PGDB} user=${PGUSER} password=${PGPASSWORD}',
    replication_sets := '{default}'
  );
"

# node2 subscribes to node1 (receives changes FROM node1)
psql_node2 -c "
  SELECT spock.sub_create(
    subscription_name := 'sub_node2_from_node1',
    provider_dsn := 'host=node1 port=5432 dbname=${PGDB} user=${PGUSER} password=${PGPASSWORD}',
    replication_sets := '{default}'
  );
"

# ──────────────────────────────────────────────────────────────
log "Step 6: Wait for subscriptions to sync"
# ──────────────────────────────────────────────────────────────
sleep 5

log "Subscription status on node1:"
psql_node1 -c "SELECT sub_name, sub_enabled, sub_slot_name FROM spock.subscription;"

log "Subscription status on node2:"
psql_node2 -c "SELECT sub_name, sub_enabled, sub_slot_name FROM spock.subscription;"

# ──────────────────────────────────────────────────────────────
log "Step 7: Insert test data and verify replication"
# ──────────────────────────────────────────────────────────────

# Insert on node1
psql_node1 -c "INSERT INTO users (name, email, node) VALUES ('Alice', 'alice@example.com', 'node1');"
psql_node1 -c "INSERT INTO users (name, email, node) VALUES ('Bob', 'bob@example.com', 'node1');"

# Insert on node2
psql_node2 -c "INSERT INTO users (name, email, node) VALUES ('Charlie', 'charlie@example.com', 'node2');"
psql_node2 -c "INSERT INTO users (name, email, node) VALUES ('Diana', 'diana@example.com', 'node2');"

# Wait for replication
sleep 3

log "Data on node1 (should have all 4 rows):"
psql_node1 -c "SELECT id, name, email, node, ts FROM users ORDER BY id;"

log "Data on node2 (should have all 4 rows):"
psql_node2 -c "SELECT id, name, email, node, ts FROM users ORDER BY id;"

# ──────────────────────────────────────────────────────────────
log "Spock setup complete!"
# ──────────────────────────────────────────────────────────────
echo ""
echo "Topology:"
echo "  node1 (R/W) :${NODE1_PORT}  <--Spock-->  node2 (R/W) :${NODE2_PORT}"
echo "  node3 (RO)  :${PG_NODE3_PORT:-15434}  <- streams from node1"
echo "  node4 (RO)  :${PG_NODE4_PORT:-15435}  <- streams from node2"
echo "  HAProxy R/W :${HAPROXY_RW_PORT:-15000}  -> round-robin node1, node2"
echo "  HAProxy RO  :${HAPROXY_RO_PORT:-15001}  -> round-robin node3, node4"
echo "  HAProxy UI  :${HAPROXY_STATS_PORT:-17000}  -> stats dashboard"
