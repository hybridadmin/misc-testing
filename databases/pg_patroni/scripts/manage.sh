#!/bin/bash
# =============================================================================
# pg_patroni — Management CLI
# PostgreSQL 18 HA with Patroni + etcd + HAProxy + PgBouncer + Valkey
# Usage: ./manage.sh [command] [args...]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_head()  { echo -e "\n${CYAN}$*${NC}"; }

# --- Source .env ---
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a; source "$PROJECT_DIR/.env"; set +a
fi

# --- Derived variables ---
COMPOSE="docker compose -f $PROJECT_DIR/docker-compose.yml"
PGPASSWORD="${POSTGRES_PASSWORD:-changeme_postgres_2025}"
PG_USER="${POSTGRES_USER:-postgres}"
PG_DB="${POSTGRES_DB:-appdb}"

# Ports
HAPROXY_RW_PORT="${HAPROXY_PORT_RW:-5050}"
HAPROXY_RO_PORT="${HAPROXY_PORT_RO:-5051}"
PGBOUNCER_PORT_LOCAL="${PGBOUNCER_PORT:-6432}"
NODE1_PORT="${PG_NODE1_PORT:-6041}"
NODE2_PORT="${PG_NODE2_PORT:-6042}"
NODE3_PORT="${PG_NODE3_PORT:-6043}"
API1_PORT="${PATRONI1_API_PORT:-8041}"
API2_PORT="${PATRONI2_API_PORT:-8042}"
API3_PORT="${PATRONI3_API_PORT:-8043}"

# --- SQL helpers ---
run_sql() {
    PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null
}

run_sql_ro() {
    PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RO_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null
}

run_sql_on() {
    local port="$1"; local sql="$2"
    PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "$sql" 2>/dev/null
}

run_sql_fmt() {
    local port="$1"; local sql="$2"
    PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "$sql" 2>/dev/null
}

# =============================================================================
# Commands
# =============================================================================

cmd_status() {
    log_head "=== Patroni Cluster Status ==="

    # Container status
    log_head "--- Containers ---"
    docker ps --filter "name=pat-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null

    # Patroni cluster members via REST API
    log_head "--- Patroni Members ---"
    for port in $API1_PORT $API2_PORT $API3_PORT; do
        local resp
        resp=$(curl -s "http://localhost:$port/patroni" 2>/dev/null) || continue
        local name role state
        name=$(echo "$resp" | jq -r '.patroni.name // "?"' 2>/dev/null)
        role=$(echo "$resp" | jq -r '.role // "?"' 2>/dev/null)
        state=$(echo "$resp" | jq -r '.state // "?"' 2>/dev/null)
        local sync=""
        if echo "$resp" | jq -e '.sync_standby' >/dev/null 2>&1; then
            sync=" (sync)"
        fi
        if [ "$role" = "master" ] || [ "$role" = "primary" ]; then
            echo -e "  ${GREEN}$name${NC}: $role ($state)$sync [API: :$port]"
        elif [ "$role" = "sync_standby" ]; then
            echo -e "  ${CYAN}$name${NC}: $role ($state) [API: :$port]"
        else
            echo -e "  ${YELLOW}$name${NC}: $role ($state) [API: :$port]"
        fi
    done

    # etcd cluster health
    log_head "--- etcd Cluster ---"
    docker exec pat-etcd1 etcdctl endpoint health \
        --endpoints=http://etcd1:2379,http://etcd2:2379,http://etcd3:2379 2>&1 || echo "  etcd unreachable"

    # HAProxy status
    log_head "--- HAProxy ---"
    local ha_rw ha_ro
    ha_rw=$(PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT inet_server_addr() || ' (' || CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END || ')'" 2>/dev/null) || ha_rw="unreachable"
    ha_ro=$(PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RO_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT inet_server_addr() || ' (' || CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END || ')'" 2>/dev/null) || ha_ro="unreachable"
    echo "  RW port $HAPROXY_RW_PORT → $ha_rw"
    echo "  RO port $HAPROXY_RO_PORT → $ha_ro"
    echo "  Stats: http://localhost:${HAPROXY_STATS_PORT:-7070}/stats"

    # PgBouncer
    log_head "--- PgBouncer ---"
    local pgb
    pgb=$(PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$PGBOUNCER_PORT_LOCAL" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT 1" 2>/dev/null) && \
        echo "  Port $PGBOUNCER_PORT_LOCAL: connected (pool_mode=${PGBOUNCER_POOL_MODE:-transaction})" || \
        echo "  Port $PGBOUNCER_PORT_LOCAL: unreachable"

    # Valkey
    log_head "--- Valkey ---"
    local vk
    vk=$(docker exec pat-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning INFO replication 2>/dev/null | grep "role:") || vk="unreachable"
    echo "  Master: ${vk:-unreachable}"
}

cmd_topology() {
    log_head "=== Cluster Topology ==="

    # patronictl list
    log_head "--- Patroni Cluster List ---"
    docker exec pat-node1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || \
        log_warn "patronictl unavailable"

    # Replication status from primary
    log_head "--- Replication Status ---"
    local primary_port=""
    for port in $NODE1_PORT $NODE2_PORT $NODE3_PORT; do
        local is_primary
        is_primary=$(PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$port" -U "$PG_USER" -d postgres -tAc "SELECT NOT pg_is_in_recovery()" 2>/dev/null) || continue
        if [ "$is_primary" = "t" ]; then
            primary_port="$port"
            break
        fi
    done

    if [ -n "$primary_port" ]; then
        PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$primary_port" -U "$PG_USER" -d postgres -c "
            SELECT client_addr, application_name, state, sync_state,
                   sent_lsn, write_lsn, flush_lsn, replay_lsn,
                   pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
            FROM pg_stat_replication
            ORDER BY application_name;" 2>/dev/null || log_warn "Could not query replication"
    else
        log_warn "No primary found"
    fi

    # etcd key for leader
    log_head "--- etcd Leader Key ---"
    docker exec pat-etcd1 etcdctl get /service/pg-patroni/leader --print-value-only 2>/dev/null || echo "  not set"
}

cmd_psql() {
    local target="${1:-primary}"
    case "$target" in
        primary|rw|p)
            log_info "Connecting to PRIMARY via HAProxy (:$HAPROXY_RW_PORT)"
            PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW_PORT" -U "$PG_USER" -d "$PG_DB"
            ;;
        replica|ro|r)
            log_info "Connecting to REPLICA via HAProxy (:$HAPROXY_RO_PORT)"
            PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RO_PORT" -U "$PG_USER" -d "$PG_DB"
            ;;
        bouncer|pgb|b)
            log_info "Connecting via PgBouncer (:$PGBOUNCER_PORT_LOCAL)"
            PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$PGBOUNCER_PORT_LOCAL" -U "$PG_USER" -d "$PG_DB"
            ;;
        node1|n1|1)
            log_info "Connecting directly to node1 (:$NODE1_PORT)"
            PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$NODE1_PORT" -U "$PG_USER" -d "$PG_DB"
            ;;
        node2|n2|2)
            log_info "Connecting directly to node2 (:$NODE2_PORT)"
            PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$NODE2_PORT" -U "$PG_USER" -d "$PG_DB"
            ;;
        node3|n3|3)
            log_info "Connecting directly to node3 (:$NODE3_PORT)"
            PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$NODE3_PORT" -U "$PG_USER" -d "$PG_DB"
            ;;
        *)
            log_error "Unknown target: $target"
            echo "  Targets: primary|rw, replica|ro, bouncer|pgb, node1|n1, node2|n2, node3|n3"
            exit 1
            ;;
    esac
}

cmd_failover() {
    log_head "=== Patroni Failover ==="
    log_warn "This will trigger a leader election and promote a new primary."
    read -r -p "Proceed? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        log_info "Cancelled."
        return
    fi
    docker exec -it pat-node1 patronictl -c /etc/patroni/patroni.yml failover 2>/dev/null || \
    docker exec -it pat-node2 patronictl -c /etc/patroni/patroni.yml failover 2>/dev/null || \
    docker exec -it pat-node3 patronictl -c /etc/patroni/patroni.yml failover 2>/dev/null || \
        log_error "Failover failed — no Patroni node reachable"
}

cmd_switchover() {
    log_head "=== Patroni Switchover ==="
    log_info "Graceful primary switchover (zero downtime)."
    read -r -p "Proceed? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        log_info "Cancelled."
        return
    fi
    docker exec -it pat-node1 patronictl -c /etc/patroni/patroni.yml switchover 2>/dev/null || \
    docker exec -it pat-node2 patronictl -c /etc/patroni/patroni.yml switchover 2>/dev/null || \
    docker exec -it pat-node3 patronictl -c /etc/patroni/patroni.yml switchover 2>/dev/null || \
        log_error "Switchover failed — no Patroni node reachable"
}

cmd_reinit() {
    log_head "=== Full Cluster Reinit ==="
    log_warn "This will DESTROY ALL DATA and recreate the cluster."
    read -r -p "Type 'yes' to confirm: " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Cancelled."
        return
    fi
    log_info "Stopping cluster..."
    $COMPOSE down -v
    log_info "Starting cluster..."
    $COMPOSE up -d
    log_info "Waiting for cluster to stabilize (30s)..."
    sleep 30
    cmd_status
}

cmd_test() {
    log_head "=== Integration Tests ==="
    local errors=0
    local test_num=0

    # Helper
    run_test() {
        test_num=$((test_num + 1))
        local desc="$1"
        echo -n "  Test $test_num: $desc ... "
    }

    pass() { echo -e "${GREEN}PASS${NC}"; }
    fail() { echo -e "${RED}FAIL${NC} — $*"; errors=$((errors + 1)); }

    # --- Wait for cluster ---
    log_info "Checking cluster readiness..."
    local ready=false
    for i in $(seq 1 10); do
        if PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT 1" >/dev/null 2>&1; then
            ready=true; break
        fi
        sleep 2
    done
    if ! $ready; then
        log_error "Cluster not ready after 20s. Aborting tests."
        exit 1
    fi

    # Test 1: HAProxy RW routes to primary
    run_test "HAProxy RW routes to primary"
    local is_primary
    is_primary=$(PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT NOT pg_is_in_recovery()" 2>/dev/null)
    [ "$is_primary" = "t" ] && pass || fail "RW port not routing to primary"

    # Test 2: HAProxy RO routes to replica
    run_test "HAProxy RO routes to replica"
    local is_replica
    is_replica=$(PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RO_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT pg_is_in_recovery()" 2>/dev/null)
    [ "$is_replica" = "t" ] && pass || fail "RO port not routing to replica"

    # Test 3: PgBouncer connectivity
    run_test "PgBouncer connectivity"
    local pgb_result
    pgb_result=$(PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$PGBOUNCER_PORT_LOCAL" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT 1" 2>/dev/null)
    [ "$pgb_result" = "1" ] && pass || fail "PgBouncer not responding"

    # Test 4: Write via HAProxy
    run_test "Write via HAProxy RW"
    run_sql "DROP TABLE IF EXISTS _test_patroni; CREATE TABLE _test_patroni (id serial PRIMARY KEY, val text, ts timestamptz DEFAULT now());" >/dev/null 2>&1
    run_sql "INSERT INTO _test_patroni (val) VALUES ('hello_patroni');" >/dev/null 2>&1
    local write_result
    write_result=$(run_sql "SELECT val FROM _test_patroni WHERE val = 'hello_patroni'")
    [ "$write_result" = "hello_patroni" ] && pass || fail "Write failed"

    # Test 5: Read from replica (replication lag test)
    run_test "Read replicated data from replica"
    sleep 1  # allow replication
    local read_result
    read_result=$(run_sql_ro "SELECT val FROM _test_patroni WHERE val = 'hello_patroni'")
    [ "$read_result" = "hello_patroni" ] && pass || fail "Replication lag or failure"

    # Test 6: Write via PgBouncer
    run_test "Write via PgBouncer"
    PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$PGBOUNCER_PORT_LOCAL" -U "$PG_USER" -d "$PG_DB" -tAc \
        "INSERT INTO _test_patroni (val) VALUES ('via_pgbouncer');" >/dev/null 2>&1
    local pgb_write
    pgb_write=$(PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$PGBOUNCER_PORT_LOCAL" -U "$PG_USER" -d "$PG_DB" -tAc \
        "SELECT val FROM _test_patroni WHERE val = 'via_pgbouncer'" 2>/dev/null)
    [ "$pgb_write" = "via_pgbouncer" ] && pass || fail "PgBouncer write failed"

    # Test 7: Synchronous replication is active
    run_test "Synchronous replication active"
    local sync_state
    sync_state=$(PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW_PORT" -U "$PG_USER" -d postgres -tAc \
        "SELECT count(*) FROM pg_stat_replication WHERE sync_state = 'sync'" 2>/dev/null)
    [ "${sync_state:-0}" -ge 1 ] && pass || fail "No sync replica found (got: ${sync_state:-none})"

    # Test 8: etcd cluster healthy
    run_test "etcd cluster healthy (3 members)"
    local etcd_health
    etcd_health=$(docker exec pat-etcd1 etcdctl member list --write-out=simple 2>/dev/null | grep -c "started") || etcd_health=0
    [ "$etcd_health" -eq 3 ] && pass || fail "Expected 3 etcd members, got $etcd_health"

    # Test 9: Patroni REST API responds on all nodes
    run_test "Patroni REST API on all 3 nodes"
    local api_ok=0
    for port in $API1_PORT $API2_PORT $API3_PORT; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/patroni" 2>/dev/null) || code=0
        [ "$code" = "200" ] && api_ok=$((api_ok + 1))
    done
    [ "$api_ok" -eq 3 ] && pass || fail "Only $api_ok/3 Patroni APIs responding"

    # Test 10: Valkey master is writable
    run_test "Valkey master write/read"
    docker exec pat-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning SET _test_patroni "hello" >/dev/null 2>&1
    local vk_result
    vk_result=$(docker exec pat-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning GET _test_patroni 2>/dev/null)
    [ "$vk_result" = "hello" ] && pass || fail "Valkey write/read failed"

    # Test 11: Valkey replication
    run_test "Valkey replication to replicas"
    local vk_repl
    vk_repl=$(docker exec pat-valkey-replica1 valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning GET _test_patroni 2>/dev/null)
    [ "$vk_repl" = "hello" ] && pass || fail "Valkey replication failed"

    # Test 12: Multiple writes + reads via PgBouncer (connection pooling stress)
    run_test "Bulk writes via PgBouncer (100 rows)"
    PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$PGBOUNCER_PORT_LOCAL" -U "$PG_USER" -d "$PG_DB" -tAc \
        "INSERT INTO _test_patroni (val) SELECT 'bulk_' || generate_series(1,100);" >/dev/null 2>&1
    local bulk_count
    bulk_count=$(PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$PGBOUNCER_PORT_LOCAL" -U "$PG_USER" -d "$PG_DB" -tAc \
        "SELECT count(*) FROM _test_patroni WHERE val LIKE 'bulk_%'" 2>/dev/null)
    [ "${bulk_count:-0}" -eq 100 ] && pass || fail "Expected 100 rows, got ${bulk_count:-0}"

    # Cleanup
    run_sql "DROP TABLE IF EXISTS _test_patroni;" >/dev/null 2>&1
    docker exec pat-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning DEL _test_patroni >/dev/null 2>&1

    # Summary
    echo ""
    if [ "$errors" -eq 0 ]; then
        log_ok "All $test_num tests passed!"
    else
        log_error "$errors/$test_num tests failed"
        exit 1
    fi
}

cmd_bench() {
    log_head "=== Benchmark ==="

    # Ensure pgbench tables exist
    log_info "Initializing pgbench tables (scale 10)..."
    PGPASSWORD="$PGPASSWORD" pgbench -h localhost -p "$HAPROXY_RW_PORT" -U "$PG_USER" -d "$PG_DB" -i -s 10 2>&1 | tail -3

    # Part 1: Standard TPC-B via HAProxy RW
    log_head "--- Part 1: TPC-B Write (HAProxy RW, 60s) ---"
    PGPASSWORD="$PGPASSWORD" pgbench -h localhost -p "$HAPROXY_RW_PORT" -U "$PG_USER" -d "$PG_DB" \
        -c 10 -j 2 -T 60 --no-vacuum 2>&1 | grep -E "^(tps|number|latency)"

    # Part 2: SELECT-only via HAProxy RO
    log_head "--- Part 2: SELECT-only Read (HAProxy RO, 60s) ---"
    PGPASSWORD="$PGPASSWORD" pgbench -h localhost -p "$HAPROXY_RO_PORT" -U "$PG_USER" -d "$PG_DB" \
        -c 10 -j 2 -T 60 -S --no-vacuum 2>&1 | grep -E "^(tps|number|latency)"

    # Part 3: Via PgBouncer
    log_head "--- Part 3: TPC-B Write (PgBouncer, 60s) ---"
    PGPASSWORD="$PGPASSWORD" pgbench -h localhost -p "$PGBOUNCER_PORT_LOCAL" -U "$PG_USER" -d "$PG_DB" \
        -c 10 -j 2 -T 60 --no-vacuum 2>&1 | grep -E "^(tps|number|latency)"

    # Cleanup
    log_info "Cleaning up pgbench tables..."
    run_sql "DROP TABLE IF EXISTS pgbench_accounts, pgbench_branches, pgbench_tellers, pgbench_history;" >/dev/null 2>&1
    log_ok "Benchmark complete"
}

cmd_logs() {
    local target="${1:-all}"
    case "$target" in
        all)        $COMPOSE logs -f --tail=50 ;;
        patroni|pg) $COMPOSE logs -f --tail=50 patroni1 patroni2 patroni3 ;;
        etcd)       $COMPOSE logs -f --tail=50 etcd1 etcd2 etcd3 ;;
        haproxy|ha) $COMPOSE logs -f --tail=50 haproxy ;;
        pgbouncer|pgb) $COMPOSE logs -f --tail=50 pgbouncer ;;
        valkey|vk)  $COMPOSE logs -f --tail=50 valkey-master valkey-replica1 valkey-replica2 ;;
        sentinel)   $COMPOSE logs -f --tail=50 valkey-sentinel1 valkey-sentinel2 valkey-sentinel3 ;;
        node1|n1|1) $COMPOSE logs -f --tail=50 patroni1 ;;
        node2|n2|2) $COMPOSE logs -f --tail=50 patroni2 ;;
        node3|n3|3) $COMPOSE logs -f --tail=50 patroni3 ;;
        *)
            log_error "Unknown target: $target"
            echo "  Targets: all, patroni, etcd, haproxy, pgbouncer, valkey, sentinel, node1, node2, node3"
            exit 1
            ;;
    esac
}

cmd_patronictl() {
    # Forward any patronictl command to a running node
    local node="pat-node1"
    if ! docker inspect "$node" --format='{{.State.Running}}' 2>/dev/null | grep -q true; then
        node="pat-node2"
    fi
    if ! docker inspect "$node" --format='{{.State.Running}}' 2>/dev/null | grep -q true; then
        node="pat-node3"
    fi
    docker exec -it "$node" patronictl -c /etc/patroni/patroni.yml "$@"
}

cmd_help() {
    echo "pg_patroni — PostgreSQL 18 HA with Patroni + etcd + HAProxy + PgBouncer + Valkey"
    echo ""
    echo "Usage: ./manage.sh [command] [args...]"
    echo ""
    echo "Info:"
    echo "  status              Cluster health overview"
    echo "  topology            Detailed replication/etcd topology"
    echo "  logs [target]       Stream logs (all|patroni|etcd|haproxy|pgbouncer|valkey|sentinel|node1..3)"
    echo ""
    echo "Access:"
    echo "  psql [target]       Interactive psql (primary|replica|bouncer|node1..3)"
    echo "  patronictl [args]   Run patronictl commands (e.g., list, show-config, edit-config)"
    echo ""
    echo "HA Operations:"
    echo "  switchover          Graceful primary switchover (zero downtime)"
    echo "  failover            Emergency failover (promotes best candidate)"
    echo "  reinit              Full cluster reinit (DESTROYS ALL DATA)"
    echo ""
    echo "Test & Benchmark:"
    echo "  test                Run integration tests (12 tests)"
    echo "  bench               Run pgbench benchmarks (TPC-B + SELECT-only + PgBouncer)"
    echo ""
    echo "Connection Info:"
    echo "  HAProxy RW:    localhost:${HAPROXY_RW_PORT} (primary)"
    echo "  HAProxy RO:    localhost:${HAPROXY_RO_PORT} (replicas)"
    echo "  PgBouncer:     localhost:${PGBOUNCER_PORT_LOCAL} (pooled)"
    echo "  Node 1 direct: localhost:${NODE1_PORT}"
    echo "  Node 2 direct: localhost:${NODE2_PORT}"
    echo "  Node 3 direct: localhost:${NODE3_PORT}"
    echo "  HAProxy Stats: http://localhost:${HAPROXY_STATS_PORT:-7070}/stats"
}

# =============================================================================
# Main dispatch
# =============================================================================

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    status)              cmd_status ;;
    topology|topo)       cmd_topology ;;
    psql)                cmd_psql "$@" ;;
    switchover|switch)   cmd_switchover ;;
    failover)            cmd_failover ;;
    reinit)              cmd_reinit ;;
    test)                cmd_test ;;
    bench|benchmark)     cmd_bench ;;
    logs|log)            cmd_logs "$@" ;;
    patronictl|pctl)     cmd_patronictl "$@" ;;
    help|--help|-h)      cmd_help ;;
    *)
        log_error "Unknown command: $COMMAND"
        cmd_help
        exit 1
        ;;
esac
