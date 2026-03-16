#!/bin/bash
# =============================================================================
# Custom entrypoint for PG18 multi-master nodes (Flyway variant)
# Wraps the official postgres Docker entrypoint, adding:
#   1. Custom postgresql.conf and pg_hba.conf
#   2. Post-init hook to create replication user and appdb
#   3. Background replication setup after PG is fully up
#   4. pgBackRest configuration and background initialization
# =============================================================================
set -e

# ---------------------------------------------------------------------------
# pgBackRest configuration generator (called at container start)
# Each node has its own stanza because each is an independent initdb.
# ---------------------------------------------------------------------------
generate_pgbackrest_conf() {
    local stanza="${PGBACKREST_STANZA:-pg-mmf-node}"
    local pgdata="${PGDATA:-/var/lib/postgresql/18/docker}"

    cat > /etc/pgbackrest/pgbackrest.conf <<PGBR_EOF
[${stanza}]
pg1-path=${pgdata}
pg1-port=5432
pg1-socket-path=/var/run/postgresql

[global]
repo1-path=/var/lib/pgbackrest
repo1-type=posix
repo1-retention-full=2
repo1-retention-diff=3
repo1-retention-archive=2
compress-type=lz4
compress-level=1
archive-async=y
spool-path=/var/spool/pgbackrest
start-fast=y
process-max=2
log-level-console=warn
log-path=/var/log/pgbackrest

[global:archive-push]
compress-level=3
log-level-console=info
PGBR_EOF
    chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
    echo "=== [pgbackrest] Generated config for stanza '${stanza}' ==="
}

# Generate pgBackRest config early (before PG starts)
generate_pgbackrest_conf

# ---------------------------------------------------------------------------
# Post-init script: runs once after initdb (first boot only)
# The official postgres entrypoint runs /docker-entrypoint-initdb.d/*.sh
# ---------------------------------------------------------------------------
mkdir -p /docker-entrypoint-initdb.d

cat > /docker-entrypoint-initdb.d/00-init-multimaster.sh << 'INITEOF'
#!/bin/bash
set -e

echo "=== Multi-master init: creating replication user and appdb ==="

# Create replication user if it doesn't exist
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${POSTGRES_REPL_USER:-replicator}') THEN
            CREATE ROLE ${POSTGRES_REPL_USER:-replicator} WITH LOGIN REPLICATION PASSWORD '${POSTGRES_REPL_PASSWORD:-changeme_repl_2025}';
        END IF;
    END
    \$\$;
SQL

echo "=== Multi-master init complete ==="
INITEOF
chmod +x /docker-entrypoint-initdb.d/00-init-multimaster.sh

# ---------------------------------------------------------------------------
# Copy custom postgresql.conf and pg_hba.conf after initdb
# ---------------------------------------------------------------------------
cat > /docker-entrypoint-initdb.d/01-copy-configs.sh << 'CONFEOF'
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
chmod +x /docker-entrypoint-initdb.d/01-copy-configs.sh

# ---------------------------------------------------------------------------
# Inject archive_command into PGDATA after initdb (per-node stanza)
# We use an initdb.d script so it runs after configs are copied.
# ---------------------------------------------------------------------------
STANZA="${PGBACKREST_STANZA:-pg-mmf-node}"
cat > /docker-entrypoint-initdb.d/02-inject-archive-command.sh << ARCHEOF
#!/bin/bash
set -e
echo "=== Injecting archive_command for stanza '${STANZA}' ==="
cat >> "\$PGDATA/postgresql.conf" <<'PGCONF'

# --- pgBackRest archive commands (injected by entrypoint) ---
archive_command = 'pgbackrest --stanza=${STANZA} archive-push %p'
restore_command = 'pgbackrest --stanza=${STANZA} archive-get %f "%p"'
PGCONF
echo "archive_command set to: pgbackrest --stanza=${STANZA} archive-push %p"
ARCHEOF
chmod +x /docker-entrypoint-initdb.d/02-inject-archive-command.sh

# ---------------------------------------------------------------------------
# pgBackRest background initialization: stanza-create + full backup
# Runs in background after PG is fully up with archive_mode=on.
# ---------------------------------------------------------------------------
init_pgbackrest_bg() {
    nohup setsid bash -c '
        trap "exit 0" ERR EXIT

        STANZA="'"${STANZA}"'"
        PGDATA="'"${PGDATA:-/var/lib/postgresql/18/docker}"'"

        echo "=== [pgbackrest] Waiting for PG to be ready ==="
        attempts=0
        while ! pg_isready -h /var/run/postgresql -U "${POSTGRES_USER:-postgres}" 2>/dev/null; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 90 ]; then
                echo "=== [pgbackrest] ERROR: PG not ready after 180s, giving up ==="
                exit 0
            fi
            sleep 2
        done

        # Wait for archive_mode=on to be effective (initdb.d scripts may trigger restart)
        echo "=== [pgbackrest] Waiting for archive_mode=on ==="
        am_attempts=0
        while true; do
            am=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h /var/run/postgresql -U "${POSTGRES_USER:-postgres}" -d postgres -tAc "SHOW archive_mode;" 2>/dev/null || echo "")
            if [ "$am" = "on" ]; then
                echo "=== [pgbackrest] archive_mode=on confirmed ==="
                break
            fi
            am_attempts=$((am_attempts + 1))
            if [ "$am_attempts" -ge 60 ]; then
                echo "=== [pgbackrest] WARNING: archive_mode not on after 120s, proceeding anyway ==="
                break
            fi
            sleep 2
        done

        # Wait for archive_command to be set
        echo "=== [pgbackrest] Waiting for archive_command ==="
        ac_attempts=0
        while true; do
            ac=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h /var/run/postgresql -U "${POSTGRES_USER:-postgres}" -d postgres -tAc "SHOW archive_command;" 2>/dev/null || echo "")
            if echo "$ac" | grep -q "pgbackrest"; then
                echo "=== [pgbackrest] archive_command confirmed: $ac ==="
                break
            fi
            ac_attempts=$((ac_attempts + 1))
            if [ "$ac_attempts" -ge 60 ]; then
                echo "=== [pgbackrest] WARNING: archive_command not set after 120s, proceeding anyway ==="
                break
            fi
            sleep 2
        done

        # Create stanza
        echo "=== [pgbackrest] Creating stanza ${STANZA} ==="
        if gosu postgres pgbackrest --stanza="$STANZA" stanza-create 2>&1; then
            echo "=== [pgbackrest] Stanza ${STANZA} created ==="
        else
            echo "=== [pgbackrest] WARNING: stanza-create returned non-zero (may already exist) ==="
        fi

        # Run initial full backup
        echo "=== [pgbackrest] Running initial full backup for ${STANZA} ==="
        if gosu postgres pgbackrest --stanza="$STANZA" --type=full backup 2>&1; then
            echo "=== [pgbackrest] Initial full backup complete for ${STANZA} ==="
        else
            echo "=== [pgbackrest] WARNING: full backup returned non-zero ==="
        fi

        echo "=== [pgbackrest] Background init complete ==="
    ' > /tmp/pgbackrest-init.log 2>&1 &
    disown
}

# Start pgBackRest init in background
init_pgbackrest_bg

# ---------------------------------------------------------------------------
# Replication setup: launched as a DETACHED background process
# Uses nohup + trap to ensure it never causes PG (PID 1) to crash
# ---------------------------------------------------------------------------
if [ "${SETUP_REPLICATION:-false}" = "true" ]; then
    nohup setsid bash -c '
        # Trap all errors - never exit non-zero (PG as PID 1 treats child exits as crashes)
        trap "exit 0" ERR EXIT

        echo "=== [repl-setup] Waiting for local PG to be fully ready ==="
        attempts=0
        while ! pg_isready -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-postgres}" 2>/dev/null; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 60 ]; then
                echo "=== [repl-setup] ERROR: local PG not ready after 120s, giving up ==="
                exit 0
            fi
            sleep 2
        done

        # Wait extra for initdb scripts to complete and PG to reload config
        echo "=== [repl-setup] PG is accepting connections, waiting for init to complete ==="
        sleep 15

        # Verify we can actually connect to appdb
        max_db_attempts=30
        db_attempts=0
        while ! PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-appdb}" -tAc "SELECT 1;" >/dev/null 2>&1; do
            db_attempts=$((db_attempts + 1))
            if [ "$db_attempts" -ge "$max_db_attempts" ]; then
                echo "=== [repl-setup] ERROR: cannot connect to ${POSTGRES_DB:-appdb} after 60s ==="
                exit 0
            fi
            sleep 2
        done

        echo "=== [repl-setup] Connected to ${POSTGRES_DB:-appdb}, starting replication setup ==="
        /usr/local/bin/setup-replication.sh || true
        echo "=== [repl-setup] Done ==="
    ' > /tmp/repl-setup.log 2>&1 &
    disown
fi

# ---------------------------------------------------------------------------
# Replication Health Agent for HAProxy agent-check (port 5480)
# Uses socat to listen on TCP 5480 and run the health check script per request.
#
# CRITICAL: socat with "fork" creates child processes. When PG is PID 1, it
# sees these child exits as "untracked child process" and may panic/restart.
# We use setsid to create a NEW process session, so socat's forked children
# are in a separate session and don't propagate to PG (PID 1).
# ---------------------------------------------------------------------------
nohup setsid bash -c '
    trap "exit 0" ERR EXIT

    # Wait for PG to be ready before starting the agent
    attempts=0
    while ! pg_isready -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-postgres}" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 60 ]; then
            echo "=== [health-agent] ERROR: PG not ready after 120s, giving up ==="
            exit 0
        fi
        sleep 2
    done

    echo "=== [health-agent] Starting replication health agent on port 5480 ==="
    exec socat TCP-LISTEN:5480,reuseaddr,fork EXEC:/usr/local/bin/pg-repl-health-agent.sh
' > /tmp/health-agent.log 2>&1 &
disown

# ---------------------------------------------------------------------------
# Delegate to the official postgres Docker entrypoint
# ---------------------------------------------------------------------------
exec docker-entrypoint.sh "$@"
