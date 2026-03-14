#!/bin/bash
# =============================================================================
# pglogical Multi-Master Replication Setup Script (keepalived variant)
# Creates pglogical nodes and bidirectional subscriptions for full-mesh
#
# Identical to the pglogical variant — keepalived does not affect replication
# setup, only the load balancing / VIP layer.
# =============================================================================
set +e

NODE_NAME="${NODE_NAME:-unknown}"
ALL_NODES="${ALL_NODES:-}"
DB="${POSTGRES_DB:-appdb}"
SU="${POSTGRES_USER:-postgres}"
SU_PASS="${POSTGRES_PASSWORD:-changeme_postgres_2025}"
REPL_USER="${POSTGRES_REPL_USER:-replicator}"
REPL_PASS="${POSTGRES_REPL_PASSWORD:-changeme_repl_2025}"

# pglogical node name: replace hyphens with underscores (pg-node1 -> pg_node1)
PGL_NODE_NAME="${NODE_NAME//-/_}"

log() { echo "[$NODE_NAME] $(date '+%H:%M:%S') $*"; }

if [ -z "$ALL_NODES" ]; then
    log "ERROR: ALL_NODES not set, cannot configure replication"
    exit 0
fi

IFS=',' read -ra NODES <<< "$ALL_NODES"

PEERS=()
for node in "${NODES[@]}"; do
    if [ "$node" != "$NODE_NAME" ]; then
        PEERS+=("$node")
    fi
done

log "This node: $NODE_NAME (pglogical name: $PGL_NODE_NAME)"
log "Peer nodes: ${PEERS[*]}"
log "Database: $DB"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
run_sql() {
    PGPASSWORD="$SU_PASS" psql -h 127.0.0.1 -p 5432 -U "$SU" -d "$1" -tAc "$2" 2>/dev/null
}

run_sql_verbose() {
    PGPASSWORD="$SU_PASS" psql -h 127.0.0.1 -p 5432 -U "$SU" -d "$1" -c "$2" 2>&1
}

run_sql_quiet() {
    PGPASSWORD="$SU_PASS" psql -h 127.0.0.1 -p 5432 -U "$SU" -d "$1" -c "$2" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Wait for peer nodes
# ---------------------------------------------------------------------------
wait_for_node() {
    local node="$1"
    local max_attempts=60
    local attempt=0
    while ! pg_isready -h "$node" -p 5432 -U "$SU" 2>/dev/null; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_attempts" ]; then
            log "ERROR: Timed out waiting for $node after $max_attempts attempts"
            return 1
        fi
        if [ $((attempt % 10)) -eq 0 ]; then
            log "Waiting for $node... (attempt $attempt/$max_attempts)"
        fi
        sleep 3
    done
    log "Node $node is ready"
    return 0
}

for peer in "${PEERS[@]}"; do
    if ! wait_for_node "$peer"; then
        log "ERROR: Cannot reach peer $peer, aborting replication setup"
        exit 0
    fi
done

# Stagger by node number to avoid simultaneous setup
NODE_NUM=$(echo "$NODE_NAME" | grep -o '[0-9]*$')
STAGGER=$((${NODE_NUM:-1} * 5))
BASE_WAIT=15
TOTAL_WAIT=$((BASE_WAIT + STAGGER))
log "Waiting ${TOTAL_WAIT}s for peers to finish init..."
sleep "$TOTAL_WAIT"

# Verify appdb connectivity on peers
for peer in "${PEERS[@]}"; do
    peer_attempts=0
    while ! PGPASSWORD="$SU_PASS" psql -h "$peer" -p 5432 -U "$SU" -d "$DB" -tAc "SELECT 1;" >/dev/null 2>&1; do
        peer_attempts=$((peer_attempts + 1))
        if [ "$peer_attempts" -ge 20 ]; then
            log "ERROR: Cannot connect to $DB on $peer, aborting"
            exit 0
        fi
        sleep 3
    done
    log "Verified connection to $DB on $peer"
done

# ---------------------------------------------------------------------------
# Step 1: Create pglogical extension
# ---------------------------------------------------------------------------
log "Creating pglogical extension on $DB..."
EXT_EXISTS=$(run_sql "$DB" "SELECT 1 FROM pg_extension WHERE extname = 'pglogical';")
if [ "$EXT_EXISTS" != "1" ]; then
    run_sql_verbose "$DB" "CREATE EXTENSION IF NOT EXISTS pglogical;"
    log "pglogical extension created"
else
    log "pglogical extension already exists"
fi

# ---------------------------------------------------------------------------
# Step 2: Grant permissions
# ---------------------------------------------------------------------------
run_sql_quiet "$DB" "GRANT ALL ON DATABASE $DB TO $REPL_USER;"
run_sql_quiet "$DB" "GRANT USAGE ON SCHEMA pglogical TO $REPL_USER;"
run_sql_quiet "$DB" "GRANT USAGE ON SCHEMA public TO $REPL_USER;"
run_sql_quiet "$DB" "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO $REPL_USER;"
run_sql_quiet "$DB" "GRANT SELECT ON ALL TABLES IN SCHEMA public TO $REPL_USER;"
run_sql_quiet "$DB" "ALTER ROLE $SU SUPERUSER;"

# ---------------------------------------------------------------------------
# Step 3: Configure conflict resolution
# ---------------------------------------------------------------------------
log "Setting conflict resolution to last_update_wins..."
run_sql_quiet "$DB" "ALTER SYSTEM SET pglogical.conflict_resolution = 'last_update_wins';"
run_sql_quiet "$DB" "ALTER SYSTEM SET pglogical.conflict_log_level = 'warning';"
run_sql_quiet "$DB" "SELECT pg_reload_conf();"
log "Conflict resolution configured (log_level=warning)"

# ---------------------------------------------------------------------------
# Step 4: Create pglogical node (this node's identity)
# ---------------------------------------------------------------------------
NODE_DSN="host=$NODE_NAME port=5432 dbname=$DB user=$SU password=$SU_PASS"
EXISTING_NODE=$(run_sql "$DB" "SELECT 1 FROM pglogical.node WHERE node_name = '$PGL_NODE_NAME';")

if [ "$EXISTING_NODE" != "1" ]; then
    log "Creating pglogical node: $PGL_NODE_NAME"
    OUTPUT=$(run_sql_verbose "$DB" "SELECT pglogical.create_node(
        node_name := '$PGL_NODE_NAME',
        dsn := '$NODE_DSN'
    );")
    log "create_node result: $OUTPUT"
else
    log "pglogical node $PGL_NODE_NAME already exists"
fi

# ---------------------------------------------------------------------------
# Step 5: Create subscriptions to each peer
# ---------------------------------------------------------------------------
for peer in "${PEERS[@]}"; do
    PEER_PGL_NAME="${peer//-/_}"
    SUB_NAME="${PGL_NODE_NAME}_sub_${PEER_PGL_NAME}"
    PEER_DSN="host=$peer port=5432 dbname=$DB user=$SU password=$SU_PASS"

    EXISTING_SUB=$(run_sql "$DB" "SELECT 1 FROM pglogical.subscription WHERE sub_name = '$SUB_NAME';")

    if [ "$EXISTING_SUB" != "1" ]; then
        log "Waiting for pglogical node on $peer..."
        pgl_attempts=0
        while true; do
            PEER_NODE_EXISTS=$(PGPASSWORD="$SU_PASS" psql -h "$peer" -p 5432 -U "$SU" -d "$DB" -tAc \
                "SELECT 1 FROM pglogical.node WHERE node_name = '$PEER_PGL_NAME';" 2>/dev/null || echo "")
            if [ "$PEER_NODE_EXISTS" = "1" ]; then
                log "Found pglogical node $PEER_PGL_NAME on $peer"
                break
            fi
            pgl_attempts=$((pgl_attempts + 1))
            if [ "$pgl_attempts" -ge 60 ]; then
                log "WARNING: Timed out waiting for pglogical node on $peer after 180s, skipping"
                continue 2
            fi
            sleep 3
        done

        log "Creating subscription $SUB_NAME -> $peer"
        sub_attempts=0
        sub_max=5
        while [ "$sub_attempts" -lt "$sub_max" ]; do
            sub_attempts=$((sub_attempts + 1))
            SUB_OUTPUT=$(run_sql_verbose "$DB" "SELECT pglogical.create_subscription(
                subscription_name := '$SUB_NAME',
                provider_dsn := '$PEER_DSN',
                replication_sets := ARRAY['default', 'default_insert_only', 'ddl_sql'],
                synchronize_structure := false,
                synchronize_data := false,
                forward_origins := '{}'
            );")
            SUB_EXIT=$?
            if [ $SUB_EXIT -eq 0 ] && echo "$SUB_OUTPUT" | grep -q "create_subscription"; then
                log "Subscription $SUB_NAME created successfully"
                break
            fi
            log "Attempt $sub_attempts/$sub_max failed for $SUB_NAME: $SUB_OUTPUT"
            if [ "$sub_attempts" -lt "$sub_max" ]; then
                log "Retrying in 10s..."
                sleep 10
            fi
        done
    else
        log "Subscription $SUB_NAME already exists"
    fi

    sleep 3
done

log "=== pglogical replication setup complete for $NODE_NAME ==="
log "Node: $PGL_NODE_NAME"
log "Subscriptions: ${#PEERS[@]} peer subscriptions configured"
log "Conflict resolution: last_update_wins"

exit 0
