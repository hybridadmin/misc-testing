#!/bin/bash
# =============================================================================
# Cluster Management Script
# Usage: ./manage.sh [command]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Load env
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

PATRONI_USER="${PATRONI_RESTAPI_USERNAME:-patroni}"
PATRONI_PASS="${PATRONI_RESTAPI_PASSWORD:-changeme_patroni_2025}"

cmd_status() {
    log_info "=== Cluster Status ==="
    echo ""

    log_info "Patroni Cluster:"
    for node in pg-node1 pg-node2 pg-node3; do
        RESP=$(docker exec "$node" curl -s "http://localhost:8008/patroni" 2>/dev/null || echo '{"state":"unreachable"}')
        STATE=$(echo "$RESP" | jq -r '.state // "unknown"')
        ROLE=$(echo "$RESP" | jq -r '.role // "unknown"')
        TL=$(echo "$RESP" | jq -r '.timeline // "?"')
        LAG=$(echo "$RESP" | jq -r '.replication_state // "N/A"')
        if [ "$ROLE" = "master" ] || [ "$ROLE" = "primary" ]; then
            log_ok "$node: role=$ROLE state=$STATE timeline=$TL (PRIMARY)"
        elif [ "$STATE" = "unreachable" ]; then
            log_error "$node: UNREACHABLE"
        else
            log_info "$node: role=$ROLE state=$STATE timeline=$TL"
        fi
    done

    echo ""
    log_info "etcd Cluster:"
    docker exec etcd1 etcdctl endpoint health --cluster \
        --endpoints=http://etcd1:2379,http://etcd2:2379,http://etcd3:2379 2>/dev/null || log_error "etcd unreachable"

    echo ""
    log_info "HAProxy Stats: http://localhost:${HAPROXY_STATS_PORT:-7000}/stats"
    log_info "  Write endpoint (primary):  localhost:${HAPROXY_WRITE_PORT:-5432}"
    log_info "  Read endpoint (replicas):  localhost:${HAPROXY_READ_PORT:-5433}"

    echo ""
    log_info "Valkey Cluster:"
    docker exec valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning INFO replication 2>/dev/null | grep -E "role:|connected_slaves:" || log_error "Valkey unreachable"
}

cmd_failover() {
    local target="${1:-}"
    log_info "Triggering failover..."
    if [ -n "$target" ]; then
        log_info "Target: $target"
        docker exec pg-node1 curl -s -u "${PATRONI_USER}:${PATRONI_PASS}" \
            -XPOST "http://localhost:8008/failover" \
            -H "Content-Type: application/json" \
            -d "{\"leader\": \"\", \"candidate\": \"$target\"}" || true
    else
        docker exec pg-node1 curl -s -u "${PATRONI_USER}:${PATRONI_PASS}" \
            -XPOST "http://localhost:8008/switchover" \
            -H "Content-Type: application/json" \
            -d '{}' || true
    fi
    sleep 5
    cmd_status
}

cmd_reinit() {
    local node="${1:?Usage: manage.sh reinit <node-name>}"
    log_warn "Reinitializing $node - this will wipe its data!"
    docker exec "$node" curl -s -u "${PATRONI_USER}:${PATRONI_PASS}" \
        -XPOST "http://localhost:8008/reinitialize" \
        -H "Content-Type: application/json"
    log_ok "Reinit triggered for $node"
}

cmd_psql() {
    local port="${1:-5432}"
    shift 2>/dev/null || true
    log_info "Connecting to PostgreSQL via localhost:$port..."
    PGPASSWORD="${POSTGRES_PASSWORD:-changeme_postgres_2025}" psql \
        -h localhost -p "$port" \
        -U "${POSTGRES_USER:-postgres}" \
        -d "${POSTGRES_DB:-appdb}" "$@"
}

cmd_valkey_cli() {
    docker exec -it valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning "$@"
}

cmd_logs() {
    local service="${1:-}"
    if [ -n "$service" ]; then
        docker compose -f "$PROJECT_DIR/docker-compose.yml" logs -f "$service"
    else
        docker compose -f "$PROJECT_DIR/docker-compose.yml" logs -f
    fi
}

cmd_bench() {
    local db="${POSTGRES_DB:-appdb}"
    local user="${POSTGRES_USER:-postgres}"
    local pass="${POSTGRES_PASSWORD:-changeme_postgres_2025}"

    # Ensure target database exists
    log_info "Ensuring database '$db' exists..."
    docker exec pg-node1 bash -c \
        "PGPASSWORD='$pass' psql -h haproxy-pg -p 5432 -U $user -d postgres -tc \"SELECT 1 FROM pg_database WHERE datname='$db'\" | grep -q 1 || \
         PGPASSWORD='$pass' psql -h haproxy-pg -p 5432 -U $user -d postgres -c \"CREATE DATABASE $db OWNER $user;\""

    log_info "Running pgbench initialization (scale=10)..."
    docker exec pg-node1 bash -c \
        "PGPASSWORD='$pass' pgbench -i -s 10 -h haproxy-pg -p 5432 -U $user $db"

    log_info "Running pgbench write test (30s, 10 clients)..."
    docker exec pg-node1 bash -c \
        "PGPASSWORD='$pass' pgbench -T 30 -c 10 -j 4 -h haproxy-pg -p 5432 -U $user $db"

    log_info "Running pgbench read test (30s, 20 clients, select-only)..."
    docker exec pg-node1 bash -c \
        "PGPASSWORD='$pass' pgbench -T 30 -c 20 -j 4 -S -h haproxy-pg -p 5433 -U $user $db"
}

cmd_help() {
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  status              Show cluster status"
    echo "  failover [node]     Trigger failover (optional: target node)"
    echo "  reinit <node>       Reinitialize a failed node"
    echo "  psql [port]         Connect via psql (default: 5432=write, 5433=read)"
    echo "  valkey-cli          Connect to Valkey CLI"
    echo "  logs [service]      Tail logs (optionally for specific service)"
    echo "  bench               Run pgbench benchmark"
    echo "  help                Show this help"
}

case "${1:-help}" in
    status)     cmd_status ;;
    failover)   cmd_failover "${2:-}" ;;
    reinit)     cmd_reinit "${2:-}" ;;
    psql)       cmd_psql "${2:-5432}" "${@:3}" ;;
    valkey-cli) shift; cmd_valkey_cli "$@" ;;
    logs)       cmd_logs "${2:-}" ;;
    bench)      cmd_bench ;;
    help|*)     cmd_help ;;
esac
