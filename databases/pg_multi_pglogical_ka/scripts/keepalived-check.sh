#!/bin/bash
# =============================================================================
# keepalived Health Check Script for PostgreSQL + pglogical
# =============================================================================
# Called by keepalived's vrrp_script every 3 seconds.
# Exit 0 = healthy (keep/gain VIP), Exit 1 = unhealthy (lose VIP).
#
# Checks:
#   1. PostgreSQL accepting connections
#   2. pglogical extension loaded
#   3. Quorum: can reach majority of peers
#   4. pglogical subscriptions not all down
#
# Also performs self-fencing (default_transaction_read_only) on failure,
# same as the pglogical variant's watchdog — this script IS the watchdog.
# =============================================================================

PG_USER="${POSTGRES_USER:-postgres}"
PG_DB="${POSTGRES_DB:-appdb}"
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
# Fencing helpers (same as pglogical variant)
# ---------------------------------------------------------------------------
fence_node() {
    local reason="$1"
    if [ ! -f "$FENCE_STATE_FILE" ]; then
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
    exit 1
fi

# ---------------------------------------------------------------------------
# Check 2: pglogical extension loaded?
# ---------------------------------------------------------------------------
ext_ok=$(pg_query "SELECT 1 FROM pg_extension WHERE extname = 'pglogical';" 2>/dev/null)
if [ "$ext_ok" != "1" ]; then
    # During initial startup, pglogical may not be loaded yet — don't fence,
    # just report unhealthy so keepalived doesn't give us the VIP prematurely
    exit 1
fi

# ---------------------------------------------------------------------------
# Maintenance mode: skip fencing checks when subscriptions are intentionally
# disabled (e.g., during benchmarks or bulk operations).
# ---------------------------------------------------------------------------
if [ -f "$MAINTENANCE_FILE" ]; then
    unfence_node
    exit 0
fi

# ---------------------------------------------------------------------------
# Check 3: Quorum — can we reach a majority of peers?
# ---------------------------------------------------------------------------
reachable_peers=0
for peer in "${PEERS[@]}"; do
    if pg_isready -h "$peer" -p 5432 -U "$PG_USER" -t 2 >/dev/null 2>&1; then
        reachable_peers=$((reachable_peers + 1))
    fi
done

if [ "$TOTAL_PEERS" -gt 0 ]; then
    total_nodes=$((TOTAL_PEERS + 1))
    majority=$(( (total_nodes / 2) + 1 ))
    needed_peers=$(( majority - 1 ))

    if [ "$reachable_peers" -lt "$needed_peers" ]; then
        fence_node "no_quorum: reachable=$reachable_peers needed=$needed_peers"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Check 4: pglogical subscriptions healthy?
# ---------------------------------------------------------------------------
total_subs=$(pg_query "SELECT count(*) FROM pglogical.show_subscription_status();" 2>/dev/null)
down_count=$(pg_query "
    SELECT count(*)
    FROM pglogical.show_subscription_status()
    WHERE status NOT IN ('replicating', 'initializing', 'copying');
" 2>/dev/null)

if [ -n "$total_subs" ] && [ -n "$down_count" ] && [ "$total_subs" -gt 0 ] && [ "$down_count" -eq "$total_subs" ] 2>/dev/null; then
    fence_node "all_subs_down: $down_count/$total_subs"
    exit 1
fi

# ---------------------------------------------------------------------------
# All checks passed — unfence if previously fenced
# ---------------------------------------------------------------------------
unfence_node
exit 0
