#!/bin/bash
# =============================================================================
# pg_spock — Management CLI
# PostgreSQL 18 + Spock Multi-Master (2x R/W + 2x RO + HAProxy)
# Usage: ./scripts/manage.sh [command] [args...]
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
PGPASSWORD="${POSTGRES_PASSWORD:-postgres}"
PG_USER="${POSTGRES_USER:-postgres}"
PG_DB="${POSTGRES_DB:-spockdb}"

# Ports
HAPROXY_RW="${HAPROXY_RW_PORT:-15000}"
HAPROXY_RO="${HAPROXY_RO_PORT:-15001}"
HAPROXY_STATS="${HAPROXY_STATS_PORT:-17000}"
NODE1_PORT="${PG_NODE1_PORT:-15432}"
NODE2_PORT="${PG_NODE2_PORT:-15433}"
NODE3_PORT="${PG_NODE3_PORT:-15434}"
NODE4_PORT="${PG_NODE4_PORT:-15435}"

# --- SQL helpers ---
run_sql() {
    PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW" -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null
}

run_sql_ro() {
    PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RO" -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null
}

run_sql_on() {
    local port="$1"; local sql="$2"
    PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "$sql" 2>/dev/null
}

# =============================================================================
# Commands
# =============================================================================

cmd_status() {
    log_head "=== pg_spock Cluster Status ==="

    # Container status
    log_head "--- Containers ---"
    docker ps --filter "name=spock-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null

    # Node roles
    log_head "--- Node Roles ---"
    for name_port in "node1:$NODE1_PORT" "node2:$NODE2_PORT" "node3:$NODE3_PORT" "node4:$NODE4_PORT"; do
        local name="${name_port%%:*}"
        local port="${name_port##*:}"
        local role
        role=$(PGPASSWORD="$PGPASSWORD" PGCONNECT_TIMEOUT=3 psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc \
            "SELECT CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END" 2>/dev/null) || role="unreachable"
        if [ "$role" = "primary" ]; then
            echo -e "  ${GREEN}$name${NC} (:$port): $role (R/W — Spock multi-master)"
        elif [ "$role" = "replica" ]; then
            echo -e "  ${CYAN}$name${NC} (:$port): $role (RO — streaming)"
        else
            echo -e "  ${RED}$name${NC} (:$port): $role"
        fi
    done

    # Spock subscriptions
    log_head "--- Spock Subscriptions ---"
    for name_port in "node1:$NODE1_PORT" "node2:$NODE2_PORT"; do
        local name="${name_port%%:*}"
        local port="${name_port##*:}"
        local subs
        subs=$(PGPASSWORD="$PGPASSWORD" PGCONNECT_TIMEOUT=3 psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc \
            "SELECT sub_name || ' (enabled=' || sub_enabled || ')' FROM spock.subscription" 2>/dev/null) || subs="unavailable"
        echo "  $name: $subs"
    done

    # HAProxy
    log_head "--- HAProxy ---"
    local ha_rw ha_ro
    ha_rw=$(PGPASSWORD="$PGPASSWORD" PGCONNECT_TIMEOUT=5 psql -h localhost -p "$HAPROXY_RW" -U "$PG_USER" -d "$PG_DB" -tAc \
        "SELECT inet_server_addr() || ' (' || CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END || ')'" 2>/dev/null) || ha_rw="unreachable"
    ha_ro=$(PGPASSWORD="$PGPASSWORD" PGCONNECT_TIMEOUT=5 psql -h localhost -p "$HAPROXY_RO" -U "$PG_USER" -d "$PG_DB" -tAc \
        "SELECT inet_server_addr() || ' (' || CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END || ')'" 2>/dev/null) || ha_ro="unreachable"
    echo "  R/W  :$HAPROXY_RW  -> $ha_rw"
    echo "  RO   :$HAPROXY_RO  -> $ha_ro"
    echo "  Stats: http://localhost:${HAPROXY_STATS}/"

    # Replication lag from primaries
    log_head "--- Streaming Replication ---"
    for name_port in "node1:$NODE1_PORT" "node2:$NODE2_PORT"; do
        local name="${name_port%%:*}"
        local port="${name_port##*:}"
        local repl_info
        repl_info=$(PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$port" -U "$PG_USER" -d postgres -tAc \
            "SELECT string_agg(application_name || ': ' || state || ' (lag=' || pg_wal_lsn_diff(sent_lsn, replay_lsn)::text || 'B)', ', ')
             FROM pg_stat_replication" 2>/dev/null) || repl_info="unavailable"
        echo "  $name -> ${repl_info:-no replicas connected}"
    done
}

cmd_topology() {
    log_head "=== Cluster Topology ==="

    # Spock node info
    log_head "--- Spock Nodes ---"
    for name_port in "node1:$NODE1_PORT" "node2:$NODE2_PORT"; do
        local name="${name_port%%:*}"
        local port="${name_port##*:}"
        echo "  --- $name ---"
        PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c \
            "SELECT node_id, node_name FROM spock.node;" 2>/dev/null || echo "  unavailable"
    done

    # Replication status from both primaries
    log_head "--- Replication Status ---"
    for name_port in "node1:$NODE1_PORT" "node2:$NODE2_PORT"; do
        local name="${name_port%%:*}"
        local port="${name_port##*:}"
        echo "  --- $name replication slots ---"
        PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c \
            "SELECT client_addr, application_name, state, sync_state,
                    sent_lsn, write_lsn, flush_lsn, replay_lsn,
                    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
             FROM pg_stat_replication
             ORDER BY application_name;" 2>/dev/null || echo "  unavailable"
    done

    # Subscription status
    log_head "--- Spock Subscription Detail ---"
    for name_port in "node1:$NODE1_PORT" "node2:$NODE2_PORT"; do
        local name="${name_port%%:*}"
        local port="${name_port##*:}"
        echo "  --- $name ---"
        PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c \
            "SELECT sub_name, sub_enabled, sub_slot_name FROM spock.subscription;" 2>/dev/null || echo "  unavailable"
    done

    # HAProxy backend status
    log_head "--- HAProxy Backend Status ---"
    local csv
    csv=$(curl -s "http://localhost:${HAPROXY_STATS}/;csv" 2>/dev/null) || csv=""
    if [ -n "$csv" ]; then
        echo "$csv" | awk -F, 'NR>1 && $2 != "FRONTEND" && $2 != "BACKEND" && $1 ~ /^pg_/ {printf "  %-8s %-8s %s\n", $1, $2, $18}'
    else
        echo "  HAProxy stats unreachable"
    fi
}

cmd_psql() {
    local target="${1:-rw}"
    case "$target" in
        rw|primary|master|p)
            log_info "Connecting to R/W via HAProxy (:$HAPROXY_RW)"
            PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW" -U "$PG_USER" -d "$PG_DB"
            ;;
        ro|replica|replicas|r)
            log_info "Connecting to RO via HAProxy (:$HAPROXY_RO)"
            PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RO" -U "$PG_USER" -d "$PG_DB"
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
        node4|n4|4)
            log_info "Connecting directly to node4 (:$NODE4_PORT)"
            PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$NODE4_PORT" -U "$PG_USER" -d "$PG_DB"
            ;;
        *)
            log_error "Unknown target: $target"
            echo "  Targets: rw|primary, ro|replica, node1|n1, node2|n2, node3|n3, node4|n4"
            exit 1
            ;;
    esac
}

cmd_setup() {
    log_head "=== Running Spock Setup ==="
    log_info "This configures Spock nodes, replication sets, bidirectional subscriptions, and test data."
    bash "$SCRIPT_DIR/setup-spock.sh"
}

cmd_reinit() {
    log_head "=== Full Cluster Reinit ==="
    log_warn "This will DESTROY ALL DATA and recreate the cluster from scratch."
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
    log_info "Running Spock setup..."
    bash "$SCRIPT_DIR/setup-spock.sh"
    cmd_status
}

cmd_test() {
    log_head "=== Integration Tests ==="
    local errors=0
    local test_num=0

    run_test() {
        test_num=$((test_num + 1))
        local desc="$1"
        echo -n "  Test $test_num: $desc ... "
    }
    pass() { echo -e "${GREEN}PASS${NC}"; }
    fail() { echo -e "${RED}FAIL${NC} -- $*"; errors=$((errors + 1)); }

    # --- Wait for cluster ---
    log_info "Checking cluster readiness..."
    local ready=false
    for i in $(seq 1 10); do
        if PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT 1" >/dev/null 2>&1; then
            ready=true; break
        fi
        sleep 2
    done
    if ! $ready; then
        log_error "Cluster not ready after 20s. Aborting tests."
        exit 1
    fi

    # --- Test 1: HAProxy R/W routes to a primary ---
    run_test "HAProxy R/W routes to primary"
    local is_primary
    is_primary=$(PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW" -U "$PG_USER" -d "$PG_DB" -tAc \
        "SELECT NOT pg_is_in_recovery()" 2>/dev/null)
    [ "$is_primary" = "t" ] && pass || fail "R/W port not routing to primary"

    # --- Test 2: HAProxy RO routes to a replica ---
    run_test "HAProxy RO routes to replica"
    local is_replica
    is_replica=$(PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RO" -U "$PG_USER" -d "$PG_DB" -tAc \
        "SELECT pg_is_in_recovery()" 2>/dev/null)
    [ "$is_replica" = "t" ] && pass || fail "RO port not routing to replica"

    # --- Test 3: Both R/W nodes are primaries ---
    run_test "Both node1 and node2 are primaries (R/W)"
    local n1_primary n2_primary
    n1_primary=$(run_sql_on "$NODE1_PORT" "SELECT NOT pg_is_in_recovery()")
    n2_primary=$(run_sql_on "$NODE2_PORT" "SELECT NOT pg_is_in_recovery()")
    [ "$n1_primary" = "t" ] && [ "$n2_primary" = "t" ] && pass || fail "node1=$n1_primary, node2=$n2_primary"

    # --- Test 4: Both RO nodes are replicas ---
    run_test "Both node3 and node4 are replicas (RO)"
    local n3_replica n4_replica
    n3_replica=$(run_sql_on "$NODE3_PORT" "SELECT pg_is_in_recovery()")
    n4_replica=$(run_sql_on "$NODE4_PORT" "SELECT pg_is_in_recovery()")
    [ "$n3_replica" = "t" ] && [ "$n4_replica" = "t" ] && pass || fail "node3=$n3_replica, node4=$n4_replica"

    # --- Test 5: Spock extension loaded on both primaries ---
    run_test "Spock extension on node1 and node2"
    local spock1 spock2
    spock1=$(run_sql_on "$NODE1_PORT" "SELECT extname FROM pg_extension WHERE extname = 'spock'")
    spock2=$(run_sql_on "$NODE2_PORT" "SELECT extname FROM pg_extension WHERE extname = 'spock'")
    [ "$spock1" = "spock" ] && [ "$spock2" = "spock" ] && pass || fail "node1=$spock1, node2=$spock2"

    # --- Test 6: pg_stat_statements loaded ---
    run_test "pg_stat_statements extension loaded"
    local pgss
    pgss=$(run_sql_on "$NODE1_PORT" "SELECT extname FROM pg_extension WHERE extname = 'pg_stat_statements'")
    [ "$pgss" = "pg_stat_statements" ] && pass || fail "pg_stat_statements not found"

    # --- Test 7: Spock subscriptions active on both nodes ---
    run_test "Spock subscriptions active (bidirectional)"
    local sub1 sub2
    sub1=$(run_sql_on "$NODE1_PORT" "SELECT count(*) FROM spock.subscription WHERE sub_enabled = true")
    sub2=$(run_sql_on "$NODE2_PORT" "SELECT count(*) FROM spock.subscription WHERE sub_enabled = true")
    [ "${sub1:-0}" -ge 1 ] && [ "${sub2:-0}" -ge 1 ] && pass || fail "node1_subs=$sub1, node2_subs=$sub2"

    # --- Test 8: Write via HAProxy R/W ---
    run_test "Write via HAProxy R/W"
    # Create test table on BOTH primaries (Spock doesn't replicate DDL)
    run_sql_on "$NODE1_PORT" "CREATE TABLE IF NOT EXISTS _test_spock (id serial PRIMARY KEY, val text, ts timestamptz DEFAULT now());" >/dev/null 2>&1
    run_sql_on "$NODE2_PORT" "CREATE TABLE IF NOT EXISTS _test_spock (id serial PRIMARY KEY, val text, ts timestamptz DEFAULT now());" >/dev/null 2>&1
    # Add to Spock replication set on both nodes
    run_sql_on "$NODE1_PORT" "SELECT spock.repset_add_table('default', '_test_spock');" >/dev/null 2>&1
    run_sql_on "$NODE2_PORT" "SELECT spock.repset_add_table('default', '_test_spock');" >/dev/null 2>&1
    # Configure sequences for multi-master
    run_sql_on "$NODE1_PORT" "ALTER SEQUENCE _test_spock_id_seq INCREMENT BY 2 RESTART WITH 1;" >/dev/null 2>&1
    run_sql_on "$NODE2_PORT" "ALTER SEQUENCE _test_spock_id_seq INCREMENT BY 2 RESTART WITH 2;" >/dev/null 2>&1
    # Write directly to node1 (deterministic target)
    run_sql_on "$NODE1_PORT" "INSERT INTO _test_spock (val) VALUES ('hello_spock');" >/dev/null 2>&1
    local write_result
    write_result=$(run_sql_on "$NODE1_PORT" "SELECT val FROM _test_spock WHERE val = 'hello_spock' LIMIT 1")
    [ "$write_result" = "hello_spock" ] && pass || fail "Write failed"

    # --- Test 9: Spock replication (node1 -> node2) ---
    run_test "Spock replication node1 -> node2"
    # Insert on node1, check on node2
    run_sql_on "$NODE1_PORT" "INSERT INTO _test_spock (val) VALUES ('from_node1');" >/dev/null 2>&1
    sleep 2
    local repl_n2
    repl_n2=$(run_sql_on "$NODE2_PORT" "SELECT val FROM _test_spock WHERE val = 'from_node1' LIMIT 1")
    [ "$repl_n2" = "from_node1" ] && pass || fail "Not replicated to node2 (got: $repl_n2)"

    # --- Test 10: Spock replication (node2 -> node1) ---
    run_test "Spock replication node2 -> node1"
    run_sql_on "$NODE2_PORT" "INSERT INTO _test_spock (val) VALUES ('from_node2');" >/dev/null 2>&1
    sleep 2
    local repl_n1
    repl_n1=$(run_sql_on "$NODE1_PORT" "SELECT val FROM _test_spock WHERE val = 'from_node2' LIMIT 1")
    [ "$repl_n1" = "from_node2" ] && pass || fail "Not replicated to node1 (got: $repl_n1)"

    # --- Test 11: Streaming replica node3 has data ---
    run_test "Streaming replica node3 has data"
    sleep 1
    local repl_n3
    repl_n3=$(run_sql_on "$NODE3_PORT" "SELECT count(*) FROM _test_spock")
    [ "${repl_n3:-0}" -ge 3 ] && pass || fail "Expected >=3 rows, got ${repl_n3:-0}"

    # --- Test 12: Streaming replica node4 has data ---
    run_test "Streaming replica node4 has data"
    local repl_n4
    repl_n4=$(run_sql_on "$NODE4_PORT" "SELECT count(*) FROM _test_spock")
    [ "${repl_n4:-0}" -ge 3 ] && pass || fail "Expected >=3 rows, got ${repl_n4:-0}"

    # --- Test 13: Read via HAProxy RO returns replicated data ---
    run_test "Read via HAProxy RO returns replicated data"
    local ro_result
    ro_result=$(run_sql_ro "SELECT count(*) FROM _test_spock")
    [ "${ro_result:-0}" -ge 3 ] && pass || fail "Expected >=3 rows via RO, got ${ro_result:-0}"

    # --- Test 14: HAProxy R/W round-robin distributes to both nodes ---
    run_test "HAProxy R/W round-robin across node1 and node2"
    local addrs=""
    for i in 1 2 3 4; do
        local addr
        addr=$(PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RW" -U "$PG_USER" -d "$PG_DB" -tAc \
            "SELECT inet_server_addr()" 2>/dev/null) || addr=""
        addrs="$addrs $addr"
    done
    local unique_addrs
    unique_addrs=$(echo "$addrs" | tr ' ' '\n' | sort -u | grep -c '.')
    [ "$unique_addrs" -ge 2 ] && pass || fail "Only reached $unique_addrs unique backend(s)"

    # --- Test 15: HAProxy RO round-robin distributes to both replicas ---
    run_test "HAProxy RO round-robin across node3 and node4"
    local ro_addrs=""
    for i in 1 2 3 4; do
        local addr
        addr=$(PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$HAPROXY_RO" -U "$PG_USER" -d "$PG_DB" -tAc \
            "SELECT inet_server_addr()" 2>/dev/null) || addr=""
        ro_addrs="$ro_addrs $addr"
    done
    local unique_ro
    unique_ro=$(echo "$ro_addrs" | tr ' ' '\n' | sort -u | grep -c '.')
    [ "$unique_ro" -ge 2 ] && pass || fail "Only reached $unique_ro unique RO backend(s)"

    # --- Test 16: Data checksums enabled ---
    run_test "Data checksums enabled"
    local checksums
    checksums=$(run_sql_on "$NODE1_PORT" "SHOW data_checksums")
    [ "$checksums" = "on" ] && pass || fail "data_checksums=$checksums"

    # --- Test 17: JIT disabled (autobase recommendation) ---
    run_test "JIT disabled (autobase recommendation)"
    local jit_val
    jit_val=$(run_sql_on "$NODE1_PORT" "SHOW jit")
    [ "$jit_val" = "off" ] && pass || fail "jit=$jit_val"

    # --- Test 18: Autovacuum aggressive tuning ---
    run_test "Autovacuum scale factor = 0.01 (autobase)"
    local av_scale
    av_scale=$(run_sql_on "$NODE1_PORT" "SHOW autovacuum_vacuum_scale_factor")
    [ "$av_scale" = "0.01" ] && pass || fail "autovacuum_vacuum_scale_factor=$av_scale"

    # --- Test 19: SSD-optimized planner ---
    run_test "SSD planner: random_page_cost = 1.1"
    local rpc
    rpc=$(run_sql_on "$NODE1_PORT" "SHOW random_page_cost")
    [ "$rpc" = "1.1" ] && pass || fail "random_page_cost=$rpc"

    # --- Test 20: Bulk writes via HAProxy R/W ---
    run_test "Bulk writes via HAProxy R/W (100 rows)"
    # Write to node1 directly (HAProxy round-robin + single INSERT may hit either node,
    # and checking via HAProxy could hit the other node before Spock replicates)
    run_sql_on "$NODE1_PORT" "INSERT INTO _test_spock (val) SELECT 'bulk_' || generate_series(1,100);" >/dev/null 2>&1
    local bulk_count
    bulk_count=$(run_sql_on "$NODE1_PORT" "SELECT count(*) FROM _test_spock WHERE val LIKE 'bulk_%'")
    [ "${bulk_count:-0}" -eq 100 ] && pass || fail "Expected 100 rows, got ${bulk_count:-0}"

    # Cleanup — remove from Spock repset before dropping
    run_sql_on "$NODE1_PORT" "SELECT spock.repset_remove_table('default', '_test_spock');" >/dev/null 2>&1
    run_sql_on "$NODE2_PORT" "SELECT spock.repset_remove_table('default', '_test_spock');" >/dev/null 2>&1
    run_sql_on "$NODE1_PORT" "DROP TABLE IF EXISTS _test_spock;" >/dev/null 2>&1
    run_sql_on "$NODE2_PORT" "DROP TABLE IF EXISTS _test_spock;" >/dev/null 2>&1

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

    # Initialize pgbench tables on BOTH primaries independently.
    # We cannot use Spock to replicate pgbench data because:
    #   1. Spock doesn't replicate DDL (CREATE TABLE)
    #   2. pgbench -i uses COPY which may not replicate for initial bulk load
    #   3. TPC-B does UPDATE by random aid — round-robin R/W to 2 masters
    #      would cause UPDATE/UPDATE conflicts on the same row
    # So we initialize each node independently and benchmark them separately.

    log_info "Initializing pgbench tables on node1 (scale 10)..."
    PGPASSWORD="$PGPASSWORD" pgbench -h localhost -p "$NODE1_PORT" -U "$PG_USER" -d "$PG_DB" -i -s 10 2>&1 | tail -3

    log_info "Initializing pgbench tables on node2 (scale 10)..."
    PGPASSWORD="$PGPASSWORD" pgbench -h localhost -p "$NODE2_PORT" -U "$PG_USER" -d "$PG_DB" -i -s 10 2>&1 | tail -3

    # Verify row counts
    local n1_count n2_count
    n1_count=$(run_sql_on "$NODE1_PORT" "SELECT count(*) FROM pgbench_accounts") || n1_count=0
    n2_count=$(run_sql_on "$NODE2_PORT" "SELECT count(*) FROM pgbench_accounts") || n2_count=0
    log_info "pgbench_accounts: node1=$n1_count rows, node2=$n2_count rows"

    # Part 1: TPC-B write on node1 (primary #1)
    log_head "--- Part 1: TPC-B Write (node1 :$NODE1_PORT, 60s) ---"
    log_info "Direct write to Spock primary #1"
    PGPASSWORD="$PGPASSWORD" pgbench -h localhost -p "$NODE1_PORT" -U "$PG_USER" -d "$PG_DB" \
        -c 10 -j 2 -T 60 --no-vacuum 2>&1 | grep -E "^(tps|number|latency)"

    # Part 2: SELECT-only via HAProxy RO (read replicas)
    log_head "--- Part 2: SELECT-only Read (HAProxy RO :$HAPROXY_RO, 60s) ---"
    log_info "Reads round-robin across node3 + node4 (streaming replicas)"
    PGPASSWORD="$PGPASSWORD" pgbench -h localhost -p "$HAPROXY_RO" -U "$PG_USER" -d "$PG_DB" \
        -c 10 -j 2 -T 60 -S --no-vacuum 2>&1 | grep -E "^(tps|number|latency)"

    # Part 3: TPC-B write on node2 (primary #2)
    log_head "--- Part 3: TPC-B Write (node2 :$NODE2_PORT, 60s) ---"
    log_info "Direct write to Spock primary #2 — confirms both masters perform equally"
    PGPASSWORD="$PGPASSWORD" pgbench -h localhost -p "$NODE2_PORT" -U "$PG_USER" -d "$PG_DB" \
        -c 10 -j 2 -T 60 --no-vacuum 2>&1 | grep -E "^(tps|number|latency)"

    # Cleanup
    log_info "Cleaning up pgbench tables..."
    for port in "$NODE1_PORT" "$NODE2_PORT"; do
        PGPASSWORD="$PGPASSWORD" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c \
            "DROP TABLE IF EXISTS pgbench_history, pgbench_accounts, pgbench_tellers, pgbench_branches;" >/dev/null 2>&1
    done
    log_ok "Benchmark complete"
}

cmd_logs() {
    local target="${1:-all}"
    case "$target" in
        all)            $COMPOSE logs -f --tail=50 ;;
        haproxy|ha)     $COMPOSE logs -f --tail=50 haproxy ;;
        node1|n1|1)     $COMPOSE logs -f --tail=50 node1 ;;
        node2|n2|2)     $COMPOSE logs -f --tail=50 node2 ;;
        node3|n3|3)     $COMPOSE logs -f --tail=50 node3 ;;
        node4|n4|4)     $COMPOSE logs -f --tail=50 node4 ;;
        primaries|rw)   $COMPOSE logs -f --tail=50 node1 node2 ;;
        replicas|ro)    $COMPOSE logs -f --tail=50 node3 node4 ;;
        *)
            log_error "Unknown target: $target"
            echo "  Targets: all, haproxy, node1..4, primaries, replicas"
            exit 1
            ;;
    esac
}

cmd_help() {
    echo "pg_spock — PostgreSQL 18 + Spock Multi-Master (2x R/W + 2x RO + HAProxy)"
    echo ""
    echo "Usage: ./scripts/manage.sh [command] [args...]"
    echo ""
    echo "Info:"
    echo "  status              Cluster health overview (nodes, Spock, HAProxy, replication)"
    echo "  topology            Detailed Spock + streaming replication topology"
    echo "  logs [target]       Stream logs (all|haproxy|node1..4|primaries|replicas)"
    echo ""
    echo "Access:"
    echo "  psql [target]       Interactive psql (rw|ro|node1..4)"
    echo ""
    echo "Setup:"
    echo "  setup               Run Spock setup (nodes, subscriptions, test data)"
    echo "  reinit              Full cluster reinit (DESTROYS ALL DATA)"
    echo ""
    echo "Test & Benchmark:"
    echo "  test                Run integration tests (20 tests)"
    echo "  bench               Run pgbench benchmarks (TPC-B + SELECT-only)"
    echo ""
    echo "Connection Info:"
    echo "  HAProxy R/W:   localhost:${HAPROXY_RW} (round-robin node1 + node2)"
    echo "  HAProxy RO:    localhost:${HAPROXY_RO} (round-robin node3 + node4)"
    echo "  HAProxy Stats: http://localhost:${HAPROXY_STATS}/"
    echo "  Node 1 direct: localhost:${NODE1_PORT} (R/W, Spock primary)"
    echo "  Node 2 direct: localhost:${NODE2_PORT} (R/W, Spock primary)"
    echo "  Node 3 direct: localhost:${NODE3_PORT} (RO, streams from node1)"
    echo "  Node 4 direct: localhost:${NODE4_PORT} (RO, streams from node2)"
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
    setup)               cmd_setup ;;
    reinit)              cmd_reinit ;;
    test)                cmd_test ;;
    bench|benchmark)     cmd_bench ;;
    logs|log)            cmd_logs "$@" ;;
    help|--help|-h)      cmd_help ;;
    *)
        log_error "Unknown command: $COMMAND"
        cmd_help
        exit 1
        ;;
esac
