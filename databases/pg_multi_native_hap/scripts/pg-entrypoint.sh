#!/bin/bash
# =============================================================================
# Custom entrypoint for PG18 multi-master nodes
# Wraps the official postgres Docker entrypoint, adding:
#   1. Custom postgresql.conf and pg_hba.conf
#   2. Post-init hook to create replication user and appdb
#   3. Background replication setup after PG is fully up
# =============================================================================
set -e

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
