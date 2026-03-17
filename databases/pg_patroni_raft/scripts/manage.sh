#!/bin/bash
# =============================================================================
# pg_patroni_raft — Management CLI
# PostgreSQL 18 HA with Patroni + Raft (built-in DCS) + keepalived VIP
#   + pgBackRest + Valkey
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
STANZA="${BACKUP_STANZA:-pg-patroni-raft}"

# Ports — direct node access (no HAProxy)
NODE1_PORT="5471"
NODE2_PORT="5472"
NODE3_PORT="5473"
API1_PORT="8031"
API2_PORT="8032"
API3_PORT="8033"

# keepalived VIP — only accessible from within the Docker network
VIP="${KEEPALIVED_VIP:-172.31.0.100}"

PATRONI_USER="${PATRONI_RESTAPI_USERNAME:-patroni}"
PATRONI_PASS="${PATRONI_RESTAPI_PASSWORD:-changeme_patroni_2025}"

# Container name prefix
CN_PREFIX="prf"

# --- SQL helpers ---
run_sql_on() {
    local port="$1"; local sql="$2"
    PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "$sql" 2>/dev/null
}

run_sql_primary() {
    local sql="$1"
    local port
    port=$(find_primary_port 2>/dev/null) || { echo ""; return 1; }
    run_sql_on "$port" "$sql"
}

# --- Find helpers ---
find_patroni_node() {
    for node in ${CN_PREFIX}-pg-node1 ${CN_PREFIX}-pg-node2 ${CN_PREFIX}-pg-node3; do
        if docker inspect "$node" --format='{{.State.Running}}' 2>/dev/null | grep -q true; then
            echo "$node"
            return
        fi
    done
    return 1
}

find_primary_node() {
    for node in ${CN_PREFIX}-pg-node1 ${CN_PREFIX}-pg-node2 ${CN_PREFIX}-pg-node3; do
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

find_primary_port() {
    for port in $NODE1_PORT $NODE2_PORT $NODE3_PORT; do
        local is_primary
        is_primary=$(PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$port" -U "$PG_USER" -d postgres -tAc "SELECT NOT pg_is_in_recovery()" 2>/dev/null) || continue
        if [ "$is_primary" = "t" ]; then
            echo "$port"
            return
        fi
    done
    return 1
}

find_replica_port() {
    for port in $NODE1_PORT $NODE2_PORT $NODE3_PORT; do
        local is_replica
        is_replica=$(PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$port" -U "$PG_USER" -d postgres -tAc "SELECT pg_is_in_recovery()" 2>/dev/null) || continue
        if [ "$is_replica" = "t" ]; then
            echo "$port"
            return
        fi
    done
    return 1
}

# =============================================================================
# Commands — stubs (to be filled in batches)
# =============================================================================

cmd_status() {
    log_head "=== Patroni + Raft + keepalived Cluster Status ==="

    # Container status
    log_head "--- Containers ---"
    docker ps --filter "name=${CN_PREFIX}-" \
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

    # keepalived VIP status
    log_head "--- keepalived VIP ---"
    for node in ${CN_PREFIX}-pg-node1 ${CN_PREFIX}-pg-node2 ${CN_PREFIX}-pg-node3; do
        if docker inspect "$node" --format='{{.State.Running}}' 2>/dev/null | grep -q true; then
            local has_vip
            has_vip=$(docker exec "$node" ip addr show eth0 2>/dev/null | grep -c "$VIP" || true)
            if [ "$has_vip" -ge 1 ]; then
                echo -e "  VIP ${GREEN}$VIP${NC} is on ${GREEN}$node${NC}"
            fi
        fi
    done

    # Raft status (no etcd — Raft is built-in)
    log_head "--- Raft DCS ---"
    echo "  Raft consensus is built into Patroni (pysyncobj) — no external DCS"
    local leader_node
    leader_node=$(find_primary_node 2>/dev/null) || leader_node=""
    if [ -n "$leader_node" ]; then
        echo -e "  Raft leader (Patroni primary): ${GREEN}$leader_node${NC}"
    else
        echo "  No primary detected"
    fi

    # Valkey
    log_head "--- Valkey ---"
    local vk
    vk=$(docker exec ${CN_PREFIX}-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning INFO replication 2>/dev/null | grep "role:") || vk="unreachable"
    echo "  Master: ${vk:-unreachable}"

    # pgBackRest summary
    log_head "--- pgBackRest ---"
    local br_node
    br_node=$(find_patroni_node 2>/dev/null) || br_node=""
    if [ -n "$br_node" ]; then
        docker exec -u postgres "$br_node" pgbackrest --stanza="$STANZA" info --output=text 2>/dev/null | head -20 || echo "  pgBackRest info unavailable"
    else
        echo "  No Patroni node running"
    fi
}

cmd_topology() {
    log_head "=== Cluster Topology ==="

    # patronictl list
    log_head "--- Patroni Cluster List ---"
    local node
    node=$(find_patroni_node 2>/dev/null) || { log_warn "No Patroni node running"; return; }
    docker exec "$node" patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || \
        log_warn "patronictl unavailable"

    # Replication status from primary
    log_head "--- Replication Status ---"
    local primary_port=""
    primary_port=$(find_primary_port 2>/dev/null) || primary_port=""

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

    # keepalived VIP location
    log_head "--- keepalived VIP Location ---"
    for cn in ${CN_PREFIX}-pg-node1 ${CN_PREFIX}-pg-node2 ${CN_PREFIX}-pg-node3; do
        if docker inspect "$cn" --format='{{.State.Running}}' 2>/dev/null | grep -q true; then
            local has_vip
            has_vip=$(docker exec "$cn" ip addr show eth0 2>/dev/null | grep -c "$VIP" || true)
            if [ "$has_vip" -ge 1 ]; then
                echo -e "  VIP ${GREEN}$VIP${NC} is held by ${GREEN}$cn${NC}"
            else
                echo "  $cn: no VIP"
            fi
        fi
    done
}

cmd_psql() {
    local target="${1:-primary}"
    case "$target" in
        primary|rw|p)
            local pp
            pp=$(find_primary_port 2>/dev/null) || { log_error "No primary found"; exit 1; }
            log_info "Connecting to PRIMARY (:$pp)"
            PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$pp" -U "$PG_USER" -d "$PG_DB"
            ;;
        replica|ro|r)
            local rp
            rp=$(find_replica_port 2>/dev/null) || { log_error "No replica found"; exit 1; }
            log_info "Connecting to REPLICA (:$rp)"
            PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$rp" -U "$PG_USER" -d "$PG_DB"
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
        vip|v)
            log_info "Connecting to VIP ($VIP) via docker exec into a PG container"
            local cn
            cn=$(find_patroni_node 2>/dev/null) || { log_error "No Patroni node running"; exit 1; }
            docker exec -it -e PGPASSWORD="$PGPASSWORD" "$cn" psql -h "$VIP" -p 5432 -U "$PG_USER" -d "$PG_DB"
            ;;
        *)
            log_error "Unknown target: $target"
            echo "  Targets: primary|rw, replica|ro, vip|v, node1|n1, node2|n2, node3|n3"
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
    local node
    node=$(find_patroni_node 2>/dev/null) || { log_error "No Patroni node running"; exit 1; }
    docker exec -it "$node" patronictl -c /etc/patroni/patroni.yml failover || \
        log_error "Failover failed"
}

cmd_switchover() {
    log_head "=== Patroni Switchover ==="
    log_info "Graceful primary switchover (zero downtime)."
    read -r -p "Proceed? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        log_info "Cancelled."
        return
    fi
    local node
    node=$(find_patroni_node 2>/dev/null) || { log_error "No Patroni node running"; exit 1; }
    docker exec -it "$node" patronictl -c /etc/patroni/patroni.yml switchover || \
        log_error "Switchover failed"
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
    docker exec -it ${CN_PREFIX}-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning "$@"
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
        valkey|vk)      $COMPOSE logs -f --tail=50 valkey-master valkey-replica1 valkey-replica2 ;;
        sentinel)       $COMPOSE logs -f --tail=50 valkey-sentinel1 valkey-sentinel2 valkey-sentinel3 ;;
        node1|n1|1)     $COMPOSE logs -f --tail=50 pg-node1 ;;
        node2|n2|2)     $COMPOSE logs -f --tail=50 pg-node2 ;;
        node3|n3|3)     $COMPOSE logs -f --tail=50 pg-node3 ;;
        *)
            log_error "Unknown target: $target"
            echo "  Targets: all, patroni, valkey, sentinel, node1, node2, node3"
            exit 1
            ;;
    esac
}

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
    docker exec -u postgres "$node" pgbackrest --stanza="$STANZA" --type="$type" backup
    log_ok "Backup complete"
    echo ""
    docker exec -u postgres "$node" pgbackrest --stanza="$STANZA" info
}

cmd_backup_info() {
    log_head "=== pgBackRest Backup Info ==="
    local node
    node=$(find_patroni_node 2>/dev/null) || { log_error "No Patroni node running"; exit 1; }
    docker exec -u postgres "$node" pgbackrest --stanza="$STANZA" info
}

cmd_backup_check() {
    log_head "=== pgBackRest Check ==="
    local node
    node=$(find_primary_node 2>/dev/null) || { log_error "No Patroni primary found"; exit 1; }
    log_info "Checking stanza '$STANZA' on $node (primary)..."
    docker exec -u postgres "$node" pgbackrest --stanza="$STANZA" check
    log_ok "pgBackRest check passed"
}

cmd_bench() {
    log_head "=== Benchmark ==="

    local pp
    pp=$(find_primary_port 2>/dev/null) || { log_error "No primary found"; exit 1; }
    local rp

    log_info "Initializing pgbench tables on primary (:$pp)..."
    PGPASSWORD="$PGPASSWORD" pgbench -h localhost -p "$pp" -U "$PG_USER" -d "$PG_DB" -i -s 10 2>/dev/null || \
        { log_error "pgbench init failed"; return; }

    # Write benchmark (TPC-B on primary)
    log_head "--- Write Benchmark (TPC-B, primary :$pp) ---"
    PGPASSWORD="$PGPASSWORD" pgbench -h localhost -p "$pp" -U "$PG_USER" -d "$PG_DB" \
        -c 10 -j 4 -T 10 2>&1 || log_warn "Write benchmark failed"

    # Read benchmark (SELECT-only on a replica)
    rp=$(find_replica_port 2>/dev/null) || rp=""
    if [ -n "$rp" ]; then
        log_head "--- Read Benchmark (SELECT-only, replica :$rp) ---"
        PGPASSWORD="$PGPASSWORD" pgbench -h localhost -p "$rp" -U "$PG_USER" -d "$PG_DB" \
            -c 10 -j 4 -T 10 -S 2>&1 || log_warn "Read benchmark failed"
    else
        log_warn "No replica found — skipping read benchmark"
    fi

    # Cleanup
    log_info "Cleaning up pgbench tables..."
    PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$pp" -U "$PG_USER" -d "$PG_DB" -c "
        DROP TABLE IF EXISTS pgbench_accounts, pgbench_branches, pgbench_history, pgbench_tellers;" 2>/dev/null
    log_ok "Benchmark complete"
}

cmd_test() {
    log_head "=== Integration Tests ==="

    local passed=0 failed=0 total=0

    run_test() { total=$((total + 1)); echo -n "  Test $total: $* ... "; }
    pass()     { passed=$((passed + 1)); echo -e "${GREEN}PASS${NC}"; }
    fail()     { failed=$((failed + 1)); echo -e "${RED}FAIL${NC} — $*"; }

    # --- Check cluster readiness ---
    log_info "Checking cluster readiness..."

    local primary_port=""
    primary_port=$(find_primary_port 2>/dev/null) || primary_port=""
    if [ -z "$primary_port" ]; then
        log_error "No primary found — cluster not ready. Aborting tests."
        exit 1
    fi

    # Test 1: Primary is writable
    run_test "Primary is writable (direct :$primary_port)"
    run_sql_on "$primary_port" "CREATE TABLE IF NOT EXISTS _test_raft (id int)" >/dev/null 2>&1
    local wr
    wr=$(run_sql_on "$primary_port" "SELECT 1" 2>/dev/null)
    [ "$wr" = "1" ] && pass || fail "Write failed on primary"

    # Test 2: Replica is read-only
    run_test "Replica is read-only"
    local replica_port
    replica_port=$(find_replica_port 2>/dev/null) || replica_port=""
    if [ -n "$replica_port" ]; then
        local ro
        ro=$(PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$replica_port" -U "$PG_USER" -d "$PG_DB" -tAc "INSERT INTO _test_raft VALUES (999)" 2>&1) || true
        echo "$ro" | grep -qi "read-only\|cannot execute" && pass || fail "Replica accepted writes"
    else
        fail "No replica found"
    fi

    # Test 3: Write + read replication
    run_test "Write + read replication across nodes"
    run_sql_on "$primary_port" "INSERT INTO _test_raft VALUES (42) ON CONFLICT DO NOTHING" >/dev/null 2>&1
    sleep 1
    if [ -n "$replica_port" ]; then
        local replicated
        replicated=$(run_sql_on "$replica_port" "SELECT id FROM _test_raft WHERE id=42")
        [ "$replicated" = "42" ] && pass || fail "Data not replicated"
    else
        fail "No replica to verify"
    fi

    # Test 4: Synchronous replication active
    run_test "Synchronous replication active"
    local sync
    sync=$(PGCONNECT_TIMEOUT=3 PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$primary_port" -U "$PG_USER" -d postgres -tAc \
        "SELECT count(*) FROM pg_stat_replication WHERE sync_state = 'sync'" 2>/dev/null)
    [ "${sync:-0}" -ge 1 ] && pass || fail "No synchronous replicas (got: ${sync:-0})"

    # Test 5: Patroni Raft consensus (all 3 nodes responding)
    run_test "Patroni Raft consensus (all 3 nodes responding)"
    local raft_ok=0
    for port in $API1_PORT $API2_PORT $API3_PORT; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/patroni" 2>/dev/null) || code="000"
        if [ "$code" = "200" ]; then
            raft_ok=$((raft_ok + 1))
        fi
    done
    [ "$raft_ok" -eq 3 ] && pass || fail "Only $raft_ok/3 Patroni nodes responding"

    # Test 6: Patroni REST API on all 3 nodes
    run_test "Patroni REST API on all 3 nodes"
    local api_ok=0
    for port in $API1_PORT $API2_PORT $API3_PORT; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/health" 2>/dev/null) || code="000"
        [ "$code" = "200" ] && api_ok=$((api_ok + 1))
    done
    [ "$api_ok" -eq 3 ] && pass || fail "Only $api_ok/3 Patroni APIs healthy"

    # Test 7: keepalived VIP on exactly one node
    run_test "keepalived VIP on exactly one node"
    local vip_count=0 vip_holder=""
    for node in ${CN_PREFIX}-pg-node1 ${CN_PREFIX}-pg-node2 ${CN_PREFIX}-pg-node3; do
        if docker inspect "$node" --format='{{.State.Running}}' 2>/dev/null | grep -q true; then
            local has_vip
            has_vip=$(docker exec "$node" ip addr show eth0 2>/dev/null | grep -c "$VIP" || true)
            if [ "$has_vip" -ge 1 ]; then
                vip_count=$((vip_count + 1))
                vip_holder="$node"
            fi
        fi
    done
    [ "$vip_count" -eq 1 ] && pass || fail "VIP found on $vip_count nodes (expected 1)"

    # Test 8: VIP routes to primary
    run_test "VIP routes to primary"
    if [ -n "$vip_holder" ]; then
        local test_node
        test_node=$(find_patroni_node 2>/dev/null) || test_node=""
        if [ -n "$test_node" ]; then
            local vip_primary
            vip_primary=$(docker exec -e PGPASSWORD="$PGPASSWORD" "$test_node" psql -h "$VIP" -p 5432 -U "$PG_USER" -d "$PG_DB" -tAc "SELECT NOT pg_is_in_recovery()" 2>/dev/null)
            [ "$vip_primary" = "t" ] && pass || fail "VIP not routing to primary"
        else
            fail "No node to test VIP connectivity"
        fi
    else
        fail "No VIP holder found"
    fi

    # Test 9: Valkey master write/read
    run_test "Valkey master write/read"
    docker exec ${CN_PREFIX}-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning SET _test_raft "hello" >/dev/null 2>&1
    local vk_result
    vk_result=$(docker exec ${CN_PREFIX}-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning GET _test_raft 2>/dev/null)
    [ "$vk_result" = "hello" ] && pass || fail "Valkey write/read failed"

    # Test 10: Valkey replication to replicas
    run_test "Valkey replication to replicas"
    local vk_repl
    vk_repl=$(docker exec ${CN_PREFIX}-valkey-replica1 valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning GET _test_raft 2>/dev/null)
    [ "$vk_repl" = "hello" ] && pass || fail "Valkey replication failed"

    # Test 11: pgBackRest stanza exists
    run_test "pgBackRest stanza exists"
    local br_node
    br_node=$(find_patroni_node 2>/dev/null) || br_node=""
    if [ -n "$br_node" ]; then
        local stanza_ok
        stanza_ok=$(docker exec -u postgres "$br_node" pgbackrest --stanza="$STANZA" info --output=json 2>/dev/null | jq -r '.[0].name // empty' 2>/dev/null)
        [ "$stanza_ok" = "$STANZA" ] && pass || fail "Stanza '$STANZA' not found"
    else
        fail "No Patroni node running"
    fi

    # Test 12: pgBackRest check passes (WAL archiving working)
    run_test "pgBackRest check (WAL archiving)"
    local primary_node
    primary_node=$(find_primary_node 2>/dev/null) || primary_node=""
    if [ -n "$primary_node" ]; then
        docker exec -u postgres "$primary_node" pgbackrest --stanza="$STANZA" check >/dev/null 2>&1 && pass || fail "pgBackRest check failed (on $primary_node)"
    else
        fail "No Patroni primary found"
    fi

    # Test 13: pgBackRest has at least one backup
    run_test "pgBackRest has at least one backup"
    if [ -n "$br_node" ]; then
        local backup_count
        backup_count=$(docker exec -u postgres "$br_node" pgbackrest --stanza="$STANZA" info --output=json 2>/dev/null | jq '.[0].backup | length' 2>/dev/null) || backup_count=0
        [ "${backup_count:-0}" -ge 1 ] && pass || fail "No backups found (count: ${backup_count:-0})"
    else
        fail "No Patroni node running"
    fi

    # --- Cleanup ---
    run_sql_on "$primary_port" "DROP TABLE IF EXISTS _test_raft" >/dev/null 2>&1
    docker exec ${CN_PREFIX}-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning DEL _test_raft >/dev/null 2>&1

    # --- Summary ---
    echo ""
    if [ "$failed" -eq 0 ]; then
        log_ok "All $total tests passed!"
    else
        log_error "$failed/$total tests failed"
    fi
}

cmd_help() {
    echo "Usage: $0 <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  status          Full cluster status (Patroni, Raft, VIP, pgBackRest)"
    echo "  topology        Detailed cluster topology (patronictl list)"
    echo "  psql [target]   Interactive psql (primary|replica|vip|node1|node2|node3)"
    echo "  switchover      Graceful Patroni switchover"
    echo "  failover        Patroni failover (emergency)"
    echo "  reinit          Full cluster reinit (DESTROYS ALL DATA)"
    echo "  test            Run integration tests"
    echo "  bench           Run pgbench benchmark"
    echo "  logs [target]   Tail logs (all|patroni|valkey|sentinel|node1|node2|node3)"
    echo "  patronictl      Run patronictl commands"
    echo "  valkey-cli      Interactive Valkey CLI"
    echo "  backup [type]   pgBackRest backup (full|diff|incr)"
    echo "  backup-info     Show backup inventory"
    echo "  backup-check    Verify stanza and WAL archiving"
    echo "  help            Show this help"
}

# =============================================================================
# Main Dispatch
# =============================================================================
case "${1:-help}" in
    status)         cmd_status ;;
    topology)       cmd_topology ;;
    psql)           shift; cmd_psql "$@" ;;
    switchover)     cmd_switchover ;;
    failover)       cmd_failover ;;
    reinit)         cmd_reinit ;;
    test)           cmd_test ;;
    bench)          cmd_bench ;;
    logs)           shift; cmd_logs "$@" ;;
    patronictl)     shift; cmd_patronictl "$@" ;;
    valkey-cli)     shift; cmd_valkey_cli "$@" ;;
    backup)         shift; cmd_backup "$@" ;;
    backup-info)    cmd_backup_info ;;
    backup-check)   cmd_backup_check ;;
    help|--help|-h) cmd_help ;;
    *)
        log_error "Unknown command: $1"
        cmd_help
        exit 1
        ;;
esac
