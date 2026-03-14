#!/bin/bash
# =============================================================================
# Replication Health Agent for HAProxy agent-check (port 5480)
# Adapted for pglogical — checks pglogical subscription status
# =============================================================================

PG_USER="${POSTGRES_USER:-postgres}"
PG_DB="${POSTGRES_DB:-appdb}"
LAG_THRESHOLD_SECONDS="${REPL_LAG_THRESHOLD:-30}"

pg_query() {
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 127.0.0.1 -p 5432 -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null
}

# Check 1: PG accepting connections?
if ! pg_isready -h 127.0.0.1 -p 5432 -U "$PG_USER" >/dev/null 2>&1; then
    echo "down # pg not accepting connections"
    exit 0
fi

# Check 2: pglogical extension loaded?
ext_ok=$(pg_query "SELECT 1 FROM pg_extension WHERE extname = 'pglogical';" 2>/dev/null)
if [ "$ext_ok" != "1" ]; then
    echo "drain # pglogical extension not loaded"
    exit 0
fi

# Check 3: All pglogical subscriptions healthy?
# pglogical.show_subscription_status() returns status per subscription
# status values: initializing, copying, replicating, down
down_count=$(pg_query "
    SELECT count(*)
    FROM pglogical.show_subscription_status()
    WHERE status NOT IN ('replicating', 'initializing', 'copying');
" 2>/dev/null)

if [ -z "$down_count" ]; then
    echo "drain # cannot query pglogical subscriptions"
    exit 0
fi

if [ "$down_count" -gt 0 ] 2>/dev/null; then
    echo "drain # ${down_count} pglogical subscription(s) down"
    exit 0
fi

# Check 4: Replication lag via native pg_stat_subscription (pglogical uses it)
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
