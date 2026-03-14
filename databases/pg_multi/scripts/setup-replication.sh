#!/bin/bash
# =============================================================================
# Multi-Master Logical Replication Setup Script
# Creates publications and subscriptions for full-mesh bidirectional replication
#
# Environment variables:
#   NODE_NAME       - This node's hostname (e.g., pg-node1)
#   ALL_NODES       - Comma-separated list of all node hostnames
#   POSTGRES_USER   - Superuser name
#   POSTGRES_PASSWORD - Superuser password
#   POSTGRES_DB     - Application database
#   POSTGRES_REPL_USER - Replication user
#   POSTGRES_REPL_PASSWORD - Replication password
# =============================================================================
# IMPORTANT: Do NOT use set -e here. This runs as a background process and
# any non-zero exit will be treated as a backend crash by PG (PID 1).
set +e

NODE_NAME="${NODE_NAME:-unknown}"
ALL_NODES="${ALL_NODES:-}"
DB="${POSTGRES_DB:-appdb}"
SU="${POSTGRES_USER:-postgres}"
SU_PASS="${POSTGRES_PASSWORD:-changeme_postgres_2025}"
REPL_USER="${POSTGRES_REPL_USER:-replicator}"
REPL_PASS="${POSTGRES_REPL_PASSWORD:-changeme_repl_2025}"

log() { echo "[$NODE_NAME] $(date '+%H:%M:%S') $*"; }

if [ -z "$ALL_NODES" ]; then
    log "ERROR: ALL_NODES not set, cannot configure replication"
    exit 0
fi

# Parse node list
IFS=',' read -ra NODES <<< "$ALL_NODES"

# Identify peer nodes (all nodes except self)
PEERS=()
for node in "${NODES[@]}"; do
    if [ "$node" != "$NODE_NAME" ]; then
        PEERS+=("$node")
    fi
done

log "This node: $NODE_NAME"
log "Peer nodes: ${PEERS[*]}"
log "Database: $DB"

# ---------------------------------------------------------------------------
# Helper: run SQL on local node (returns output, suppresses errors)
# ---------------------------------------------------------------------------
run_sql() {
    PGPASSWORD="$SU_PASS" psql -h 127.0.0.1 -p 5432 -U "$SU" -d "$1" -tAc "$2" 2>/dev/null
}

run_sql_quiet() {
    PGPASSWORD="$SU_PASS" psql -h 127.0.0.1 -p 5432 -U "$SU" -d "$1" -c "$2" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Wait for all peer nodes to be reachable
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

# Extra wait to ensure all initdb scripts have completed on peers
# Stagger subscription creation by node number to avoid overwhelming
# freshly-started nodes with simultaneous replication slot creation
NODE_NUM=$(echo "$NODE_NAME" | grep -o '[0-9]*$')
STAGGER=$((${NODE_NUM:-1} * 5))
BASE_WAIT=15
TOTAL_WAIT=$((BASE_WAIT + STAGGER))
log "Waiting ${TOTAL_WAIT}s for peers to finish init (base=${BASE_WAIT}s + stagger=${STAGGER}s for node ${NODE_NUM})..."
sleep "$TOTAL_WAIT"

# Verify we can connect to appdb on all peers
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
# Grant replication user access
# ---------------------------------------------------------------------------
run_sql_quiet "$DB" "GRANT ALL ON DATABASE $DB TO $REPL_USER;"
run_sql_quiet "$DB" "GRANT USAGE ON SCHEMA public TO $REPL_USER;"
run_sql_quiet "$DB" "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO $REPL_USER;"
run_sql_quiet "$DB" "GRANT SELECT ON ALL TABLES IN SCHEMA public TO $REPL_USER;"

# ---------------------------------------------------------------------------
# Create publication (publishes ALL tables in appdb)
# ---------------------------------------------------------------------------
PUB_NAME="pub_${NODE_NAME//-/_}"
EXISTING_PUB=$(run_sql "$DB" "SELECT 1 FROM pg_publication WHERE pubname = '$PUB_NAME';")

if [ "$EXISTING_PUB" != "1" ]; then
    log "Creating publication $PUB_NAME on $DB"
    run_sql_quiet "$DB" "CREATE PUBLICATION $PUB_NAME FOR ALL TABLES;"
    # Verify it was created
    VERIFY_PUB=$(run_sql "$DB" "SELECT 1 FROM pg_publication WHERE pubname = '$PUB_NAME';")
    if [ "$VERIFY_PUB" = "1" ]; then
        log "Publication $PUB_NAME created successfully"
    else
        log "ERROR: Failed to create publication $PUB_NAME"
        exit 0
    fi
else
    log "Publication $PUB_NAME already exists"
fi

# ---------------------------------------------------------------------------
# Create subscriptions to each peer node
# ---------------------------------------------------------------------------
for peer in "${PEERS[@]}"; do
    SUB_NAME="sub_${peer//-/_}_to_${NODE_NAME//-/_}"
    PEER_PUB="pub_${peer//-/_}"

    EXISTING_SUB=$(run_sql "$DB" "SELECT 1 FROM pg_subscription WHERE subname = '$SUB_NAME';")

    if [ "$EXISTING_SUB" != "1" ]; then
        # Wait for the peer's publication to exist
        log "Waiting for publication $PEER_PUB on $peer..."
        pub_attempts=0
        while true; do
            PEER_PUB_EXISTS=$(PGPASSWORD="$SU_PASS" psql -h "$peer" -p 5432 -U "$SU" -d "$DB" -tAc \
                "SELECT 1 FROM pg_publication WHERE pubname = '$PEER_PUB';" 2>/dev/null || echo "")
            if [ "$PEER_PUB_EXISTS" = "1" ]; then
                log "Found publication $PEER_PUB on $peer"
                break
            fi
            pub_attempts=$((pub_attempts + 1))
            if [ "$pub_attempts" -ge 60 ]; then
                log "WARNING: Timed out waiting for $PEER_PUB on $peer after 180s, skipping"
                continue 2
            fi
            sleep 3
        done

        log "Creating subscription $SUB_NAME -> $peer ($PEER_PUB)"
        # copy_data=false: nodes start empty and in sync, no initial bulk copy needed
        # origin=none: prevents replication loops — don't re-replicate data that
        #              arrived via another subscription (critical for multi-master)
        # disable_on_error=true: if a conflict causes an error (e.g. unique constraint
        #              violation), disable the subscription instead of crash-looping.
        #              This allows inspection and manual resolution.
        # streaming=parallel: stream large in-progress transactions in parallel
        #
        # Retry loop: CREATE SUBSCRIPTION creates a replication slot on the remote node.
        # If the remote is busy (e.g., other nodes are also creating slots), it may fail.
        sub_attempts=0
        sub_max=5
        while [ "$sub_attempts" -lt "$sub_max" ]; do
            sub_attempts=$((sub_attempts + 1))
            SUB_OUTPUT=$(PGPASSWORD="$SU_PASS" psql -h 127.0.0.1 -p 5432 -U "$SU" -d "$DB" -c "CREATE SUBSCRIPTION $SUB_NAME \
                CONNECTION 'host=$peer port=5432 dbname=$DB user=$SU password=$SU_PASS' \
                PUBLICATION $PEER_PUB \
                WITH (copy_data = false, origin = none, disable_on_error = true, streaming = parallel);" 2>&1)
            SUB_EXIT=$?
            if [ $SUB_EXIT -eq 0 ]; then
                break
            fi
            log "Attempt $sub_attempts/$sub_max failed for $SUB_NAME: $SUB_OUTPUT"
            if [ "$sub_attempts" -lt "$sub_max" ]; then
                log "Retrying in 10s..."
                sleep 10
            fi
        done

        # Verify
        VERIFY_SUB=$(run_sql "$DB" "SELECT 1 FROM pg_subscription WHERE subname = '$SUB_NAME';")
        if [ "$VERIFY_SUB" = "1" ]; then
            log "Subscription $SUB_NAME created successfully"
        else
            log "WARNING: Subscription $SUB_NAME may not have been created"
        fi
    else
        log "Subscription $SUB_NAME already exists"
    fi

    # Brief pause between subscriptions to reduce load on peers
    sleep 3
done

log "=== Replication setup complete for $NODE_NAME ==="
log "Publications: $PUB_NAME"
log "Subscriptions: ${#PEERS[@]} peer subscriptions configured"

# Always exit cleanly
exit 0
