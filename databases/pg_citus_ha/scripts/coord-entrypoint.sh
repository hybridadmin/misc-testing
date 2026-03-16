#!/bin/bash
# =============================================================================
# Coordinator Entrypoint for Citus 14.0 Distributed Cluster
# =============================================================================
# Starts PG with Citus, launches background cluster setup (add workers,
# set coordinator host), the failover monitor (VIP management), and
# pgBackRest stanza creation + initial backup (primary only).
#
# NOTE: In production on native Linux (without Rosetta 2 emulation), you can
# use keepalived with VRRP unicast for faster failover (~3s) and split-brain
# protection. See keepalived/keepalived.conf.tmpl for the template.
# =============================================================================
set -e

# pgBackRest stanza: coordinator + standby share system-id (standby is
# pg_basebackup clone), so they share the same stanza.
: "${PGBACKREST_STANZA:=pg-citus-coordinator}"
PGDATA="${PGDATA:-/var/lib/postgresql/18/docker}"

# ---------------------------------------------------------------------------
# Generate per-node pgbackrest.conf
# ---------------------------------------------------------------------------
generate_pgbackrest_conf() {
    local stanza="$1"
    mkdir -p /etc/pgbackrest
    cat > /etc/pgbackrest/pgbackrest.conf <<EOF
[global]
repo1-path=/var/lib/pgbackrest
repo1-type=posix

# Retention
repo1-retention-full=2
repo1-retention-diff=3
repo1-retention-archive=2
repo1-retention-archive-type=full

# Performance
process-max=2
compress-type=lz4
compress-level=1

# Reliability
start-fast=y
delta=y
resume=n

# Logging
log-level-console=warn
log-path=/var/log/pgbackrest

# Archive async
archive-async=y
spool-path=/var/spool/pgbackrest

[global:archive-push]
compress-level=3
log-level-console=info

[global:archive-get]
process-max=2

[${stanza}]
pg1-path=${PGDATA}
pg1-port=5432
pg1-socket-path=/var/run/postgresql
EOF
    chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
    echo "=== [entrypoint] Generated pgbackrest.conf with stanza='${stanza}' ==="
}

# Ensure pgBackRest directories exist
for dir in /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest; do
    mkdir -p "$dir" 2>/dev/null || true
    chown postgres:postgres "$dir" 2>/dev/null || true
done

generate_pgbackrest_conf "$PGBACKREST_STANZA"

# ---------------------------------------------------------------------------
# Init script: copy custom configs into PGDATA on first run
# The Citus image already has 001-create-citus-extension.sql in initdb.d
# We add our config copier to run after that
# ---------------------------------------------------------------------------
mkdir -p /docker-entrypoint-initdb.d

# NOTE: archive_command is injected here because it needs the per-node stanza name.
# archive_mode=on is already in postgresql.conf but archive_command cannot be there
# since it differs per node (different stanza names).
cat > /docker-entrypoint-initdb.d/002-copy-configs.sh << CONFEOF
#!/bin/bash
set -e
echo "=== Copying custom postgresql.conf and pg_hba.conf ==="
if [ -f /etc/postgresql/postgresql.conf ]; then
    cp /etc/postgresql/postgresql.conf "\$PGDATA/postgresql.conf"
    echo "Copied postgresql.conf to \$PGDATA"
fi
if [ -f /etc/postgresql/pg_hba.conf ]; then
    cp /etc/postgresql/pg_hba.conf "\$PGDATA/pg_hba.conf"
    echo "Copied pg_hba.conf to \$PGDATA"
fi

# Inject archive_command with the per-node stanza
echo "=== Injecting archive_command for stanza '${PGBACKREST_STANZA}' ==="
cat >> "\$PGDATA/postgresql.conf" <<ARCHEOF

# --- pgBackRest archive command (injected by entrypoint) ---
archive_command = 'pgbackrest --stanza=${PGBACKREST_STANZA} archive-push %p'
ARCHEOF
echo "archive_command injected"
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
# Background: pgBackRest stanza creation + initial full backup
# Only runs on the primary coordinator (workers have their own stanzas).
# ---------------------------------------------------------------------------
init_pgbackrest_bg() {
    local stanza="$PGBACKREST_STANZA"
    (
        # Wait for PostgreSQL to be ready
        sleep 5
        local max_wait=60
        for i in $(seq 1 "$max_wait"); do
            if pg_isready -h /var/run/postgresql -p 5432 -U "${POSTGRES_USER:-postgres}" -q 2>/dev/null; then
                break
            fi
            sleep 1
        done

        # Wait for archive_mode=on — the docker-entrypoint runs initdb.d scripts
        # then restarts PG, so archive_mode isn't visible until after that restart.
        echo "=== [pgbackrest] Waiting for archive_mode=on ==="
        for i in $(seq 1 60); do
            local am
            am=$(gosu postgres psql -h /var/run/postgresql -U "${POSTGRES_USER:-postgres}" -d postgres -tAc "SHOW archive_mode;" 2>/dev/null) || am=""
            if [ "$am" = "on" ]; then
                echo "=== [pgbackrest] archive_mode=on confirmed ==="
                break
            fi
            sleep 2
        done

        echo "=== [pgbackrest] Initializing stanza '${stanza}' ==="
        gosu postgres pgbackrest --stanza="$stanza" stanza-create 2>&1 || echo "=== [pgbackrest] WARN: stanza-create failed (may already exist) ==="

        echo "=== [pgbackrest] Running check ==="
        gosu postgres pgbackrest --stanza="$stanza" check 2>&1 || echo "=== [pgbackrest] WARN: check failed ==="

        echo "=== [pgbackrest] Creating initial full backup (background) ==="
        gosu postgres pgbackrest --stanza="$stanza" --type=full backup > /var/log/pgbackrest/initial-backup.log 2>&1 || echo "=== [pgbackrest] WARN: initial backup failed ==="

        echo "=== [pgbackrest] Initialization complete (stanza='${stanza}') ==="
    ) > /tmp/pgbackrest-init.log 2>&1 &
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
    init_pgbackrest_bg
fi
start_failover_monitor_bg

# Wait for PG — this keeps the container alive
wait $PG_PID
exit $?
