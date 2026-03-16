#!/bin/bash
# =============================================================================
# Replication Health Agent for HAProxy agent-check (port 5480)
#
# HAProxy agent-check protocol: the agent must respond with a single line
# containing a weight/state directive. HAProxy reads the response and adjusts
# the server accordingly.
#
# Responses:
#   "ready up 100%\n"     — node fully healthy, accept traffic
#   "drain\n"             — stop sending NEW connections (existing ones finish)
#   "down\n"              — mark server as down immediately
#   "ready up 50%\n"      — reduce traffic weight (degraded)
#
# This agent checks:
#   1. PG is accepting connections
#   2. All subscriptions are enabled (none disabled due to conflict errors)
#   3. No apply errors (apply_error_count = 0 in pg_stat_subscription_stats)
#   4. Replication lag is within threshold
#
# Runs as: socat TCP-LISTEN:5480,reuseaddr,fork EXEC:/usr/local/bin/pg-repl-health-agent.sh
# =============================================================================

# Configuration
PG_USER="${POSTGRES_USER:-postgres}"
PG_DB="${POSTGRES_DB:-appdb}"
LAG_THRESHOLD_SECONDS="${REPL_LAG_THRESHOLD:-30}"

# Helper: run a query, return trimmed result
pg_query() {
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 127.0.0.1 -p 5432 -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null
}

# Check 1: Can we connect to PG at all?
if ! pg_isready -h 127.0.0.1 -p 5432 -U "$PG_USER" >/dev/null 2>&1; then
    echo "down # pg not accepting connections"
    exit 0
fi

# Check 2: Are ALL subscriptions enabled?
disabled_count=$(pg_query "SELECT count(*) FROM pg_subscription WHERE NOT subenabled;" 2>/dev/null)
if [ -z "$disabled_count" ]; then
    # Can't query — PG might be starting up
    echo "drain # cannot query subscriptions"
    exit 0
fi

if [ "$disabled_count" -gt 0 ] 2>/dev/null; then
    echo "drain # ${disabled_count} subscription(s) disabled"
    exit 0
fi

# Check 3: Any apply errors?
# pg_stat_subscription_stats is PG15+ — check for apply_error_count
error_count=$(pg_query "
    SELECT COALESCE(SUM(apply_error_count), 0)
    FROM pg_stat_subscription_stats;
" 2>/dev/null)

if [ -n "$error_count" ] && [ "$error_count" -gt 0 ] 2>/dev/null; then
    echo "ready up 50% # ${error_count} apply error(s)"
    exit 0
fi

# Check 4: Replication lag — check if any subscription worker hasn't received
# a message recently (indicates stalled replication)
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

# All checks passed — fully healthy
echo "ready up 100%"
exit 0
