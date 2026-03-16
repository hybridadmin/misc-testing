#!/bin/bash
# =============================================================================
# Worker Entrypoint for Citus 14.0 Distributed Cluster
# =============================================================================
# Copies custom configs into PGDATA on first run, generates per-node
# pgBackRest config, and creates stanza + initial backup in background.
# The Citus image handles extension creation via initdb.d scripts.
# =============================================================================
set -e

# Each worker has its own system-id (independent initdb) -> own stanza.
# PGBACKREST_STANZA is set via environment in docker-compose.yml.
: "${PGBACKREST_STANZA:=pg-citus-worker}"
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
    echo "=== [worker] Generated pgbackrest.conf with stanza='${stanza}' ==="
}

# Ensure pgBackRest directories exist
for dir in /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest; do
    mkdir -p "$dir" 2>/dev/null || true
    chown postgres:postgres "$dir" 2>/dev/null || true
done

generate_pgbackrest_conf "$PGBACKREST_STANZA"

# ---------------------------------------------------------------------------
# Init script: copy custom configs + inject archive_command
# ---------------------------------------------------------------------------
mkdir -p /docker-entrypoint-initdb.d

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
# Background: pgBackRest stanza creation + initial full backup
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
# Start PG via docker-entrypoint in background, then pgBackRest init, wait
# ---------------------------------------------------------------------------
docker-entrypoint.sh "$@" &
PG_PID=$!

init_pgbackrest_bg

# Wait for PG — this keeps the container alive
wait $PG_PID
exit $?
