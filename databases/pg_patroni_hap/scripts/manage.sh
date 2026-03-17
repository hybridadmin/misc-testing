#!/bin/bash
# =============================================================================
# pg_patroni_hap — Management CLI
# PostgreSQL 18 HA with Patroni + etcd + HAProxy + pgBackRest + Valkey
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

# pgBackRest
STANZA="${BACKUP_STANZA:-pg-patroni-hap}"

# Ports
HAPROXY_RW_PORT="${HAPROXY_WRITE_PORT:-5432}"
HAPROXY_RO_PORT="${HAPROXY_READ_PORT:-5433}"
HAPROXY_ANY_PORT="5434"
NODE1_PORT="5441"
NODE2_PORT="5442"
NODE3_PORT="5443"
API1_PORT="8008"
API2_PORT="8009"
API3_PORT="8010"

PATRONI_USER="${PATRONI_RESTAPI_USERNAME:-patroni}"
PATRONI_PASS="${PATRONI_RESTAPI_PASSWORD:-changeme_patroni_2025}"

# --- SQL helpers ---
run_sql() {
    PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null
}

run_sql_ro() {
    PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RO_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null
}

run_sql_any() {
    PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_ANY_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null
}

run_sql_on() {
    local port="$1"; local sql="$2"
    PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "$sql" 2>/dev/null
}

# --- Find a running Patroni node ---
find_patroni_node() {
    for node in pg-node1 pg-node2 pg-node3; do
        if docker inspect "$node" --format='{{.State.Running}}' 2>/dev/null | grep -q true; then
            echo "$node"
            return
        fi
    done
    return 1
}

# --- Find the current Patroni primary node ---
find_primary_node() {
    for node in pg-node1 pg-node2 pg-node3; do
        if docker inspect "$node" --format='{{.State.Running}}' 2>/dev/null | grep -q true; then
            local is_primary
            is_primary=$(docker exec "$node" psql -U postgres -h /var/run/postgresql -tAc "SELECT NOT pg_is_in_recovery()" 2>/dev/null)
            if [ "$is_primary" = "t" ]; then
                echo "$node"
                return
            fi
        fi
    done
    return 1
}

# =============================================================================
# Commands
# =============================================================================

cmd_status() {
    log_head "=== Patroni Cluster Status ==="

    # Container status
    log_head "--- Containers ---"
    docker ps --filter "name=pg-node" --filter "name=etcd" --filter "name=haproxy-pg" --filter "name=valkey" \
        --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null

    # Patroni cluster members via REST API
    log_head "--- Patroni Members ---"
    for port in $API1_PORT $API2_PORT $API3_PORT; do
        local resp
        resp=$(curl -s "http://localhost:$port/patroni" 2>/dev/null) || continue
        local name role state
        name=$(echo "$resp" | jq -r '.patroni.name // "?"' 2>/dev/null)
        role=$(echo "$resp" | jq -r '.role // "?"' 2>/dev/null)
        state=$(echo "$resp" | jq -r '.state // "?"' 2>/dev/null)
        if [ "$role" = "master" ] || [ "$role" = "primary" ]; then
            echo -e "  ${GREEN}$name${NC}: $role ($state) [API: :$port]"
        elif [ "$role" = "sync_standby" ]; then
            echo -e "  ${CYAN}$name${NC}: $role ($state) [API: :$port]"
        else
            echo -e "  ${YELLOW}$name${NC}: $role ($state) [API: :$port]"
        fi
    done

    # etcd cluster health
    log_head "--- etcd Cluster ---"
    docker exec etcd1 etcdctl endpoint health \
        --endpoints=http://etcd1:2379,http://etcd2:2379,http://etcd3:2379 2>&1 || echo "  etcd unreachable"

    # HAProxy status
    log_head "--- HAProxy ---"
    local ha_rw ha_ro ha_any
    ha_rw=$(PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT inet_server_addr() || ' (' || CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END || ')'" 2>/dev/null) || ha_rw="unreachable"
    ha_ro=$(PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RO_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT inet_server_addr() || ' (' || CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END || ')'" 2>/dev/null) || ha_ro="unreachable"
    ha_any=$(PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_ANY_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT inet_server_addr() || ' (' || CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END || ')'" 2>/dev/null) || ha_any="unreachable"
    echo "  Write  port $HAPROXY_RW_PORT  -> $ha_rw"
    echo "  Read   port $HAPROXY_RO_PORT  -> $ha_ro"
    echo "  Any    port $HAPROXY_ANY_PORT -> $ha_any"
    echo "  Stats: http://localhost:${HAPROXY_STATS_PORT:-7000}/stats"

    # Valkey
    log_head "--- Valkey ---"
    local vk
    vk=$(docker exec valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning INFO replication 2>/dev/null | grep "role:") || vk="unreachable"
    echo "  Master: ${vk:-unreachable}"

    # pgBackRest summary
    log_head "--- pgBackRest ---"
    local br_node
    br_node=$(find_patroni_node 2>/dev/null) || br_node=""
    if [ -n "$br_node" ]; then
        docker exec "$br_node" pgbackrest --stanza="$STANZA" info --output=text 2>/dev/null | head -20 || echo "  pgBackRest info unavailable"
    else
        echo "  No Patroni node running"
    fi
}

cmd_topology() {
    log_head "=== Cluster Topology ==="

    # patronictl list
    log_head "--- Patroni Cluster List ---"
    docker exec pg-node1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || \
        log_warn "patronictl unavailable"

    # Replication status from primary
    log_head "--- Replication Status ---"
    local primary_port=""
    for port in $NODE1_PORT $NODE2_PORT $NODE3_PORT; do
        local is_primary
        is_primary=$(PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$port" -U "$PG_USER" -d postgres -tAc "SELECT NOT pg_is_in_recovery()" 2>/dev/null) || continue
        if [ "$is_primary" = "t" ]; then
            primary_port="$port"
            break
        fi
    done

    if [ -n "$primary_port" ]; then
        PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$primary_port" -U "$PG_USER" -d postgres -c "
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
    docker exec etcd1 etcdctl get /service/pg-patroni-hap/leader --print-value-only 2>/dev/null || echo "  not set"
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
        any|a)
            log_info "Connecting to ANY healthy node via HAProxy (:$HAPROXY_ANY_PORT)"
            PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_ANY_PORT" -U "$PG_USER" -d "$PG_DB"
            ;;
        node1|n1|1)
            log_info "Connecting directly to pg-node1 (:$NODE1_PORT)"
            PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$NODE1_PORT" -U "$PG_USER" -d "$PG_DB"
            ;;
        node2|n2|2)
            log_info "Connecting directly to pg-node2 (:$NODE2_PORT)"
            PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$NODE2_PORT" -U "$PG_USER" -d "$PG_DB"
            ;;
        node3|n3|3)
            log_info "Connecting directly to pg-node3 (:$NODE3_PORT)"
            PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$NODE3_PORT" -U "$PG_USER" -d "$PG_DB"
            ;;
        *)
            log_error "Unknown target: $target"
            echo "  Targets: primary|rw, replica|ro, any|a, node1|n1, node2|n2, node3|n3"
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
    docker exec -it pg-node1 patronictl -c /etc/patroni/patroni.yml failover 2>/dev/null || \
    docker exec -it pg-node2 patronictl -c /etc/patroni/patroni.yml failover 2>/dev/null || \
    docker exec -it pg-node3 patronictl -c /etc/patroni/patroni.yml failover 2>/dev/null || \
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
    docker exec -it pg-node1 patronictl -c /etc/patroni/patroni.yml switchover 2>/dev/null || \
    docker exec -it pg-node2 patronictl -c /etc/patroni/patroni.yml switchover 2>/dev/null || \
    docker exec -it pg-node3 patronictl -c /etc/patroni/patroni.yml switchover 2>/dev/null || \
        log_error "Switchover failed — no Patroni node reachable"
}

cmd_reinit() {
    log_head "=== Full Cluster Reinit ==="
    log_warn "This will DESTROY ALL DATA (including pgBackRest backups) and recreate the cluster."
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

cmd_valkey_cli() {
    docker exec -it valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning "$@"
}

cmd_patronictl() {
    local node
    node=$(find_patroni_node 2>/dev/null) || { log_error "No Patroni node running"; exit 1; }
    docker exec -it "$node" patronictl -c /etc/patroni/patroni.yml "$@"
}

cmd_logs() {
    local target="${1:-all}"
    case "$target" in
        all)            $COMPOSE logs -f --tail=50 ;;
        patroni|pg)     $COMPOSE logs -f --tail=50 pg-node1 pg-node2 pg-node3 ;;
        etcd)           $COMPOSE logs -f --tail=50 etcd1 etcd2 etcd3 ;;
        haproxy|ha)     $COMPOSE logs -f --tail=50 haproxy-pg ;;
        valkey|vk)      $COMPOSE logs -f --tail=50 valkey-master valkey-replica1 valkey-replica2 ;;
        sentinel)       $COMPOSE logs -f --tail=50 valkey-sentinel1 valkey-sentinel2 valkey-sentinel3 ;;
        node1|n1|1)     $COMPOSE logs -f --tail=50 pg-node1 ;;
        node2|n2|2)     $COMPOSE logs -f --tail=50 pg-node2 ;;
        node3|n3|3)     $COMPOSE logs -f --tail=50 pg-node3 ;;
        *)
            log_error "Unknown target: $target"
            echo "  Targets: all, patroni, etcd, haproxy, valkey, sentinel, node1, node2, node3"
            exit 1
            ;;
    esac
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

    # Cleanup
    log_info "Cleaning up pgbench tables..."
    run_sql "DROP TABLE IF EXISTS pgbench_accounts, pgbench_branches, pgbench_tellers, pgbench_history;" >/dev/null 2>&1
    log_ok "Benchmark complete"
}

# --- pgBackRest commands ---

cmd_backup() {
    local type="${1:-diff}"
    case "$type" in
        full|diff|incr) ;;
        *)
            log_error "Unknown backup type: $type (use full, diff, or incr)"
            exit 1
            ;;
    esac

    log_head "=== pgBackRest Backup ($type) ==="
    local node
    node=$(find_primary_node 2>/dev/null) || { log_error "No Patroni primary found"; exit 1; }
    log_info "Running $type backup on $node (stanza: $STANZA)..."
    docker exec "$node" pgbackrest --stanza="$STANZA" --type="$type" backup
    log_ok "Backup complete"
    echo ""
    docker exec "$node" pgbackrest --stanza="$STANZA" info
}

cmd_backup_info() {
    log_head "=== pgBackRest Backup Info ==="
    local node
    node=$(find_patroni_node 2>/dev/null) || { log_error "No Patroni node running"; exit 1; }
    docker exec "$node" pgbackrest --stanza="$STANZA" info
}

cmd_backup_check() {
    log_head "=== pgBackRest Check ==="
    local node
    node=$(find_primary_node 2>/dev/null) || { log_error "No Patroni primary found"; exit 1; }
    log_info "Checking stanza '$STANZA' on $node (primary)..."
    docker exec "$node" pgbackrest --stanza="$STANZA" check
    log_ok "pgBackRest check passed"
}

# --- Test command ---
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
    for i in $(seq 1 15); do
        if PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT 1" >/dev/null 2>&1; then
            ready=true; break
        fi
        sleep 2
    done
    if ! $ready; then
        log_error "Cluster not ready after 30s. Aborting tests."
        exit 1
    fi

    # Test 1: HAProxy Write routes to primary
    run_test "HAProxy Write routes to primary"
    local is_primary
    is_primary=$(PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT NOT pg_is_in_recovery()" 2>/dev/null)
    [ "$is_primary" = "t" ] && pass || fail "RW port not routing to primary"

    # Test 2: HAProxy Read routes to replica
    run_test "HAProxy Read routes to replica"
    local is_replica
    is_replica=$(PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RO_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT pg_is_in_recovery()" 2>/dev/null)
    [ "$is_replica" = "t" ] && pass || fail "RO port not routing to replica"

    # Test 3: HAProxy Any routes to healthy node
    run_test "HAProxy Any routes to healthy node"
    local any_result
    any_result=$(PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_ANY_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT 1" 2>/dev/null)
    [ "$any_result" = "1" ] && pass || fail "Any port not routing to healthy node"

    # Test 4: Write via HAProxy Write
    run_test "Write via HAProxy Write"
    run_sql "DROP TABLE IF EXISTS _test_hap; CREATE TABLE _test_hap (id serial PRIMARY KEY, val text, ts timestamptz DEFAULT now());" >/dev/null 2>&1
    run_sql "INSERT INTO _test_hap (val) VALUES ('hello_hap');" >/dev/null 2>&1
    local write_result
    write_result=$(run_sql "SELECT val FROM _test_hap WHERE val = 'hello_hap'")
    [ "$write_result" = "hello_hap" ] && pass || fail "Write failed"

    # Test 5: Read replicated data from replica
    run_test "Read replicated data from replica"
    sleep 1  # allow replication
    local read_result
    read_result=$(run_sql_ro "SELECT val FROM _test_hap WHERE val = 'hello_hap'")
    [ "$read_result" = "hello_hap" ] && pass || fail "Replication lag or failure"

    # Test 6: Synchronous replication active
    run_test "Synchronous replication active"
    local sync_state
    sync_state=$(PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW_PORT" -U "$PG_USER" -d postgres -tAc \
        "SELECT count(*) FROM pg_stat_replication WHERE sync_state = 'sync'" 2>/dev/null)
    [ "${sync_state:-0}" -ge 1 ] && pass || fail "No sync replica found (got: ${sync_state:-none})"

    # Test 7: etcd cluster healthy (3 members)
    run_test "etcd cluster healthy (3 members)"
    local etcd_health
    etcd_health=$(docker exec etcd1 etcdctl member list --write-out=simple 2>/dev/null | grep -c "started") || etcd_health=0
    [ "$etcd_health" -eq 3 ] && pass || fail "Expected 3 etcd members, got $etcd_health"

    # Test 8: Patroni REST API on all 3 nodes
    run_test "Patroni REST API on all 3 nodes"
    local api_ok=0
    for port in $API1_PORT $API2_PORT $API3_PORT; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/patroni" 2>/dev/null) || code=0
        [ "$code" = "200" ] && api_ok=$((api_ok + 1))
    done
    [ "$api_ok" -eq 3 ] && pass || fail "Only $api_ok/3 Patroni APIs responding"

    # Test 9: Valkey master write/read
    run_test "Valkey master write/read"
    docker exec valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning SET _test_hap "hello" >/dev/null 2>&1
    local vk_result
    vk_result=$(docker exec valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning GET _test_hap 2>/dev/null)
    [ "$vk_result" = "hello" ] && pass || fail "Valkey write/read failed"

    # Test 10: Valkey replication to replicas
    run_test "Valkey replication to replicas"
    local vk_repl
    vk_repl=$(docker exec valkey-replica1 valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning GET _test_hap 2>/dev/null)
    [ "$vk_repl" = "hello" ] && pass || fail "Valkey replication failed"

    # Test 11: pgBackRest stanza exists
    run_test "pgBackRest stanza exists"
    local br_node
    br_node=$(find_patroni_node 2>/dev/null) || br_node=""
    if [ -n "$br_node" ]; then
        local stanza_ok
        stanza_ok=$(docker exec "$br_node" pgbackrest --stanza="$STANZA" info --output=json 2>/dev/null | jq -r '.[0].name // empty' 2>/dev/null)
        [ "$stanza_ok" = "$STANZA" ] && pass || fail "Stanza '$STANZA' not found"
    else
        fail "No Patroni node running"
    fi

    # Test 12: pgBackRest check passes (WAL archiving working)
    run_test "pgBackRest check (WAL archiving)"
    local primary_node
    primary_node=$(find_primary_node 2>/dev/null) || primary_node=""
    if [ -n "$primary_node" ]; then
        docker exec "$primary_node" pgbackrest --stanza="$STANZA" check >/dev/null 2>&1 && pass || fail "pgBackRest check failed (on $primary_node)"
    else
        fail "No Patroni primary found"
    fi

    # Test 13: pgBackRest has at least one backup
    run_test "pgBackRest has at least one backup"
    if [ -n "$br_node" ]; then
        local backup_count
        backup_count=$(docker exec "$br_node" pgbackrest --stanza="$STANZA" info --output=json 2>/dev/null | jq '.[0].backup | length' 2>/dev/null) || backup_count=0
        [ "${backup_count:-0}" -ge 1 ] && pass || fail "No backups found (got: ${backup_count:-0})"
    else
        fail "No Patroni node running"
    fi

    # Cleanup
    run_sql "DROP TABLE IF EXISTS _test_hap;" >/dev/null 2>&1
    docker exec valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning DEL _test_hap >/dev/null 2>&1

    # Summary
    echo ""
    if [ "$errors" -eq 0 ]; then
        log_ok "All $test_num tests passed!"
    else
        log_error "$errors/$test_num tests failed"
        exit 1
    fi
}

# --- Help ---
cmd_help() {
    echo "pg_patroni_hap — PostgreSQL 18 HA with Patroni + etcd + HAProxy + pgBackRest + Valkey"
    echo ""
    echo "Usage: ./manage.sh [command] [args...]"
    echo ""
    echo "Info:"
    echo "  status              Cluster health overview"
    echo "  topology            Detailed replication/etcd topology"
    echo "  logs [target]       Stream logs (all|patroni|etcd|haproxy|valkey|sentinel|node1..3)"
    echo ""
    echo "Access:"
    echo "  psql [target]       Interactive psql (primary|replica|any|node1..3)"
    echo "  valkey-cli          Connect to Valkey CLI"
    echo "  patronictl [args]   Run patronictl commands (e.g., list, show-config, edit-config)"
    echo ""
    echo "HA Operations:"
    echo "  switchover          Graceful primary switchover (zero downtime)"
    echo "  failover            Emergency failover (promotes best candidate)"
    echo "  reinit              Full cluster reinit (DESTROYS ALL DATA)"
    echo ""
    echo "pgBackRest:"
    echo "  backup [type]       Run backup (full|diff|incr, default: diff)"
    echo "  backup-info         Show backup inventory"
    echo "  backup-check        Verify stanza and WAL archiving"
    echo ""
    echo "Test & Benchmark:"
    echo "  test                Run integration tests (13 tests)"
    echo "  bench               Run pgbench benchmarks (TPC-B + SELECT-only)"
    echo ""
    echo "Connection Info:"
    echo "  HAProxy Write:  localhost:${HAPROXY_RW_PORT} (primary)"
    echo "  HAProxy Read:   localhost:${HAPROXY_RO_PORT} (replicas)"
    echo "  HAProxy Any:    localhost:${HAPROXY_ANY_PORT} (any healthy)"
    echo "  Node 1 direct:  localhost:${NODE1_PORT}"
    echo "  Node 2 direct:  localhost:${NODE2_PORT}"
    echo "  Node 3 direct:  localhost:${NODE3_PORT}"
    echo "  HAProxy Stats:  http://localhost:${HAPROXY_STATS_PORT:-7000}/stats"
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
    valkey-cli)          cmd_valkey_cli "$@" ;;
    backup)              cmd_backup "$@" ;;
    backup-info|info)    cmd_backup_info ;;
    backup-check|check)  cmd_backup_check ;;
    help|--help|-h)      cmd_help ;;
    *)
        log_error "Unknown command: $COMMAND"
        cmd_help
        exit 1
        ;;
esac
