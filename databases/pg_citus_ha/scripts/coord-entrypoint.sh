#!/bin/bash
# =============================================================================
# Coordinator Entrypoint for Citus 14.0 Distributed Cluster
# =============================================================================
# Starts PG with Citus, launches background cluster setup (add workers,
# set coordinator host), and the failover monitor (VIP management).
#
# NOTE: In production on native Linux (without Rosetta 2 emulation), you can
# use keepalived with VRRP unicast for faster failover (~3s) and split-brain
# protection. See keepalived/keepalived.conf.tmpl for the template.
# =============================================================================
set -e

# ---------------------------------------------------------------------------
# Init script: copy custom configs into PGDATA on first run
# The Citus image already has 001-create-citus-extension.sql in initdb.d
# We add our config copier to run after that
# ---------------------------------------------------------------------------
mkdir -p /docker-entrypoint-initdb.d

cat > /docker-entrypoint-initdb.d/002-copy-configs.sh << 'CONFEOF'
#!/bin/bash
set -e
echo "=== Copying custom postgresql.conf and pg_hba.conf ==="
if [ -f /etc/postgresql/postgresql.conf ]; then
    cp /etc/postgresql/postgresql.conf "$PGDATA/postgresql.conf"
    echo "Copied postgresql.conf to $PGDATA"
fi
if [ -f /etc/postgresql/pg_hba.conf ]; then
    cp /etc/postgresql/pg_hba.conf "$PGDATA/pg_hba.conf"
    echo "Copied pg_hba.conf to $PGDATA"
fi
CONFEOF
chmod +x /docker-entrypoint-initdb.d/002-copy-configs.sh

cat > /docker-entrypoint-initdb.d/003-create-repl-user.sh << 'REPLEOF'
#!/bin/bash
set -e
echo "=== Creating replication user ==="
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${POSTGRES_REPL_USER:-replicator}') THEN
            CREATE ROLE ${POSTGRES_REPL_USER:-replicator} WITH LOGIN REPLICATION PASSWORD '${POSTGRES_REPL_PASSWORD:-changeme_repl_2025}';
        END IF;
    END
    \$\$;
SQL
echo "=== Replication user ready ==="
REPLEOF
chmod +x /docker-entrypoint-initdb.d/003-create-repl-user.sh

# ---------------------------------------------------------------------------
# Background: Citus cluster setup (add workers, register coordinator)
# Only runs on the primary coordinator (not the standby)
# ---------------------------------------------------------------------------
start_cluster_setup_bg() {
    (
        trap "exit 0" ERR EXIT

        echo "=== [cluster-setup] Waiting for coordinator to be ready ==="
        attempts=0
        while ! pg_isready -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-postgres}" 2>/dev/null; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 60 ]; then
                echo "=== [cluster-setup] ERROR: coordinator not ready after 120s ==="
                exit 0
            fi
            sleep 2
        done
        sleep 10  # Wait for init scripts to complete

        # Verify citus extension exists
        max_attempts=30
        for i in $(seq 1 $max_attempts); do
            result=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-appdb}" -tAc "SELECT count(*) FROM pg_extension WHERE extname='citus';" 2>/dev/null)
            if [ "$result" = "1" ]; then
                echo "=== [cluster-setup] Citus extension found ==="
                break
            fi
            echo "=== [cluster-setup] Waiting for citus extension ($i/$max_attempts) ==="
            sleep 2
        done

        /usr/local/bin/setup-cluster.sh || true
        echo "=== [cluster-setup] Done ==="
    ) > /tmp/cluster-setup.log 2>&1 &
}

# ---------------------------------------------------------------------------
# Background: Start failover monitor (assigns VIP, monitors health)
# ---------------------------------------------------------------------------
start_failover_monitor_bg() {
    (
        attempts=0
        while ! pg_isready -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-postgres}" 2>/dev/null; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 60 ]; then
                echo "=== [failover-monitor] ERROR: PG not ready after 120s ==="
                exit 0
            fi
            sleep 2
        done
        sleep 15  # Wait for cluster setup to begin

        echo "=== [failover-monitor] Starting failover monitor ==="
        exec /usr/local/bin/failover-monitor.sh
    ) > /tmp/failover-monitor.log 2>&1 &
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
# Start PG via docker-entrypoint in background, then background tasks, wait
# ---------------------------------------------------------------------------
docker-entrypoint.sh "$@" &
PG_PID=$!

# Start background tasks — both are children of this shell, NOT of postgres
if [ "${IS_COORDINATOR_PRIMARY:-false}" = "true" ]; then
    start_cluster_setup_bg
fi
start_failover_monitor_bg

# Wait for PG — this keeps the container alive
wait $PG_PID
exit $?
