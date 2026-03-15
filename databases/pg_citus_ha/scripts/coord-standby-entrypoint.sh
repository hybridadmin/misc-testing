#!/bin/bash
# =============================================================================
# Coordinator Standby Entrypoint for Citus 14.0 Distributed Cluster
# =============================================================================
# This entrypoint handles the standby coordinator which uses physical
# streaming replication from the primary coordinator.
#
# On first start (empty PGDATA):
#   1. Runs pg_basebackup from the primary coordinator
#   2. Creates standby.signal to enter recovery mode
#   3. Configures primary_conninfo for streaming replication
#
# On subsequent starts:
#   - If standby.signal exists: resumes streaming replication
#   - If standby.signal is gone (promoted): starts as primary
#
# The failover monitor runs on this node and watches the primary.
# If the primary is unreachable for N consecutive checks, it assigns
# the VIP to this node and promotes it to primary via pg_promote().
#
# NOTE: In production on native Linux (without Rosetta 2 emulation), you can
# use keepalived with VRRP unicast for faster failover (~3s) and split-brain
# protection. See keepalived/keepalived.conf.tmpl for the template.
# =============================================================================
set -e

PGDATA="${PGDATA:-/var/lib/postgresql/18/docker}"
PRIMARY_HOST="${COORDINATOR_HOST:-coordinator}"
PRIMARY_PORT="5432"
REPL_USER="${POSTGRES_REPL_USER:-replicator}"
REPL_PASS="${POSTGRES_REPL_PASSWORD:-changeme_repl_2025}"
PG_USER="${POSTGRES_USER:-postgres}"
PG_PASS="${POSTGRES_PASSWORD:-changeme_postgres_2025}"
PG_DB="${POSTGRES_DB:-appdb}"
MY_IP="${MY_IP:-172.34.0.11}"

# ---------------------------------------------------------------------------
# Initialize standby from primary via pg_basebackup (first start only)
# ---------------------------------------------------------------------------
init_standby() {
    echo "=== [standby] PGDATA is empty, initializing from primary ($PRIMARY_HOST) ==="

    # Wait for primary to be accepting connections
    echo "=== [standby] Waiting for primary coordinator to be ready ==="
    attempts=0
    while ! pg_isready -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PG_USER" -t 2 >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 90 ]; then
            echo "=== [standby] ERROR: Primary not ready after 180s, aborting ==="
            exit 1
        fi
        sleep 2
    done

    # Extra wait for full initialization (init scripts, cluster setup)
    echo "=== [standby] Primary is accepting connections, waiting 20s for full init ==="
    sleep 20

    # Ensure replication slot exists on primary
    echo "=== [standby] Creating replication slot on primary (if not exists) ==="
    PGPASSWORD="$PG_PASS" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PG_USER" -d postgres -tAc \
        "SELECT pg_create_physical_replication_slot('coordinator_standby', true) WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'coordinator_standby');" 2>/dev/null || true

    # Run pg_basebackup to clone the primary
    echo "=== [standby] Running pg_basebackup from $PRIMARY_HOST ==="
    mkdir -p "$PGDATA"
    chown postgres:postgres "$PGDATA"
    chmod 700 "$PGDATA"

    PGPASSWORD="$REPL_PASS" pg_basebackup \
        -h "$PRIMARY_HOST" \
        -p "$PRIMARY_PORT" \
        -U "$REPL_USER" \
        -D "$PGDATA" \
        -Fp \
        -Xs \
        -P \
        -R \
        -S coordinator_standby \
        --checkpoint=fast

    # -R flag creates standby.signal and sets primary_conninfo in postgresql.auto.conf
    # -S uses the replication slot we created

    # Ensure standby.signal exists (belt and suspenders)
    touch "$PGDATA/standby.signal"
    chown postgres:postgres "$PGDATA/standby.signal"

    # Append slot name to auto.conf if not already there
    if ! grep -q "primary_slot_name" "$PGDATA/postgresql.auto.conf" 2>/dev/null; then
        echo "primary_slot_name = 'coordinator_standby'" >> "$PGDATA/postgresql.auto.conf"
    fi

    # Copy our custom configs (pg_basebackup copies the primary's configs,
    # but we want to use the mounted versions which may differ slightly)
    if [ -f /etc/postgresql/postgresql.conf ]; then
        cp /etc/postgresql/postgresql.conf "$PGDATA/postgresql.conf"
    fi
    if [ -f /etc/postgresql/pg_hba.conf ]; then
        cp /etc/postgresql/pg_hba.conf "$PGDATA/pg_hba.conf"
    fi

    chown -R postgres:postgres "$PGDATA"
    echo "=== [standby] pg_basebackup complete, standby ready ==="
}

# ---------------------------------------------------------------------------
# Start failover monitor as a properly daemonized process
# Uses start-stop-daemon which does a double-fork, ensuring the monitor
# process is fully detached from the PG process tree (reparented to PID 1).
# This avoids PG's "untracked child process" crash on standby nodes.
# ---------------------------------------------------------------------------
start_failover_monitor_daemon() {
    echo "=== [standby] Launching failover monitor via start-stop-daemon ==="

    # Create a wrapper script that waits for PG then runs the monitor.
    # start-stop-daemon needs a single executable to launch.
    cat > /tmp/failover-monitor-wrapper.sh << 'WRAPEOF'
#!/bin/bash
LOG="/tmp/failover-monitor.log"
PG_USER="${POSTGRES_USER:-postgres}"

attempts=0
while ! pg_isready -h 127.0.0.1 -p 5432 -U "$PG_USER" -t 2 >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
        echo "$(date) [failover-monitor] PG not ready after 120s, giving up" >> "$LOG"
        exit 0
    fi
    sleep 2
done
sleep 10

echo "$(date) [failover-monitor] PG is ready, starting failover monitor" >> "$LOG"
exec /usr/local/bin/failover-monitor.sh
WRAPEOF
    chmod +x /tmp/failover-monitor-wrapper.sh

    # start-stop-daemon does a proper double-fork: the monitor process
    # becomes a child of PID 1 (tini), completely outside PG's process tree.
    start-stop-daemon --start --background \
        --make-pidfile --pidfile /tmp/failover-monitor.pid \
        --startas /bin/bash -- /tmp/failover-monitor-wrapper.sh
}

# ---------------------------------------------------------------------------
# Forward signals to PG process for clean shutdown
# ---------------------------------------------------------------------------
forward_signal() {
    if [ -n "$PG_PID" ]; then
        kill -"$1" "$PG_PID" 2>/dev/null || true
    fi
}

trap 'forward_signal TERM' TERM
trap 'forward_signal INT' INT
trap 'forward_signal QUIT' QUIT

# ---------------------------------------------------------------------------
# Check if we need to initialize
# ---------------------------------------------------------------------------
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    # Empty PGDATA — need to clone from primary
    init_standby

    echo "=== [standby] Starting PostgreSQL in standby mode ==="

    # Start PG in background as postgres user
    gosu postgres postgres -D "$PGDATA" &
    PG_PID=$!

    # Launch failover monitor as a fully detached daemon (won't be a PG child)
    start_failover_monitor_daemon

    # Wait for PG — this keeps the container running
    wait $PG_PID
    exit $?
else
    # PGDATA exists — either resuming standby or was promoted
    echo "=== [standby] PGDATA exists ==="

    # Start PG in background as postgres user
    gosu postgres postgres -D "$PGDATA" &
    PG_PID=$!

    # Launch failover monitor as a fully detached daemon (won't be a PG child)
    start_failover_monitor_daemon

    # Wait for PG — this keeps the container running
    wait $PG_PID
    exit $?
fi
