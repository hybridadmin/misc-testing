#!/bin/bash
# ============================================================
# setup_replication.sh
# Configures full-mesh bidirectional pglogical replication
# between pg_node1, pg_node2, and pg_node3.
#
# Full mesh = 6 subscriptions:
#   node1 -> node2, node2 -> node1
#   node1 -> node3, node3 -> node1
#   node2 -> node3, node3 -> node2
#
# All nodes start from the same init.sql schema, so we use
# synchronize_data := false to avoid PK conflicts from seed data.
#
# Runs as a one-shot container AFTER all three nodes are healthy.
# ============================================================
set -euo pipefail

PGUSER="${POSTGRES_USER:-appuser}"
PGDB="${POSTGRES_DB:-app_db}"
export PGPASSWORD="${POSTGRES_PASSWORD:-changeme_prod_2024}"

NODE1_HOST="pg_node1"
NODE2_HOST="pg_node2"
NODE3_HOST="pg_node3"
PORT=5432

log() { echo "[pglogical-setup] $*"; }

run_sql() {
    local host="$1"; shift
    psql -h "$host" -p "$PORT" -U "$PGUSER" -d "$PGDB" \
         -v ON_ERROR_STOP=1 --no-psqlrc -qAt "$@"
}

# ─── Wait for all nodes ──────────────────────────────────────
wait_ready() {
    local host="$1" name="$2"
    log "Waiting for $name ($host) ..."
    for i in $(seq 1 60); do
        if pg_isready -h "$host" -p "$PORT" -U "$PGUSER" -d "$PGDB" >/dev/null 2>&1; then
            log "$name is ready."
            return 0
        fi
        sleep 1
    done
    log "ERROR: $name did not become ready in 60 s"
    exit 1
}

wait_ready "$NODE1_HOST" "node1"
wait_ready "$NODE2_HOST" "node2"
wait_ready "$NODE3_HOST" "node3"

# ─── Create pglogical nodes ──────────────────────────────────
create_node() {
    local host="$1" node_name="$2"
    log "Creating pglogical node '$node_name' on $host ..."
    run_sql "$host" <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pglogical.node WHERE node_name = '${node_name}') THEN
        PERFORM pglogical.create_node(
            node_name := '${node_name}',
            dsn := 'host=${host} port=${PORT} dbname=${PGDB} user=${PGUSER} password=${POSTGRES_PASSWORD}'
        );
    END IF;
END
\$\$;
SQL
}

create_node "$NODE1_HOST" "node1"
create_node "$NODE2_HOST" "node2"
create_node "$NODE3_HOST" "node3"

# ─── Add all tables to the default replication set on each node ──
# synchronize_data := false because all nodes already have the same
# schema from init.sql — no initial data copy needed.
add_tables_to_default_set() {
    local host="$1" node_name="$2"
    log "Adding tables to default replication set on $node_name ..."
    run_sql "$host" <<'SQL'
DO $$
DECLARE
    tbl RECORD;
BEGIN
    FOR tbl IN
        SELECT schemaname, tablename
        FROM pg_tables
        WHERE schemaname = 'public'
          AND tablename NOT LIKE 'pglogical%'
    LOOP
        BEGIN
            PERFORM pglogical.replication_set_add_table(
                set_name       := 'default',
                relation       := (tbl.schemaname || '.' || tbl.tablename)::regclass,
                synchronize_data := false
            );
            RAISE NOTICE 'Added %.% to default set', tbl.schemaname, tbl.tablename;
        EXCEPTION WHEN duplicate_object OR unique_violation THEN
            RAISE NOTICE '%.% already in default set', tbl.schemaname, tbl.tablename;
        END;
    END LOOP;
END
$$;
SQL
}

add_tables_to_default_set "$NODE1_HOST" "node1"
add_tables_to_default_set "$NODE2_HOST" "node2"
add_tables_to_default_set "$NODE3_HOST" "node3"

# ─── Create full-mesh bidirectional subscriptions ─────────────
# forward_origins := '{}' prevents infinite replication loops
# in a multi-node bidirectional topology.
# synchronize_data := false because all nodes share the same init.sql.
create_subscription() {
    local sub_host="$1" sub_name="$2" provider_host="$3"
    log "Creating subscription '$sub_name' on $sub_host -> $provider_host ..."

    run_sql "$sub_host" <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pglogical.subscription WHERE sub_name = '${sub_name}'
    ) THEN
        PERFORM pglogical.create_subscription(
            subscription_name := '${sub_name}',
            provider_dsn      := 'host=${provider_host} port=${PORT} dbname=${PGDB} user=${PGUSER} password=${POSTGRES_PASSWORD}',
            replication_sets  := ARRAY['default'],
            synchronize_data  := false,
            forward_origins   := '{}'
        );
    END IF;
END
\$\$;
SQL
}

# node1 <-> node2
create_subscription "$NODE2_HOST" "sub_node2_from_node1" "$NODE1_HOST"
create_subscription "$NODE1_HOST" "sub_node1_from_node2" "$NODE2_HOST"

# node1 <-> node3
create_subscription "$NODE3_HOST" "sub_node3_from_node1" "$NODE1_HOST"
create_subscription "$NODE1_HOST" "sub_node1_from_node3" "$NODE3_HOST"

# node2 <-> node3
create_subscription "$NODE3_HOST" "sub_node3_from_node2" "$NODE2_HOST"
create_subscription "$NODE2_HOST" "sub_node2_from_node3" "$NODE3_HOST"

# ─── Wait for subscriptions to reach replicating state ─────────
log "Waiting for subscriptions to initialize ..."
sleep 10

check_sub() {
    local host="$1" sub_name="$2"
    local status
    # PG18 pglogical returns "subscription_name" not "sub_name" in show_subscription_status()
    status=$(run_sql "$host" -c \
        "SELECT status FROM pglogical.show_subscription_status('${sub_name}');" 2>/dev/null || echo "unknown")
    log "  $sub_name on $host: $status"
}

log "--- Subscription status ---"
check_sub "$NODE2_HOST" "sub_node2_from_node1"
check_sub "$NODE1_HOST" "sub_node1_from_node2"
check_sub "$NODE3_HOST" "sub_node3_from_node1"
check_sub "$NODE1_HOST" "sub_node1_from_node3"
check_sub "$NODE3_HOST" "sub_node3_from_node2"
check_sub "$NODE2_HOST" "sub_node2_from_node3"

# ─── Stagger SERIAL sequences per node ────────────────────────
# With 3 nodes doing multi-master writes, all sharing the same
# SERIAL sequences, they would generate colliding PKs (1,2,3,...).
# Fix: set INCREMENT BY 3 with different START offsets:
#   node1: 1, 4, 7, 10, ...
#   node2: 2, 5, 8, 11, ...
#   node3: 3, 6, 9, 12, ...
#
# Idempotent: on re-run, queries MAX(col) from the owning table
# to compute a safe restart value above all existing data.
stagger_sequences() {
    local host="$1" offset="$2" node_name="$3"
    log "Staggering sequences on $node_name (offset=$offset, increment=3) ..."
    run_sql "$host" <<SQL
DO \$\$
DECLARE
    seq RECORD;
    max_val bigint;
    new_start bigint;
BEGIN
    FOR seq IN
        SELECT
            s.sequencename,
            d.refobjid::regclass AS table_name,
            a.attname AS column_name
        FROM pg_sequences s
        JOIN pg_class c ON c.relname = s.sequencename AND c.relnamespace = 'public'::regnamespace
        JOIN pg_depend d ON d.objid = c.oid AND d.deptype = 'a'
        JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
        WHERE s.schemaname = 'public'
    LOOP
        -- Get the actual max value from the table column
        EXECUTE format('SELECT COALESCE(MAX(%I), 0) FROM %s', seq.column_name, seq.table_name)
            INTO max_val;

        -- Compute the next value > max_val with correct modulo alignment
        IF max_val < ${offset} THEN
            new_start := ${offset};
        ELSE
            new_start := max_val + 1;
            WHILE (new_start % 3) != (${offset} % 3) LOOP
                new_start := new_start + 1;
            END LOOP;
        END IF;

        EXECUTE format(
            'ALTER SEQUENCE %I INCREMENT BY 3 RESTART WITH %s',
            seq.sequencename,
            new_start
        );
        RAISE NOTICE 'Staggered % on ${node_name}: restart=%, increment=3 (max existing=%)',
            seq.sequencename, new_start, max_val;
    END LOOP;
END
\$\$;
SQL
}

stagger_sequences "$NODE1_HOST" 1 "node1"
stagger_sequences "$NODE2_HOST" 2 "node2"
stagger_sequences "$NODE3_HOST" 3 "node3"

# ─── Quick smoke test ─────────────────────────────────────────
log "Running 3-node replication smoke test ..."

# Use a unique marker per run so re-runs don't conflict with prior data
MARKER="smoke_$(date +%s)"

run_sql "$NODE1_HOST" -c \
    "INSERT INTO benchmark_table (data) VALUES ('${MARKER}_node1');"
run_sql "$NODE2_HOST" -c \
    "INSERT INTO benchmark_table (data) VALUES ('${MARKER}_node2');"
run_sql "$NODE3_HOST" -c \
    "INSERT INTO benchmark_table (data) VALUES ('${MARKER}_node3');"

# Give replication a few seconds to converge
sleep 5

# Count only this run's smoke test rows on each node
N1_COUNT=$(run_sql "$NODE1_HOST" -c "SELECT count(*) FROM benchmark_table WHERE data LIKE '${MARKER}%';")
N2_COUNT=$(run_sql "$NODE2_HOST" -c "SELECT count(*) FROM benchmark_table WHERE data LIKE '${MARKER}%';")
N3_COUNT=$(run_sql "$NODE3_HOST" -c "SELECT count(*) FROM benchmark_table WHERE data LIKE '${MARKER}%';")

log "Smoke rows (marker=$MARKER): node1=$N1_COUNT, node2=$N2_COUNT, node3=$N3_COUNT"

if [ "$N1_COUNT" = "3" ] && [ "$N2_COUNT" = "3" ] && [ "$N3_COUNT" = "3" ]; then
    log "Full-mesh bidirectional replication is working correctly. All 3 nodes have 3 smoke rows."
else
    log "WARNING: smoke row counts differ -- replication may still be syncing."
    log "  Expected 3 on each node. node1=$N1_COUNT, node2=$N2_COUNT, node3=$N3_COUNT"
    log "Dumping smoke rows from each node for debugging:"
    run_sql "$NODE1_HOST" -c "SELECT id, data FROM benchmark_table WHERE data LIKE '${MARKER}%' ORDER BY id;" || true
    run_sql "$NODE2_HOST" -c "SELECT id, data FROM benchmark_table WHERE data LIKE '${MARKER}%' ORDER BY id;" || true
    run_sql "$NODE3_HOST" -c "SELECT id, data FROM benchmark_table WHERE data LIKE '${MARKER}%' ORDER BY id;" || true
fi

log "============================================"
log " pglogical 3-node full-mesh setup complete!"
log "============================================"
