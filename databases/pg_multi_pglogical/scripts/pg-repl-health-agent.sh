#!/bin/bash
# =============================================================================
# Replication Health Agent for HAProxy agent-check (port 5480)
# Adapted for pglogical — checks pglogical subscription status
#
# Split-brain mitigations:
#   1. Quorum-aware write gating: if this node cannot reach a majority of
#      peers via TCP, it self-fences (sets default_transaction_read_only=on)
#      and reports DOWN to HAProxy.
#   2. Self-fencing on subscription loss: if ALL pglogical subscriptions are
#      down, the node self-fences and reports DOWN (not just drain).
#   3. Auto-unfencing: when quorum is restored and subscriptions recover,
#      read-only mode is removed automatically.
#
# Fence state is tracked via /tmp/pglogical_fenced to avoid redundant
# ALTER SYSTEM calls on every health check cycle.
# =============================================================================

PG_USER="${POSTGRES_USER:-postgres}"
PG_DB="${POSTGRES_DB:-appdb}"
LAG_THRESHOLD_SECONDS="${REPL_LAG_THRESHOLD:-30}"
FENCE_STATE_FILE="/tmp/pglogical_fenced"
MAINTENANCE_FILE="/tmp/pglogical_maintenance"

# Peer nodes — parsed from ALL_NODES, excluding self
ALL_NODES="${ALL_NODES:-}"
NODE_NAME="${NODE_NAME:-}"
PEERS=()
if [ -n "$ALL_NODES" ] && [ -n "$NODE_NAME" ]; then
    IFS=',' read -ra _ALL <<< "$ALL_NODES"
    for _n in "${_ALL[@]}"; do
        [ "$_n" != "$NODE_NAME" ] && PEERS+=("$_n")
    done
fi
TOTAL_PEERS=${#PEERS[@]}

pg_query() {
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 127.0.0.1 -p 5432 -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Fencing helpers
# ---------------------------------------------------------------------------
fence_node() {
    local reason="$1"
    if [ ! -f "$FENCE_STATE_FILE" ]; then
        # Set node read-only to prevent writes even on direct-access ports
        # ALTER SYSTEM cannot run inside a transaction block, so use separate -c calls
        PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 127.0.0.1 -p 5432 -U "$PG_USER" -d "$PG_DB" \
            -c "ALTER SYSTEM SET default_transaction_read_only = on;" \
            -c "SELECT pg_reload_conf();" >/dev/null 2>&1
        echo "$reason" > "$FENCE_STATE_FILE"
    fi
}

unfence_node() {
    if [ -f "$FENCE_STATE_FILE" ]; then
        PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 127.0.0.1 -p 5432 -U "$PG_USER" -d "$PG_DB" \
            -c "ALTER SYSTEM RESET default_transaction_read_only;" \
            -c "SELECT pg_reload_conf();" >/dev/null 2>&1
        rm -f "$FENCE_STATE_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Check 1: PG accepting connections?
# ---------------------------------------------------------------------------
if ! pg_isready -h 127.0.0.1 -p 5432 -U "$PG_USER" >/dev/null 2>&1; then
    echo "down # pg not accepting connections"
    exit 0
fi

# ---------------------------------------------------------------------------
# Check 2: pglogical extension loaded?
# ---------------------------------------------------------------------------
ext_ok=$(pg_query "SELECT 1 FROM pg_extension WHERE extname = 'pglogical';" 2>/dev/null)
if [ "$ext_ok" != "1" ]; then
    echo "drain # pglogical extension not loaded"
    exit 0
fi

# ---------------------------------------------------------------------------
# Maintenance mode: skip fencing checks when subscriptions are intentionally
# disabled (e.g., during benchmarks or bulk operations).
# Touch /tmp/pglogical_maintenance to enter, remove to exit.
# ---------------------------------------------------------------------------
if [ -f "$MAINTENANCE_FILE" ]; then
    unfence_node
    echo "ready up 100% # maintenance mode — fencing checks skipped"
    exit 0
fi

# ---------------------------------------------------------------------------
# Check 3: Quorum — can we reach a majority of peers?
# With 3 nodes, majority = 2 (self + at least 1 peer).
# We check TCP reachability to peer port 5432 with a 2s timeout.
# ---------------------------------------------------------------------------
reachable_peers=0
for peer in "${PEERS[@]}"; do
    # Use bash /dev/tcp or pg_isready with short timeout
    if pg_isready -h "$peer" -p 5432 -U "$PG_USER" -t 2 >/dev/null 2>&1; then
        reachable_peers=$((reachable_peers + 1))
    fi
done

# Majority requires (total_nodes / 2) + 1. With 3 nodes, that's 2.
# This node is 1, so we need at least 1 reachable peer.
# With 5 nodes, need 3 → need at least 2 reachable peers.
# General: need >= ceil(total_nodes/2) - 1 reachable peers, where total_nodes = TOTAL_PEERS + 1
if [ "$TOTAL_PEERS" -gt 0 ]; then
    total_nodes=$((TOTAL_PEERS + 1))
    majority=$(( (total_nodes / 2) + 1 ))
    needed_peers=$(( majority - 1 ))  # subtract self

    if [ "$reachable_peers" -lt "$needed_peers" ]; then
        fence_node "no_quorum: reachable=$reachable_peers needed=$needed_peers"
        echo "down # no quorum: only $reachable_peers/$TOTAL_PEERS peers reachable (need $needed_peers)"
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Check 4: All pglogical subscriptions healthy?
# If ALL subscriptions are down, self-fence and report DOWN.
# If some are down, report drain (partial degradation).
# ---------------------------------------------------------------------------
total_subs=$(pg_query "SELECT count(*) FROM pglogical.show_subscription_status();" 2>/dev/null)
down_count=$(pg_query "
    SELECT count(*)
    FROM pglogical.show_subscription_status()
    WHERE status NOT IN ('replicating', 'initializing', 'copying');
" 2>/dev/null)

if [ -z "$total_subs" ] || [ -z "$down_count" ]; then
    echo "drain # cannot query pglogical subscriptions"
    exit 0
fi

if [ "$total_subs" -gt 0 ] && [ "$down_count" -eq "$total_subs" ] 2>/dev/null; then
    # ALL subscriptions are down — full partition from peers
    fence_node "all_subs_down: $down_count/$total_subs"
    echo "down # all $total_subs pglogical subscription(s) down — fenced"
    exit 0
fi

if [ "$down_count" -gt 0 ] 2>/dev/null; then
    # Some subscriptions down — partial degradation, don't fence but drain
    echo "drain # ${down_count}/${total_subs} pglogical subscription(s) down"
    exit 0
fi

# ---------------------------------------------------------------------------
# All checks passed — unfence if previously fenced
# ---------------------------------------------------------------------------
unfence_node

# ---------------------------------------------------------------------------
# Check 5: Replication lag via native pg_stat_subscription
# ---------------------------------------------------------------------------
stale_count=$(pg_query "
    SELECT count(*)
    FROM pg_stat_subscription
    WHERE relid IS NULL
      AND last_msg_send_time IS NOT NULL
      AND extract(epoch FROM now() - last_msg_send_time) > ${LAG_THRESHOLD_SECONDS};
" 2>/dev/null)

if [ -n "$stale_count" ] && [ "$stale_count" -gt 0 ] 2>/dev/null; then
    echo "ready up 75% # ${stale_count} subscription(s) lagging >${LAG_THRESHOLD_SECONDS}s"
    exit 0
fi

echo "ready up 100%"
exit 0
