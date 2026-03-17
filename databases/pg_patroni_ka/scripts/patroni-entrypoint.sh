#!/bin/bash
# =============================================================================
# Custom entrypoint for Patroni + keepalived
# =============================================================================
# This script:
#   1. Generates keepalived.conf from the template + environment variables
#   2. Starts keepalived as a background daemon (waits for Patroni to be ready)
#   3. Execs into Patroni (PID 1)
# =============================================================================
set -e

# ---------------------------------------------------------------------------
# Generate keepalived.conf from template + environment variables
# ---------------------------------------------------------------------------
generate_keepalived_conf() {
    local node_name="${PATRONI_NAME:-pg-node1}"
    local my_ip="${MY_IP:-}"
    local vip="${KEEPALIVED_VIP:-172.30.0.100}"
    local vrid="${KEEPALIVED_VRID:-53}"
    local node1_ip="${PG_NODE1_IP:-172.30.0.11}"
    local node2_ip="${PG_NODE2_IP:-172.30.0.12}"
    local node3_ip="${PG_NODE3_IP:-172.30.0.13}"

    # Determine priority based on node name
    # ALL nodes start as BACKUP — required for nopreempt to work.
    # The highest-priority healthy node wins the initial election.
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

    # Generate config from template
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
# Start keepalived as a background daemon
# Waits for Patroni to be healthy before starting.
# keepalived-check.sh runs every 3s to determine if this node should hold VIP.
# ---------------------------------------------------------------------------
nohup setsid bash -c '
    trap "exit 0" ERR EXIT

    # Wait for Patroni API to be responding
    attempts=0
    while true; do
        code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8008/health 2>/dev/null || echo "000")
        if [ "$code" = "200" ]; then
            break
        fi
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 90 ]; then
            echo "=== [keepalived] ERROR: Patroni not ready after 180s, giving up ==="
            exit 0
        fi
        sleep 2
    done

    # Brief delay for cluster to stabilize
    sleep 10

    echo "=== [keepalived] Starting keepalived daemon ==="
    exec keepalived --no-syslog --log-console --log-detail --dont-fork \
        -f /etc/keepalived/keepalived.conf
' > /tmp/keepalived.log 2>&1 &
disown

# ---------------------------------------------------------------------------
# Ensure postgres user owns all required directories
# (keepalived stays root-owned; Patroni/PG/pgBackRest need postgres ownership)
# ---------------------------------------------------------------------------
mkdir -p /tmp/pgbackrest
chown -R postgres:postgres /var/lib/postgresql /run/postgresql \
    /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest /tmp/pgbackrest

# ---------------------------------------------------------------------------
# Exec into Patroni as postgres user (becomes PID 1)
# keepalived background process continues running as root (required for VIP mgmt)
# ---------------------------------------------------------------------------
exec gosu postgres patroni /etc/patroni/patroni.yml
