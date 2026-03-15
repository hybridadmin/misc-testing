#!/bin/bash
# =============================================================================
# Citus Distributed Cluster Management Script
# Usage: ./manage.sh [command]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

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
log_head()  { echo -e "${CYAN}$*${NC}"; }

if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

PG_USER="${POSTGRES_USER:-postgres}"
PG_PASS="${POSTGRES_PASSWORD:-changeme_postgres_2025}"
PG_DB="${POSTGRES_DB:-appdb}"
VIP="${KEEPALIVED_VIP:-172.34.0.100}"

COORDINATOR="cit-coordinator"
COORDINATOR_PORT=5941
STANDBY="cit-coordinator-standby"
STANDBY_PORT=5942
WORKERS=("cit-worker1" "cit-worker2")
WORKER_PORTS=(5943 5944)
ALL_PG_CONTAINERS=("$COORDINATOR" "$STANDBY" "${WORKERS[@]}")
ALL_PG_PORTS=("$COORDINATOR_PORT" "$STANDBY_PORT" "${WORKER_PORTS[@]}")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run SQL on coordinator (all distributed queries go through coordinator)
run_sql() {
    local sql="$1"
    PGPASSWORD="$PG_PASS" psql -h localhost -p "$COORDINATOR_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "$sql" 2>/dev/null
}

# Run SQL on a specific port
run_sql_on() {
    local port="$1"
    local sql="$2"
    PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "$sql" 2>/dev/null
}

# Run SQL with formatted output on coordinator
run_sql_fmt() {
    local sql="$1"
    PGPASSWORD="$PG_PASS" psql -h localhost -p "$COORDINATOR_PORT" -U "$PG_USER" -d "$PG_DB" -c "$sql" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_status() {
    log_head "=== Citus 14.0 Distributed Cluster Status ==="
    echo ""

    # --- Primary Coordinator ---
    log_info "Coordinator (primary):"
    STATE=$(docker exec "$COORDINATOR" pg_isready -h localhost -U "$PG_USER" 2>/dev/null && echo "accepting" || echo "unreachable")
    if [[ "$STATE" == *"accepting"* ]]; then
        CITUS_VER=$(run_sql "SELECT extversion FROM pg_extension WHERE extname='citus';" || echo "?")
        PG_VER=$(run_sql "SELECT version();" || echo "?")
        NODE_COUNT=$(run_sql "SELECT count(*) FROM pg_dist_node;" || echo "?")
        WORKER_COUNT=$(run_sql "SELECT count(*) FROM citus_get_active_worker_nodes();" || echo "?")
        IS_RECOVERY=$(run_sql "SELECT pg_is_in_recovery();" || echo "?")
        log_ok "$COORDINATOR: UP  citus=$CITUS_VER  nodes=$NODE_COUNT  workers=$WORKER_COUNT  recovery=$IS_RECOVERY"
        echo "    PG: $PG_VER"
    else
        log_error "$COORDINATOR: UNREACHABLE"
    fi

    # --- Coordinator Standby ---
    echo ""
    log_info "Coordinator (standby):"
    STANDBY_STATE=$(docker exec "$STANDBY" pg_isready -h localhost -U "$PG_USER" 2>/dev/null && echo "accepting" || echo "unreachable")
    if [[ "$STANDBY_STATE" == *"accepting"* ]]; then
        STANDBY_RECOVERY=$(run_sql_on "$STANDBY_PORT" "SELECT pg_is_in_recovery();" || echo "?")
        STANDBY_LSN=$(run_sql_on "$STANDBY_PORT" "SELECT pg_last_wal_replay_lsn();" || echo "?")
        if [ "$STANDBY_RECOVERY" = "t" ]; then
            log_ok "$STANDBY: UP  role=standby  replay_lsn=$STANDBY_LSN"
        else
            log_warn "$STANDBY: UP  role=PRIMARY (promoted!)  lsn=$STANDBY_LSN"
        fi
    else
        log_error "$STANDBY: UNREACHABLE"
    fi

    # --- Replication status (from primary) ---
    echo ""
    log_info "Streaming Replication:"
    if [[ "$STATE" == *"accepting"* ]]; then
        REPL_INFO=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "$COORDINATOR_PORT" -U "$PG_USER" -d "$PG_DB" \
            -c "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn, sync_state FROM pg_stat_replication;" 2>/dev/null)
        if echo "$REPL_INFO" | grep -q "streaming"; then
            echo "$REPL_INFO"
        else
            log_warn "  No active replication connections"
        fi
    elif [[ "$STANDBY_STATE" == *"accepting"* ]] && [ "$STANDBY_RECOVERY" = "f" ]; then
        log_warn "  Primary is down — standby has been promoted"
    else
        log_error "  Cannot check replication (primary unreachable)"
    fi

    # --- Workers ---
    echo ""
    log_info "Workers:"
    for i in "${!WORKERS[@]}"; do
        local worker="${WORKERS[$i]}"
        local port="${WORKER_PORTS[$i]}"
        STATE=$(docker exec "$worker" pg_isready -h localhost -U "$PG_USER" 2>/dev/null && echo "accepting" || echo "unreachable")
        if [[ "$STATE" == *"accepting"* ]]; then
            CITUS_VER=$(run_sql_on "$port" "SELECT extversion FROM pg_extension WHERE extname='citus';" || echo "?")
            log_ok "$worker: UP  citus=$CITUS_VER  port=$port"
        else
            log_error "$worker: UNREACHABLE"
        fi
    done

    echo ""
    log_info "Cluster Topology:"
    run_sql_fmt "SELECT nodeid, nodename, nodeport, noderole, isactive FROM pg_dist_node ORDER BY nodeid;" || log_error "Cannot query cluster topology"

    echo ""
    log_info "Shard Distribution:"
    run_sql_fmt "SELECT nodename, count(*) as shard_count FROM citus_shards GROUP BY nodename ORDER BY nodename;" 2>/dev/null || echo "    (no distributed tables yet)"

    echo ""
    log_info "VIP Status:"
    cmd_vip_status

    echo ""
    log_info "Failover Monitor:"
    cmd_monitor_status

    echo ""
    log_info "Valkey Cluster:"
    docker exec cit-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning INFO replication 2>/dev/null | grep -E "role:|connected_slaves:" || log_error "Valkey unreachable"
}

cmd_vip_status() {
    log_info "  VIP address: $VIP"
    local vip_holder="none"
    local coord_containers=("$COORDINATOR" "$STANDBY")
    for c in "${coord_containers[@]}"; do
        local has_vip
        has_vip=$(docker exec "$c" ip addr show eth0 2>/dev/null | grep "$VIP" || true)
        if [ -n "$has_vip" ]; then
            vip_holder="$c"
            log_ok "  VIP holder: $c"
        fi
    done
    if [ "$vip_holder" = "none" ]; then
        log_warn "  VIP holder: NONE (failover monitor may still be starting)"
    fi
}

cmd_monitor_status() {
    local coord_containers=("$COORDINATOR" "$STANDBY")
    local labels=("primary" "standby")
    for i in "${!coord_containers[@]}"; do
        local c="${coord_containers[$i]}"
        local label="${labels[$i]}"
        local running="no"
        # Check by PID file first, then by process name
        if docker exec "$c" test -f /tmp/failover-monitor.pid 2>/dev/null; then
            docker exec "$c" kill -0 "$(docker exec "$c" cat /tmp/failover-monitor.pid 2>/dev/null)" 2>/dev/null && running="yes"
        fi
        if [ "$running" = "no" ]; then
            # Fallback: check if failover-monitor.sh process exists
            docker exec "$c" pgrep -f "failover-monitor.sh" >/dev/null 2>&1 && running="yes"
        fi
        if [ "$running" = "yes" ]; then
            local last_log
            last_log=$(docker exec "$c" tail -1 /tmp/failover-monitor.log 2>/dev/null || echo "")
            log_ok "  $c ($label): running"
            [ -n "$last_log" ] && echo "    last: $last_log"
        else
            log_warn "  $c ($label): not running"
        fi
    done
}

cmd_psql() {
    local target="${1:-coordinator}"
    local port="$COORDINATOR_PORT"

    case "$target" in
        coordinator|coord) port="$COORDINATOR_PORT" ;;
        standby|sb)        port="$STANDBY_PORT" ;;
        worker1|w1)        port="${WORKER_PORTS[0]}" ;;
        worker2|w2)        port="${WORKER_PORTS[1]}" ;;
        *)
            log_error "Unknown target: $target (use: coordinator, standby, worker1, worker2)"
            return 1
            ;;
    esac

    log_info "Connecting to $target on port $port..."
    PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB"
}

cmd_ddl() {
    local sql="${1:-}"

    if [ -z "$sql" ]; then
        echo "Usage: $0 ddl \"SQL statement\""
        echo ""
        echo "Executes DDL on the coordinator. Citus automatically propagates DDL to workers."
        echo "This is a major advantage over logical replication — no manual per-node execution needed."
        echo ""
        echo "Examples:"
        echo "  $0 ddl \"CREATE TABLE users (id bigint, name text); SELECT create_distributed_table('users', 'id');\""
        echo "  $0 ddl \"CREATE TABLE config (key text PRIMARY KEY, val text); SELECT create_reference_table('config');\""
        echo "  $0 ddl \"ALTER TABLE users ADD COLUMN email text;\""
        return 1
    fi

    log_info "Executing DDL on coordinator (Citus will propagate to workers)..."
    if PGPASSWORD="$PG_PASS" psql -h localhost -p "$COORDINATOR_PORT" -U "$PG_USER" -d "$PG_DB" -c "$sql" 2>&1; then
        log_ok "DDL executed successfully"
    else
        log_error "DDL execution failed"
        return 1
    fi
}

cmd_test() {
    log_head "=== Citus Distributed Cluster Integration Test ==="
    echo ""
    local errors=0

    # Test 1: Coordinator connectivity
    log_info "Test 1: Coordinator connectivity"
    if run_sql "SELECT 1;" >/dev/null 2>&1; then
        log_ok "Coordinator accepting connections"
    else
        log_error "Coordinator not accepting connections"
        errors=$((errors + 1))
    fi

    # Test 2: Citus extension
    log_info "Test 2: Citus extension loaded"
    CITUS_OK=$(run_sql "SELECT count(*) FROM pg_extension WHERE extname='citus';" || echo "0")
    if [ "$CITUS_OK" = "1" ]; then
        log_ok "Citus extension loaded"
    else
        log_error "Citus extension not loaded"
        errors=$((errors + 1))
    fi

    # Test 3: Workers registered
    log_info "Test 3: Workers registered"
    WORKER_COUNT=$(run_sql "SELECT count(*) FROM citus_get_active_worker_nodes();" || echo "0")
    if [ "$WORKER_COUNT" = "2" ]; then
        log_ok "Both workers registered ($WORKER_COUNT active)"
    else
        log_error "Expected 2 workers, got $WORKER_COUNT"
        errors=$((errors + 1))
    fi

    # Test 4: Create distributed table, insert, query
    log_info "Test 4: Distributed table CRUD"
    run_sql "DROP TABLE IF EXISTS _test_dist CASCADE;" >/dev/null 2>&1
    if run_sql "CREATE TABLE _test_dist (id bigint, val text); SELECT create_distributed_table('_test_dist', 'id');" >/dev/null 2>&1; then
        log_ok "Created distributed table _test_dist"
    else
        log_error "Failed to create distributed table"
        errors=$((errors + 1))
    fi

    if run_sql "INSERT INTO _test_dist SELECT g, 'row-' || g FROM generate_series(1,1000) g;" >/dev/null 2>&1; then
        COUNT=$(run_sql "SELECT count(*) FROM _test_dist;")
        if [ "$COUNT" = "1000" ]; then
            log_ok "Insert + count verified ($COUNT rows)"
        else
            log_error "Expected 1000 rows, got $COUNT"
            errors=$((errors + 1))
        fi
    else
        log_error "Failed to insert rows"
        errors=$((errors + 1))
    fi

    # Test 5: Verify shards distributed across workers
    log_info "Test 5: Shard distribution"
    SHARD_NODES=$(run_sql "SELECT count(DISTINCT nodename) FROM citus_shards WHERE table_name = '_test_dist'::regclass;" || echo "0")
    if [ "$SHARD_NODES" = "2" ]; then
        log_ok "Shards distributed across $SHARD_NODES workers"
    else
        log_warn "Shards only on $SHARD_NODES node(s) (expected 2)"
    fi

    # Test 6: Reference table
    log_info "Test 6: Reference table"
    run_sql "DROP TABLE IF EXISTS _test_ref CASCADE;" >/dev/null 2>&1
    if run_sql "CREATE TABLE _test_ref (key text PRIMARY KEY, val text); SELECT create_reference_table('_test_ref');" >/dev/null 2>&1; then
        run_sql "INSERT INTO _test_ref VALUES ('k1', 'v1');" >/dev/null 2>&1
        # Reference tables are replicated to all workers — verify on a worker directly
        W1_COUNT=$(run_sql_on "${WORKER_PORTS[0]}" "SELECT count(*) FROM _test_ref;" || echo "0")
        W2_COUNT=$(run_sql_on "${WORKER_PORTS[1]}" "SELECT count(*) FROM _test_ref;" || echo "0")
        if [ "$W1_COUNT" = "1" ] && [ "$W2_COUNT" = "1" ]; then
            log_ok "Reference table replicated to both workers"
        else
            log_warn "Reference table: worker1=$W1_COUNT worker2=$W2_COUNT (expected 1 each)"
        fi
    else
        log_error "Failed to create reference table"
        errors=$((errors + 1))
    fi

    # Test 7: Valkey connectivity
    log_info "Test 7: Valkey connectivity"
    if docker exec cit-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning PING 2>/dev/null | grep -q PONG; then
        log_ok "Valkey master responding"
    else
        log_error "Valkey master not responding"
        errors=$((errors + 1))
    fi

    # Test 8: Coordinator standby streaming replication
    log_info "Test 8: Coordinator standby replication"
    STANDBY_STATE=$(docker exec "$STANDBY" pg_isready -h localhost -U "$PG_USER" 2>/dev/null && echo "accepting" || echo "unreachable")
    if [[ "$STANDBY_STATE" == *"accepting"* ]]; then
        STANDBY_RECOVERY=$(run_sql_on "$STANDBY_PORT" "SELECT pg_is_in_recovery();" || echo "?")
        if [ "$STANDBY_RECOVERY" = "t" ]; then
            REPL_STATE=$(run_sql "SELECT state FROM pg_stat_replication WHERE client_addr='172.34.0.11' LIMIT 1;" || echo "?")
            if [ "$REPL_STATE" = "streaming" ]; then
                log_ok "Standby is streaming from primary"
            else
                log_warn "Standby connected but replication state: $REPL_STATE"
            fi
        else
            log_warn "Standby is not in recovery (may have been promoted)"
        fi
    else
        log_warn "Standby is unreachable"
    fi

    # Test 9: VIP assigned
    log_info "Test 9: VIP assigned"
    VIP_ON_PRIMARY=$(docker exec "$COORDINATOR" ip addr show eth0 2>/dev/null | grep "$VIP" || true)
    VIP_ON_STANDBY=$(docker exec "$STANDBY" ip addr show eth0 2>/dev/null | grep "$VIP" || true)
    if [ -n "$VIP_ON_PRIMARY" ] || [ -n "$VIP_ON_STANDBY" ]; then
        local holder="$COORDINATOR"
        [ -n "$VIP_ON_STANDBY" ] && holder="$STANDBY"
        log_ok "VIP $VIP assigned to $holder"
    else
        log_warn "VIP not assigned to any coordinator (monitor may be starting)"
    fi

    # Cleanup
    log_info "Cleaning up test tables..."
    run_sql "DROP TABLE IF EXISTS _test_dist CASCADE;" >/dev/null 2>&1
    run_sql "DROP TABLE IF EXISTS _test_ref CASCADE;" >/dev/null 2>&1

    echo ""
    if [ "$errors" -eq 0 ]; then
        log_ok "All tests passed!"
    else
        log_error "$errors test(s) failed"
        return 1
    fi
}

cmd_bench() {
    local duration="${1:-10}"
    local clients="${2:-8}"

    log_head "=== Citus Distributed Cluster Benchmark ==="
    echo ""
    log_info "Parameters: duration=${duration}s, clients=${clients}"
    log_info "Target: coordinator on port $COORDINATOR_PORT"
    echo ""

    # Ensure pgbench is available
    if ! command -v pgbench &>/dev/null; then
        log_error "pgbench not found. Install postgresql-client."
        return 1
    fi

    # -----------------------------------------------------------------------
    # Part 1: Standard pgbench TPC-B (for apples-to-apples comparison with
    # multi-master variants). NOTE: TPC-B is a worst-case for Citus because
    # each transaction touches multiple tables across shards requiring 2PC.
    # -----------------------------------------------------------------------
    log_head "--- Part 1: Standard pgbench TPC-B (cross-shard, apples-to-apples) ---"
    echo ""

    log_info "Setting up pgbench tables..."
    run_sql "DROP TABLE IF EXISTS pgbench_history CASCADE;" >/dev/null 2>&1
    run_sql "DROP TABLE IF EXISTS pgbench_tellers CASCADE;" >/dev/null 2>&1
    run_sql "DROP TABLE IF EXISTS pgbench_branches CASCADE;" >/dev/null 2>&1
    run_sql "DROP TABLE IF EXISTS pgbench_accounts CASCADE;" >/dev/null 2>&1

    PGPASSWORD="$PG_PASS" pgbench -i -s 10 -h localhost -p "$COORDINATOR_PORT" -U "$PG_USER" "$PG_DB" 2>&1

    log_info "Distributing pgbench tables across workers..."
    run_sql "SELECT create_distributed_table('pgbench_accounts', 'aid');" >/dev/null 2>&1 || true
    run_sql "SELECT create_reference_table('pgbench_branches');" >/dev/null 2>&1 || true
    run_sql "SELECT create_reference_table('pgbench_tellers');" >/dev/null 2>&1 || true
    run_sql "SELECT create_distributed_table('pgbench_history', 'aid');" >/dev/null 2>&1 || true

    echo ""
    log_info "Shard distribution:"
    run_sql_fmt "SELECT nodename, count(*) as shard_count FROM citus_shards GROUP BY nodename ORDER BY nodename;"

    echo ""
    log_info "Write (TPC-B): ${duration}s, ${clients} clients..."
    PGPASSWORD="$PG_PASS" pgbench -h localhost -p "$COORDINATOR_PORT" -U "$PG_USER" -d "$PG_DB" \
        -T "$duration" -c "$clients" -j 4 --no-vacuum 2>&1

    echo ""
    log_info "Read (SELECT-only on pgbench_accounts): ${duration}s, ${clients} clients..."
    PGPASSWORD="$PG_PASS" pgbench -h localhost -p "$COORDINATOR_PORT" -U "$PG_USER" -d "$PG_DB" \
        -T "$duration" -c "$clients" -j 4 -S --no-vacuum 2>&1

    log_info "Cleaning up pgbench tables..."
    run_sql "DROP TABLE IF EXISTS pgbench_history CASCADE;" >/dev/null 2>&1
    run_sql "DROP TABLE IF EXISTS pgbench_tellers CASCADE;" >/dev/null 2>&1
    run_sql "DROP TABLE IF EXISTS pgbench_branches CASCADE;" >/dev/null 2>&1
    run_sql "DROP TABLE IF EXISTS pgbench_accounts CASCADE;" >/dev/null 2>&1

    # -----------------------------------------------------------------------
    # Part 2: Single-shard operations (Citus-optimized). This is the realistic
    # benchmark — in production you'd route queries to a single shard via the
    # distribution key. No 2PC overhead, work is pushed to workers.
    # -----------------------------------------------------------------------
    echo ""
    log_head "--- Part 2: Single-shard operations (Citus-optimized) ---"
    echo ""

    log_info "Setting up distributed benchmark table..."
    run_sql "DROP TABLE IF EXISTS _bench_dist CASCADE;" >/dev/null 2>&1
    run_sql "CREATE TABLE _bench_dist (
        id bigint NOT NULL,
        account_id bigint NOT NULL,
        val text,
        amount numeric(15,2) DEFAULT 0.00,
        ts timestamp DEFAULT now(),
        PRIMARY KEY (account_id, id)
    );" >/dev/null 2>&1
    run_sql "SELECT create_distributed_table('_bench_dist', 'account_id');" >/dev/null 2>&1

    log_info "Seeding 500k rows..."
    run_sql "INSERT INTO _bench_dist (id, account_id, val, amount)
        SELECT g, (g % 10000) + 1, 'data-' || g, (random() * 10000)::numeric(15,2)
        FROM generate_series(1, 500000) g;" >/dev/null 2>&1
    log_ok "Seed complete"

    # Custom pgbench script: single-shard writes (INSERT only, same partition key)
    local write_script
    write_script=$(mktemp /tmp/citus_bench_write.XXXXXX)
    cat > "$write_script" <<'ENDSQL'
\set aid random(1, 10000)
\set val random(1, 999999999)
\set amt random(1, 10000)
INSERT INTO _bench_dist (id, account_id, val, amount)
    VALUES (:val + (1000000000::bigint * :client_id), :aid, 'bench-' || :val, :amt);
ENDSQL

    # Custom pgbench script: single-shard point reads
    local read_script
    read_script=$(mktemp /tmp/citus_bench_read.XXXXXX)
    cat > "$read_script" <<'ENDSQL'
\set aid random(1, 10000)
SELECT id, val, amount FROM _bench_dist WHERE account_id = :aid LIMIT 5;
ENDSQL

    # Custom pgbench script: aggregation across shards (scatter-gather, small range)
    local agg_script
    agg_script=$(mktemp /tmp/citus_bench_agg.XXXXXX)
    cat > "$agg_script" <<'ENDSQL'
\set aid random(1, 10000)
SELECT count(*), sum(amount) FROM _bench_dist WHERE account_id = :aid;
ENDSQL

    echo ""
    log_info "Single-shard WRITE (INSERT, single partition key): ${duration}s, ${clients} clients..."
    PGPASSWORD="$PG_PASS" pgbench -h localhost -p "$COORDINATOR_PORT" -U "$PG_USER" -d "$PG_DB" \
        -T "$duration" -c "$clients" -j 4 -n -f "$write_script" 2>&1

    echo ""
    log_info "Single-shard READ (point lookup by partition key): ${duration}s, ${clients} clients..."
    PGPASSWORD="$PG_PASS" pgbench -h localhost -p "$COORDINATOR_PORT" -U "$PG_USER" -d "$PG_DB" \
        -T "$duration" -c "$clients" -j 4 -n -f "$read_script" 2>&1

    echo ""
    log_info "Single-shard AGGREGATION (per-partition SUM): ${duration}s, ${clients} clients..."
    PGPASSWORD="$PG_PASS" pgbench -h localhost -p "$COORDINATOR_PORT" -U "$PG_USER" -d "$PG_DB" \
        -T "$duration" -c "$clients" -j 4 -n -f "$agg_script" 2>&1

    # Cleanup
    echo ""
    log_info "Cleaning up..."
    run_sql "DROP TABLE IF EXISTS _bench_dist CASCADE;" >/dev/null 2>&1
    rm -f "$write_script" "$read_script" "$agg_script"
    log_ok "Benchmark complete"
}

cmd_logs() {
    local target="${1:-coordinator}"
    local lines="${2:-50}"
    case "$target" in
        coordinator|coord)     docker logs --tail "$lines" "$COORDINATOR" ;;
        standby|sb)            docker logs --tail "$lines" "$STANDBY" ;;
        worker1|w1)            docker logs --tail "$lines" "${WORKERS[0]}" ;;
        worker2|w2)            docker logs --tail "$lines" "${WORKERS[1]}" ;;
        valkey)                docker logs --tail "$lines" cit-valkey-master ;;
        setup)                 docker exec "$COORDINATOR" cat /tmp/cluster-setup.log 2>/dev/null || echo "(no setup log)" ;;
        monitor|failover)
            echo "=== Primary coordinator monitor ==="
            docker exec "$COORDINATOR" cat /tmp/failover-monitor.log 2>/dev/null | tail -"$lines" || echo "(no log)"
            echo ""
            echo "=== Standby coordinator monitor ==="
            docker exec "$STANDBY" cat /tmp/failover-monitor.log 2>/dev/null | tail -"$lines" || echo "(no log)"
            ;;
        *)
            log_error "Unknown target: $target"
            echo "Usage: $0 logs [coordinator|standby|worker1|worker2|valkey|setup|monitor] [lines]"
            return 1
            ;;
    esac
}

cmd_topology() {
    log_head "=== Citus Cluster Topology ==="
    echo ""
    log_info "All nodes:"
    run_sql_fmt "SELECT nodeid, nodename, nodeport, noderole, isactive FROM pg_dist_node ORDER BY nodeid;"
    echo ""
    log_info "Active workers:"
    run_sql_fmt "SELECT * FROM citus_get_active_worker_nodes();"
    echo ""
    log_info "Distributed tables:"
    run_sql_fmt "SELECT logicalrelid::text as table_name, partmethod, partkey, repmodel, autoconverted FROM pg_dist_partition ORDER BY logicalrelid::text;"
    echo ""
    log_info "Shard distribution:"
    run_sql_fmt "SELECT table_name::text, nodename, count(*) as shard_count FROM citus_shards GROUP BY table_name, nodename ORDER BY table_name, nodename;"
    echo ""
    log_info "Streaming replication (from primary):"
    PGPASSWORD="$PG_PASS" psql -h localhost -p "$COORDINATOR_PORT" -U "$PG_USER" -d "$PG_DB" \
        -c "SELECT pid, client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn, sync_state, slot_name FROM pg_stat_replication;" 2>/dev/null || log_warn "  Primary unreachable or no replication"
    echo ""
    log_info "Replication slots:"
    PGPASSWORD="$PG_PASS" psql -h localhost -p "$COORDINATOR_PORT" -U "$PG_USER" -d "$PG_DB" \
        -c "SELECT slot_name, slot_type, active, restart_lsn, confirmed_flush_lsn FROM pg_replication_slots;" 2>/dev/null || log_warn "  Primary unreachable"
}

# ---------------------------------------------------------------------------
# HA Commands: failover, promote, reinit
# ---------------------------------------------------------------------------

cmd_failover() {
    log_head "=== Manual Failover: Coordinator ==="
    echo ""
    log_warn "This will:"
    log_warn "  1. Stop the primary coordinator"
    log_warn "  2. Wait for the standby's failover monitor to detect the failure"
    log_warn "  3. Standby will assign VIP and promote itself"
    echo ""

    # Check standby is running and in recovery mode
    STANDBY_STATE=$(docker exec "$STANDBY" pg_isready -h localhost -U "$PG_USER" 2>/dev/null && echo "accepting" || echo "unreachable")
    if [[ "$STANDBY_STATE" != *"accepting"* ]]; then
        log_error "Standby is not running — cannot failover"
        return 1
    fi
    STANDBY_RECOVERY=$(run_sql_on "$STANDBY_PORT" "SELECT pg_is_in_recovery();" || echo "?")
    if [ "$STANDBY_RECOVERY" != "t" ]; then
        log_warn "Standby is already promoted (not in recovery) — nothing to failover"
        return 0
    fi

    read -r -p "Proceed with failover? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        log_info "Aborted"
        return 0
    fi

    log_info "Stopping primary coordinator..."
    docker stop "$COORDINATOR" --timeout 5 2>/dev/null
    log_ok "Primary stopped"

    log_info "Waiting for standby failover monitor to detect failure and promote..."
    log_info "(This takes ~15-20s: 3 checks x 3s + promotion)"

    local attempts=0
    while true; do
        local is_recovery
        is_recovery=$(run_sql_on "$STANDBY_PORT" "SELECT pg_is_in_recovery();" 2>/dev/null || echo "?")
        if [ "$is_recovery" = "f" ]; then
            log_ok "Standby has been promoted to primary!"
            break
        fi
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 30 ]; then
            log_error "Standby did not promote after 30s — check logs"
            return 1
        fi
        sleep 1
    done

    # Check VIP
    local vip_on_standby
    vip_on_standby=$(docker exec "$STANDBY" ip addr show eth0 2>/dev/null | grep "$VIP" || true)
    if [ -n "$vip_on_standby" ]; then
        log_ok "VIP $VIP is now on standby"
    else
        log_warn "VIP not yet on standby — it may take a few more seconds"
    fi

    echo ""
    log_ok "Failover complete. The old primary ($COORDINATOR) is stopped."
    log_info "To reinitialize it as a standby, run: $0 reinit"
}

cmd_promote() {
    log_head "=== Manual Promote: Coordinator Standby ==="
    echo ""
    log_warn "This promotes the standby to primary WITHOUT stopping the primary."
    log_warn "Use 'failover' instead for a coordinated failover."
    log_warn "This is for situations where the primary is already dead."
    echo ""

    # Check standby is running and in recovery mode
    STANDBY_STATE=$(docker exec "$STANDBY" pg_isready -h localhost -U "$PG_USER" 2>/dev/null && echo "accepting" || echo "unreachable")
    if [[ "$STANDBY_STATE" != *"accepting"* ]]; then
        log_error "Standby is not running — cannot promote"
        return 1
    fi
    STANDBY_RECOVERY=$(run_sql_on "$STANDBY_PORT" "SELECT pg_is_in_recovery();" || echo "?")
    if [ "$STANDBY_RECOVERY" != "t" ]; then
        log_warn "Standby is already promoted (not in recovery)"
        return 0
    fi

    read -r -p "Promote standby to primary? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        log_info "Aborted"
        return 0
    fi

    log_info "Promoting standby..."
    docker exec "$STANDBY" bash -c "PGPASSWORD='$PG_PASS' psql -h 127.0.0.1 -U '$PG_USER' -d '$PG_DB' -c 'SELECT pg_promote(true, 60);'" 2>/dev/null
    sleep 3

    local is_recovery
    is_recovery=$(run_sql_on "$STANDBY_PORT" "SELECT pg_is_in_recovery();" 2>/dev/null || echo "?")
    if [ "$is_recovery" = "f" ]; then
        log_ok "Standby promoted to primary"
    else
        log_error "Promotion may have failed — standby still in recovery"
        return 1
    fi

    # Assign VIP to standby if not already there
    local vip_on_standby
    vip_on_standby=$(docker exec "$STANDBY" ip addr show eth0 2>/dev/null | grep "$VIP" || true)
    if [ -z "$vip_on_standby" ]; then
        log_info "Assigning VIP to promoted standby..."
        docker exec "$STANDBY" ip addr add "$VIP/16" dev eth0 2>/dev/null || true
        docker exec "$STANDBY" arping -c 3 -A -I eth0 "$VIP" >/dev/null 2>&1 || true
        log_ok "VIP assigned"
    else
        log_ok "VIP already on standby"
    fi

    # Re-register as Citus coordinator
    log_info "Re-registering as Citus coordinator..."
    docker exec "$STANDBY" bash -c "PGPASSWORD='$PG_PASS' psql -h 127.0.0.1 -U '$PG_USER' -d '$PG_DB' -c \"SELECT citus_set_coordinator_host('coordinator-standby', 5432);\"" 2>/dev/null || true
    log_ok "Promotion complete"
}

cmd_reinit() {
    log_head "=== Reinitialize Old Primary as New Standby ==="
    echo ""
    log_info "This will:"
    log_info "  1. Wipe the old primary's data volume"
    log_info "  2. Start it fresh (pg_basebackup from the new primary)"
    log_info "  3. Configure it as a streaming standby"
    echo ""
    log_warn "NOTE: The standby entrypoint is currently configured to connect to"
    log_warn "'coordinator' as the primary. After a failover, 'coordinator-standby'"
    log_warn "is the new primary. The reinit process needs the old primary to become"
    log_warn "the new standby with the roles reversed."
    echo ""
    log_warn "This is a complex operation that requires:"
    log_warn "  1. Updating COORDINATOR_HOST env var on the old primary"
    log_warn "  2. Wiping and re-basebackup'ing the old primary's data"
    log_warn "  3. Swapping entrypoints (old primary uses standby entrypoint)"
    echo ""
    log_warn "For simplicity, the recommended approach after failover is:"
    log_warn "  1. Stop the cluster:  docker compose down"
    log_warn "  2. Remove ALL data:   docker compose down -v"
    log_warn "  3. Start fresh:       docker compose up -d"
    echo ""
    log_info "The cluster will re-initialize with the original primary/standby roles."
    log_info "Any data written to the promoted standby will be lost."
    echo ""

    read -r -p "Proceed with full cluster reinit? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        log_info "Aborted"
        return 0
    fi

    log_info "Stopping cluster..."
    docker compose down 2>/dev/null
    log_info "Removing data volumes..."
    docker compose down -v 2>/dev/null
    log_info "Starting fresh cluster..."
    docker compose up -d 2>/dev/null

    log_ok "Cluster restarting. Use '$0 status' to check progress."
    log_info "Full initialization takes ~60-90s (pg_basebackup, cluster setup, monitors)."
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

cmd_help() {
    echo ""
    log_head "Citus 14.0 Distributed Cluster Management"
    echo ""
    echo "Usage: $0 <command> [args...]"
    echo ""
    echo "Info commands:"
    echo "  status            Show cluster status (nodes, replication, VIP, monitors)"
    echo "  topology          Show detailed Citus topology (nodes, tables, shards, replication)"
    echo "  logs [target] [n] Show logs (coordinator|standby|worker1|worker2|valkey|setup|monitor)"
    echo ""
    echo "Access commands:"
    echo "  psql [target]     Open psql to coordinator|standby|worker1|worker2"
    echo "  ddl \"SQL\"         Execute DDL on coordinator (auto-propagated to workers)"
    echo ""
    echo "HA commands:"
    echo "  failover          Coordinated failover: stop primary, standby auto-promotes"
    echo "  promote           Manual promote: promote standby (use when primary is already dead)"
    echo "  reinit            Reinitialize cluster (wipe all data, start fresh)"
    echo ""
    echo "Test commands:"
    echo "  test              Run integration tests"
    echo "  bench [dur] [cli] Run pgbench benchmark (default: 10s, 8 clients)"
    echo ""
    echo "  help              Show this help"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    status)     cmd_status ;;
    topology)   cmd_topology ;;
    psql)       cmd_psql "$@" ;;
    ddl)        cmd_ddl "$@" ;;
    test)       cmd_test ;;
    bench)      cmd_bench "$@" ;;
    logs)       cmd_logs "$@" ;;
    failover)   cmd_failover ;;
    promote)    cmd_promote ;;
    reinit)     cmd_reinit ;;
    help|--help|-h) cmd_help ;;
    *)
        log_error "Unknown command: $COMMAND"
        cmd_help
        exit 1
        ;;
esac
