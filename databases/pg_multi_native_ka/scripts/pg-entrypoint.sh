#!/bin/bash
# =============================================================================
# Custom entrypoint for PG18 multi-master nodes (native replication + keepalived)
# =============================================================================
# Hybrid of pg_multi/ (native replication) + pg_multi_pglogical_ka/ (keepalived).
#   - No pglogical extension — uses PG18 native CREATE PUBLICATION / SUBSCRIPTION
#   - No socat health agent — keepalived replaces HAProxy
#   - Starts keepalived as a background daemon
#   - keepalived-check.sh IS the watchdog (runs every 3s via vrrp_script)
# =============================================================================
set -e

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
# Generate keepalived.conf from template + environment variables
# ---------------------------------------------------------------------------
generate_keepalived_conf() {
    local node_name="${NODE_NAME:-pg-node1}"
    local my_ip="${MY_IP:-}"
    local vip="${KEEPALIVED_VIP:-172.33.0.100}"
    local vrid="${KEEPALIVED_VRID:-52}"
    local node1_ip="${PG_NODE1_IP:-172.33.0.11}"
    local node2_ip="${PG_NODE2_IP:-172.33.0.12}"
    local node3_ip="${PG_NODE3_IP:-172.33.0.13}"

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
# Native replication setup: launched as a DETACHED background process
# Uses nohup + trap to ensure it never causes PG (PID 1) to crash
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

        echo "=== [repl-setup] Connected to ${POSTGRES_DB:-appdb}, starting native replication setup ==="
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
