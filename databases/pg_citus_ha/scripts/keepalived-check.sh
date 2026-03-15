#!/bin/bash
# =============================================================================
# keepalived Health Check Script for Citus Coordinator HA
# =============================================================================
# Called by keepalived's vrrp_script every 3 seconds.
# Exit 0 = healthy (keep/gain VIP), Exit 1 = unhealthy (lose VIP).
#
# For the primary coordinator:
#   - PG must be accepting connections
#   - Citus extension must be loaded
#   - Must be able to query pg_dist_node
#
# For the standby coordinator:
#   - PG must be accepting connections
#   - Must be in recovery mode (streaming from primary)
#   - If primary is still reachable, report "healthy" but keepalived
#     priority (90 < 100) means the primary wins the VIP election.
#   - If we've been promoted (no longer in recovery), pass all checks.
# =============================================================================

PG_USER="${POSTGRES_USER:-postgres}"
PG_DB="${POSTGRES_DB:-appdb}"

pg_query() {
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 127.0.0.1 -p 5432 -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null
}

# Check 1: PG accepting connections?
if ! pg_isready -h 127.0.0.1 -p 5432 -U "$PG_USER" >/dev/null 2>&1; then
    exit 1
fi

# Check 2: Can we query PG at all?
is_standby=$(pg_query "SELECT pg_is_in_recovery();" 2>/dev/null)
if [ -z "$is_standby" ]; then
    # Can't even run a query
    exit 1
fi

if [ "$is_standby" = "t" ]; then
    # We're a standby. Check that streaming replication is running.
    wal_status=$(pg_query "SELECT status FROM pg_stat_wal_receiver LIMIT 1;" 2>/dev/null)
    if [ "$wal_status" = "streaming" ] || [ "$wal_status" = "catchup" ]; then
        # Healthy standby — streaming from primary
        exit 0
    fi
    # WAL receiver not streaming — could be primary is down.
    # Still report healthy so keepalived can give us the VIP and we promote.
    # (The notify script handles promotion)
    exit 0
else
    # We're a primary (or promoted standby). Check Citus is functional.

    # Check 3: Citus extension loaded?
    citus_ok=$(pg_query "SELECT count(*) FROM pg_extension WHERE extname='citus';" 2>/dev/null)
    if [ "${citus_ok:-0}" != "1" ]; then
        exit 1
    fi

    # Check 4: Can query Citus metadata?
    node_count=$(pg_query "SELECT count(*) FROM pg_dist_node;" 2>/dev/null)
    if [ -z "$node_count" ]; then
        exit 1
    fi

    exit 0
fi
