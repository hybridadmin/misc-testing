#!/bin/bash
# =============================================================================
# Custom entrypoint for PG18 multi-master nodes (pglogical + keepalived variant)
# =============================================================================
# Key differences from the HAProxy variant:
#   - No socat health agent (keepalived replaces HAProxy)
#   - Starts keepalived as a background daemon
#   - keepalived-check.sh IS the watchdog (runs every 3s via vrrp_script)
#   - No separate fence-watchdog loop needed (keepalived check handles it)
# =============================================================================
set -e

# ---------------------------------------------------------------------------
# pgBackRest configuration generator (called at container start)
# Each node has its own stanza because each is an independent initdb.
# ---------------------------------------------------------------------------
generate_pgbackrest_conf() {
    local stanza="${PGBACKREST_STANZA:-pg-mmk-node}"
    local pgdata="${PGDATA:-/var/lib/postgresql/data}"

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

mkdir -p /docker-entrypoint-initdb.d

cat > /docker-entrypoint-initdb.d/00-init-multimaster.sh << 'INITEOF'
#!/bin/bash
set -e

echo "=== Multi-master init: creating replication user and appdb ==="

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
STANZA="${PGBACKREST_STANZA:-pg-mmk-node}"
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
# Generate keepalived.conf from template + environment variables
# ---------------------------------------------------------------------------
generate_keepalived_conf() {
    local node_name="${NODE_NAME:-pg-node1}"
    local my_ip="${MY_IP:-}"
    local vip="${KEEPALIVED_VIP:-172.32.0.100}"
    local vrid="${KEEPALIVED_VRID:-51}"
    local node1_ip="${PG_NODE1_IP:-172.32.0.11}"
    local node2_ip="${PG_NODE2_IP:-172.32.0.12}"
    local node3_ip="${PG_NODE3_IP:-172.32.0.13}"

    # Determine priority and state based on node name
    # ALL nodes start as BACKUP — this is required for nopreempt to work.
    # The node with the highest priority wins the initial election.
    # nopreempt ensures that once a BACKUP takes over, it keeps the VIP
    # even if a higher-priority node recovers (prevents VIP flapping).
    local state="BACKUP"
    local priority=90
    case "$node_name" in
        pg-node1) priority=100; my_ip="${my_ip:-$node1_ip}" ;;
        pg-node2) priority=95; my_ip="${my_ip:-$node2_ip}" ;;
        pg-node3) priority=90; my_ip="${my_ip:-$node3_ip}" ;;
    esac

    # Build unicast_peer list (all peers except self)
    local unicast_peers=""
    for ip in $node1_ip $node2_ip $node3_ip; do
        if [ "$ip" != "$my_ip" ]; then
            unicast_peers="${unicast_peers}        ${ip}"$'\n'
        fi
    done

    # Generate config from template using two-pass approach:
    # Pass 1: sed handles all simple single-line substitutions
    # Pass 2: awk handles the multi-line UNICAST_PEERS replacement
    local tmpl="/etc/keepalived/keepalived.conf.tmpl"
    if [ -f "$tmpl" ]; then
        sed -e "s|\${KEEPALIVED_STATE}|$state|g" \
            -e "s|\${KEEPALIVED_VRID}|$vrid|g" \
            -e "s|\${KEEPALIVED_PRIORITY}|$priority|g" \
            -e "s|\${MY_IP}|$my_ip|g" \
            -e "s|\${KEEPALIVED_VIP}|$vip|g" \
            "$tmpl" | awk -v peers="$unicast_peers" '{
                if ($0 ~ /\$\{UNICAST_PEERS\}/) {
                    printf "%s", peers
                } else {
                    print
                }
            }' > /etc/keepalived/keepalived.conf
        echo "=== [keepalived] Generated config for $node_name (state=$state, priority=$priority, ip=$my_ip) ==="
    else
        echo "=== [keepalived] ERROR: template $tmpl not found ==="
    fi
}

generate_keepalived_conf

# ---------------------------------------------------------------------------
# pgBackRest background initialization: stanza-create + full backup
# Runs in background after PG is fully up with archive_mode=on.
# ---------------------------------------------------------------------------
init_pgbackrest_bg() {
    nohup setsid bash -c '
        trap "exit 0" ERR EXIT

        STANZA="'"${STANZA}"'"
        PGDATA="'"${PGDATA:-/var/lib/postgresql/data}"'"

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
# pglogical replication setup: launched as a DETACHED background process
# ---------------------------------------------------------------------------
if [ "${SETUP_REPLICATION:-false}" = "true" ]; then
    nohup setsid bash -c '
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

        echo "=== [repl-setup] PG is accepting connections, waiting for init to complete ==="
        sleep 15

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

        echo "=== [repl-setup] Connected to ${POSTGRES_DB:-appdb}, starting pglogical setup ==="
        /usr/local/bin/setup-replication.sh || true
        echo "=== [repl-setup] Done ==="
    ' > /tmp/repl-setup.log 2>&1 &
    disown
fi

# ---------------------------------------------------------------------------
# Start keepalived as a background daemon
# It needs to run as root (which we are at this point in the entrypoint).
# keepalived will call keepalived-check.sh every 3s — that script acts as
# BOTH the VRRP health check AND the self-fencing watchdog.
# ---------------------------------------------------------------------------
nohup setsid bash -c '
    trap "exit 0" ERR EXIT

    # Wait for PG to be accepting connections before starting keepalived
    attempts=0
    while ! pg_isready -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-postgres}" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 60 ]; then
            echo "=== [keepalived] ERROR: PG not ready after 120s, giving up ==="
            exit 0
        fi
        sleep 2
    done

    # Wait for replication setup to have a chance to complete
    sleep 30

    echo "=== [keepalived] Starting keepalived daemon ==="
    exec keepalived --no-syslog --log-console --log-detail --dont-fork \
        -f /etc/keepalived/keepalived.conf
' > /tmp/keepalived.log 2>&1 &
disown

exec docker-entrypoint.sh "$@"
