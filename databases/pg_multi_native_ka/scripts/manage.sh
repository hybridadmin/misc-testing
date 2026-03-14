#!/bin/bash
# =============================================================================
# Multi-Master Cluster Management Script (Native PG18 + keepalived variant)
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
VIP="${KEEPALIVED_VIP:-172.33.0.100}"

NODES=("mmn-pg-node1" "mmn-pg-node2" "mmn-pg-node3")
NODE_PORTS=(5841 5842 5843)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run SQL and return output (single value)
run_sql_on() {
    local port="$1"
    local sql="$2"
    PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "$sql" 2>/dev/null
}

# Run SQL that requires write access even if node is fenced (read-only).
# Prefixes with SET default_transaction_read_only = off to override the fence.
# Use for repair/admin operations that must work on fenced nodes.
run_sql_rw() {
    local port="$1"
    shift
    # Each -c flag runs in its own transaction. The SET applies to the session,
    # so subsequent -c flags inherit it. Use -q to suppress the "SET" output.
    PGPASSWORD="$PG_PASS" psql -q -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" \
        -c "SET default_transaction_read_only = off;" "$@" 2>/dev/null
}

# Unfence a node: reset read-only and remove fence state file
unfence_node_via_docker() {
    local container="$1"
    local port="$2"
    run_sql_rw "$port" \
        -c "ALTER SYSTEM RESET default_transaction_read_only;" \
        -c "SELECT pg_reload_conf();" >/dev/null 2>&1
    docker exec "$container" rm -f /tmp/native_fenced 2>/dev/null || true
}

# Execute SQL on ALL nodes (needed because logical replication does NOT replicate DDL)
exec_on_all_nodes() {
    local sql="$1"
    local label="${2:-SQL}"
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        if PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "$sql" 2>/dev/null; then
            log_ok "$node: $label"
        else
            log_error "$node: Failed to execute $label"
            return 1
        fi
    done
}

# Refresh all enabled subscriptions on all nodes (needed after new tables are added)
refresh_all_subscriptions() {
    log_info "Refreshing subscriptions on all nodes..."
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs)
            [ -z "$sub" ] && continue
            if PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION $sub REFRESH PUBLICATION WITH (copy_data = false);" 2>/dev/null; then
                log_ok "$node: refreshed $sub"
            else
                log_error "$node: failed to refresh $sub"
            fi
        done
    done
}

# Disable all enabled subscriptions on all nodes (uses run_sql_rw for fenced nodes)
disable_all_subs() {
    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs)
            [ -z "$sub" ] && continue
            run_sql_rw "$port" -c "ALTER SUBSCRIPTION \"$sub\" DISABLE;"
        done
    done
}

# Re-enable all disabled subscriptions on all nodes (uses run_sql_rw for fenced nodes)
enable_all_subs() {
    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE NOT subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs)
            [ -z "$sub" ] && continue
            run_sql_rw "$port" -c "ALTER SUBSCRIPTION \"$sub\" ENABLE;"
        done
    done
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_status() {
    log_head "=== Multi-Master Cluster (Native PG18 + keepalived) Status ==="
    echo ""

    log_info "PostgreSQL Nodes:"
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        STATE=$(docker exec "$node" pg_isready -h localhost -U "$PG_USER" 2>/dev/null && echo "accepting" || echo "unreachable")
        if [[ "$STATE" == *"accepting"* ]]; then
            PUB_COUNT=$(run_sql_on "$port" "SELECT count(*) FROM pg_publication;" || echo "?")
            SUB_COUNT=$(run_sql_on "$port" "SELECT count(*) FROM pg_subscription;" || echo "?")
            SUB_STATUS=$(run_sql_on "$port" "SELECT string_agg(subname || '=' || CASE WHEN subenabled THEN 'active' ELSE 'disabled' END, ', ') FROM pg_subscription;" || echo "?")
            log_ok "$node: UP  publications=$PUB_COUNT  subscriptions=$SUB_COUNT"
            if [ -n "$SUB_STATUS" ] && [ "$SUB_STATUS" != "?" ] && [ "$SUB_STATUS" != "" ]; then
                echo "             Subscriptions: $SUB_STATUS"
            fi
        else
            log_error "$node: UNREACHABLE"
        fi
    done

    echo ""
    log_info "Replication Lag (per subscription):"
    for node in "${NODES[@]}"; do
        LAG_INFO=$(docker exec "$node" bash -c "PGPASSWORD='$PG_PASS' psql -h localhost -U $PG_USER -d $PG_DB -tAc \"
            SELECT string_agg(
                s.subname || ': ' ||
                COALESCE(
                    CASE WHEN sr.last_msg_send_time IS NOT NULL
                        THEN extract(epoch from now() - sr.last_msg_send_time)::text || 's'
                        ELSE 'no data'
                    END,
                    'unknown'
                ),
                ', '
            )
            FROM pg_subscription s
            LEFT JOIN pg_stat_subscription sr ON s.oid = sr.subid AND sr.relid IS NULL;
        \"" 2>/dev/null || echo "unavailable")
        if [ -n "$LAG_INFO" ] && [ "$LAG_INFO" != "" ] && [ "$LAG_INFO" != "unavailable" ]; then
            echo "    $node: $LAG_INFO"
        fi
    done

    echo ""
    log_info "keepalived VIP:"
    cmd_vip_status

    echo ""
    log_info "Valkey Cluster:"
    docker exec mmn-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning INFO replication 2>/dev/null | grep -E "role:|connected_slaves:" || log_error "Valkey unreachable"
}

cmd_vip_status() {
    log_info "  VIP address: $VIP"
    local vip_holder="none"
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local has_vip
        has_vip=$(docker exec "$node" ip addr show eth0 2>/dev/null | grep "$VIP" || true)
        if [ -n "$has_vip" ]; then
            vip_holder="$node"
            log_ok "  VIP holder: $node"
            break
        fi
    done
    if [ "$vip_holder" = "none" ]; then
        log_warn "  VIP holder: NONE (VIP not assigned — keepalived may still be starting)"
    fi

    echo ""
    log_info "  keepalived status per node:"
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local ka_running
        ka_running=$(docker exec "$node" pgrep -cx keepalived 2>/dev/null)
        if [ "$ka_running" -gt 0 ] 2>/dev/null; then
            ka_running="running (${ka_running} processes)"
        else
            ka_running="not running"
        fi
        local fenced
        fenced=$(docker exec "$node" cat /tmp/native_fenced 2>/dev/null || echo "")
        if [ -n "$fenced" ]; then
            log_warn "  $node: keepalived=$ka_running  FENCED ($fenced)"
        else
            log_ok "  $node: keepalived=$ka_running"
        fi
    done

    # Test VIP connectivity
    echo ""
    if PGPASSWORD="$PG_PASS" psql -h "$VIP" -p 5432 -U "$PG_USER" -d "$PG_DB" -tAc "SELECT 1;" --connect-timeout=3 >/dev/null 2>&1; then
        log_ok "  VIP connectivity: OK (reachable at $VIP:5432)"
    else
        log_warn "  VIP connectivity: UNREACHABLE from host (expected on Docker Desktop — use direct ports 5841-5843)"
    fi
}

cmd_replication_detail() {
    log_head "=== Native Replication Detail ==="
    echo ""
    for node in "${NODES[@]}"; do
        log_info "$node publications:"
        docker exec "$node" bash -c "PGPASSWORD='$PG_PASS' psql -h localhost -U $PG_USER -d $PG_DB -c 'SELECT pubname, puballtables FROM pg_publication;'" 2>/dev/null || echo "  (unreachable)"
        echo ""
        log_info "$node subscriptions:"
        docker exec "$node" bash -c "PGPASSWORD='$PG_PASS' psql -h localhost -U $PG_USER -d $PG_DB -c 'SELECT subname, subenabled, subconninfo FROM pg_subscription;'" 2>/dev/null || echo "  (unreachable)"
        echo ""
    done
}

cmd_ddl() {
    local sql="${1:-}"
    local sql_file="${2:-}"

    if [ -z "$sql" ]; then
        echo "Usage: $0 ddl \"SQL statement\""
        echo "       $0 ddl -f file.sql"
        echo ""
        echo "Executes DDL on ALL nodes (since logical replication does NOT replicate DDL)."
        echo "After execution, all subscriptions are refreshed to pick up new tables."
        echo ""
        echo "Safety: DDL is tested on node1 first. If it fails, no other nodes are touched."
        echo ""
        echo "Examples:"
        echo "  $0 ddl \"CREATE TABLE users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text);\""
        echo "  $0 ddl \"ALTER TABLE users ADD COLUMN email text;\""
        return 1
    fi

    local succeeded_nodes=()
    local failed_nodes=()

    if [ "$sql" = "-f" ]; then
        if [ -z "$sql_file" ] || [ ! -f "$sql_file" ]; then
            log_error "File not found: $sql_file"
            return 1
        fi
        sql=$(cat "$sql_file")
        log_info "Executing DDL from file '$sql_file'"
    fi

    # Step 1: Canary test on node1
    log_info "Testing DDL on ${NODES[0]} first..."
    if PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[0]}" -U "$PG_USER" -d "$PG_DB" -c "$sql" 2>&1; then
        log_ok "${NODES[0]}: DDL succeeded (canary)"
        succeeded_nodes+=("${NODES[0]}")
    else
        log_error "${NODES[0]}: DDL FAILED on canary node — aborting. No other nodes were touched."
        return 1
    fi

    # Step 2: Apply to remaining nodes
    for i in 1 2; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        if PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "$sql" 2>&1; then
            log_ok "$node: DDL succeeded"
            succeeded_nodes+=("$node")
        else
            log_error "$node: DDL FAILED"
            failed_nodes+=("$node")
        fi
    done

    # Step 3: Report results
    if [ ${#failed_nodes[@]} -gt 0 ]; then
        echo ""
        log_error "DDL failed on ${#failed_nodes[@]} node(s): ${failed_nodes[*]}"
        log_warn "DDL succeeded on: ${succeeded_nodes[*]}"
        log_warn "The cluster is now in an INCONSISTENT state for this DDL."
        log_warn "Manually fix the failed node(s) or re-run: $0 ddl \"$sql\""
        log_warn "(Re-running is safe — DDL like CREATE TABLE IF NOT EXISTS is idempotent.)"
    fi

    # Refresh subscriptions if DDL likely created/dropped tables
    if echo "$sql" | grep -qiE '(CREATE|DROP)\s+TABLE'; then
        refresh_all_subscriptions
    fi

    if [ ${#failed_nodes[@]} -eq 0 ]; then
        log_ok "DDL applied successfully to all ${#succeeded_nodes[@]} nodes"
    fi
}

cmd_test_multimaster() {
    log_head "=== Testing Native Multi-Master Replication (keepalived) ==="
    echo ""

    # -----------------------------------------------------------------------
    # TEST 1: DDL on all nodes + subscription refresh
    # -----------------------------------------------------------------------
    log_head "--- Test 1: DDL (manual on all nodes, since native repl doesn't replicate DDL) ---"
    echo ""

    # Drop existing test table on ALL nodes (disable subs first to prevent WAL poisoning)
    log_info "Dropping any existing test table on all nodes..."
    disable_all_subs
    for port in "${NODE_PORTS[@]}"; do
        run_sql_rw "$port" -c "DROP TABLE IF EXISTS mm_repl_test;"
    done
    enable_all_subs

    # Create test table on ALL nodes
    log_info "Creating test table on ALL nodes (DDL doesn't replicate)..."
    exec_on_all_nodes "
        CREATE TABLE mm_repl_test (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            node_name text NOT NULL,
            value text NOT NULL,
            created_at timestamptz DEFAULT now()
        );
    " "created mm_repl_test"

    # Refresh subscriptions so they learn about the new table
    refresh_all_subscriptions
    sleep 2

    log_ok "DDL TEST PASSED (table created on all 3 nodes, subscriptions refreshed)"

    # -----------------------------------------------------------------------
    # TEST 2: DML replication (INSERT/UPDATE/DELETE)
    # -----------------------------------------------------------------------
    echo ""
    log_head "--- Test 2: DML Replication (INSERT/UPDATE/DELETE) ---"
    echo ""

    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        log_info "Writing to $node (port $port)..."
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "
            INSERT INTO mm_repl_test (node_name, value) VALUES ('$node', 'written directly to $node');
        " 2>/dev/null
        log_ok "Written to $node"
    done

    log_info "Waiting for replication to propagate..."
    sleep 3

    echo ""
    log_info "Verifying replication (expecting 3 rows on each node):"
    ALL_PASS=true
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        ROW_COUNT=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM mm_repl_test;" 2>/dev/null || echo "0")
        if [ "$ROW_COUNT" = "3" ]; then
            log_ok "$node (port $port): $ROW_COUNT rows"
        else
            log_error "$node (port $port): $ROW_COUNT rows (expected 3)"
            ALL_PASS=false
        fi
    done

    echo ""
    if [ "$ALL_PASS" = true ]; then
        log_ok "INSERT replication PASSED"
    else
        log_warn "Replication may need more time. Retrying in 10s..."
        sleep 10
        for i in "${!NODES[@]}"; do
            local node="${NODES[$i]}"
            local port="${NODE_PORTS[$i]}"
            ROW_COUNT=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM mm_repl_test;" 2>/dev/null || echo "0")
            if [ "$ROW_COUNT" = "3" ]; then
                log_ok "$node (port $port): $ROW_COUNT rows (replicated after retry)"
            else
                log_error "$node (port $port): $ROW_COUNT rows (STILL MISSING — check logs)"
            fi
        done
    fi

    # Test UPDATE
    echo ""
    log_info "Testing UPDATE replication (updating node1's row from node2)..."
    PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[1]}" -U "$PG_USER" -d "$PG_DB" -c "
        UPDATE mm_repl_test SET value = 'UPDATED by node2' WHERE node_name = '${NODES[0]}';
    " 2>/dev/null
    sleep 2
    UPDATED=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[2]}" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT value FROM mm_repl_test WHERE node_name = '${NODES[0]}';" 2>/dev/null)
    if [ "$UPDATED" = "UPDATED by node2" ]; then
        log_ok "UPDATE replication verified (node2 -> node3)"
    else
        log_error "UPDATE replication failed (node3 sees: '$UPDATED')"
    fi

    # Test DELETE
    log_info "Testing DELETE replication (deleting node3's row from node1)..."
    PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[0]}" -U "$PG_USER" -d "$PG_DB" -c "
        DELETE FROM mm_repl_test WHERE node_name = '${NODES[2]}';
    " 2>/dev/null
    sleep 2
    REMAINING=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[1]}" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM mm_repl_test;" 2>/dev/null)
    if [ "$REMAINING" = "2" ]; then
        log_ok "DELETE replication verified (node1 -> node2)"
    else
        log_error "DELETE replication failed (node2 has $REMAINING rows, expected 2)"
    fi

    # -----------------------------------------------------------------------
    # TEST 3: keepalived VIP connectivity
    # -----------------------------------------------------------------------
    echo ""
    log_head "--- Test 3: keepalived VIP Connectivity ---"
    echo ""
    cmd_vip_status

    # Show final state via direct node access
    echo ""
    log_info "Final data via node1:"
    PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[0]}" -U "$PG_USER" -d "$PG_DB" -c "SELECT node_name, value, created_at FROM mm_repl_test ORDER BY node_name;" 2>/dev/null

    # -----------------------------------------------------------------------
    # Cleanup: disable subs -> drop table on all -> re-enable subs
    # -----------------------------------------------------------------------
    echo ""
    log_info "Cleaning up test table (disabling subs -> drop -> re-enable)..."

    disable_all_subs

    for port in "${NODE_PORTS[@]}"; do
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "DROP TABLE IF EXISTS mm_repl_test;" 2>/dev/null
    done

    enable_all_subs

    log_ok "Test table dropped and subscriptions re-enabled"
}

cmd_bench() {
    local db="$PG_DB"
    local user="$PG_USER"
    local pass="$PG_PASS"
    local scale="${1:-10}"

    log_head "=== Multi-Master pgbench Benchmark (Native + keepalived) ==="
    echo ""
    log_info "Strategy: Initialize pgbench independently on each node."
    log_info "Subscriptions disabled during benchmark. Maintenance mode prevents fencing."
    echo ""

    # Step 1: Enter maintenance mode (prevents keepalived-check.sh from fencing nodes
    # when subscriptions are intentionally disabled for the benchmark)
    log_info "Entering maintenance mode on all nodes..."
    for node in "${NODES[@]}"; do
        docker exec "$node" touch /tmp/native_maintenance
    done

    # Step 2: Disable all subscriptions
    log_info "Disabling all subscriptions for benchmark..."
    disable_all_subs

    # Step 3: Drop leftover pgbench tables
    for node in "${NODES[@]}"; do
        docker exec "$node" bash -c "PGPASSWORD='$pass' psql -h 127.0.0.1 -U $user -d $db -c '
            DROP TABLE IF EXISTS pgbench_accounts, pgbench_branches, pgbench_history, pgbench_tellers CASCADE;
        '" 2>/dev/null
    done

    # Step 4: Initialize pgbench independently on EACH node
    for node in "${NODES[@]}"; do
        log_info "Initializing pgbench (scale=$scale) on $node..."
        docker exec "$node" bash -c \
            "PGPASSWORD='$pass' pgbench -i -s $scale -h 127.0.0.1 -U $user $db" 2>&1
        log_ok "$node: pgbench initialized"
    done

    # Verify row counts
    echo ""
    log_info "Verifying pgbench_accounts row counts:"
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local count
        count=$(docker exec "$node" bash -c "PGPASSWORD='$pass' psql -h 127.0.0.1 -U $user -d $db -tAc 'SELECT count(*) FROM pgbench_accounts;'" 2>/dev/null || echo "?")
        log_info "  $node: $count rows"
    done

    # Step 5: Write benchmark
    echo ""
    log_info "Running pgbench WRITE test (30s, 10 clients) on each node directly..."
    for node in "${NODES[@]}"; do
        log_info "  WRITE benchmark on $node:"
        docker exec "$node" bash -c \
            "PGPASSWORD='$pass' pgbench -T 30 -c 10 -j 4 -h 127.0.0.1 -U $user $db" 2>&1
        echo ""
    done

    # Step 6: Read benchmark
    echo ""
    log_info "Running pgbench READ test (30s, 20 clients, select-only) on each node directly..."
    for node in "${NODES[@]}"; do
        log_info "  READ benchmark on $node:"
        docker exec "$node" bash -c \
            "PGPASSWORD='$pass' pgbench -T 30 -c 20 -j 4 -S -h 127.0.0.1 -U $user $db" 2>&1
        echo ""
    done

    # Step 7: Cleanup — drop tables, then drop+recreate subscriptions from current LSN
    # Cannot simply re-enable subscriptions because WAL accumulated while they were
    # disabled includes CREATE TABLE, INSERT, and DROP TABLE for pgbench tables.
    # Replaying that WAL would crash the subscription workers.
    echo ""
    log_info "Cleaning up pgbench tables..."

    for node in "${NODES[@]}"; do
        docker exec "$node" bash -c "PGPASSWORD='$pass' psql -h 127.0.0.1 -U $user -d $db -c '
            DROP TABLE IF EXISTS pgbench_accounts, pgbench_branches, pgbench_history, pgbench_tellers CASCADE;
        '" 2>/dev/null
    done

    # Drop and recreate all subscriptions from current LSN
    log_info "Recreating subscriptions from current LSN (skipping accumulated bench WAL)..."
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$pass" psql -h localhost -p "$port" -U "$user" -d "$db" -tAc \
            "SELECT subname || '|' || subconninfo || '|' || array_to_string(subpublications, ', ') FROM pg_subscription;" 2>/dev/null | while IFS='|' read -r sub conninfo pubname; do
            sub=$(echo "$sub" | xargs)
            conninfo=$(echo "$conninfo" | xargs)
            pubname=$(echo "$pubname" | xargs)
            [ -z "$sub" ] && continue
            run_sql_rw "$port" -c "DROP SUBSCRIPTION \"$sub\";" 2>&1
            run_sql_rw "$port" -c "CREATE SUBSCRIPTION \"$sub\" CONNECTION '$conninfo' PUBLICATION $pubname WITH (copy_data = false, origin = none, streaming = parallel, disable_on_error = true);" 2>&1
            log_ok "  $node: recreated $sub"
        done
    done

    # Step 8: Exit maintenance mode
    log_info "Exiting maintenance mode..."
    for node in "${NODES[@]}"; do
        docker exec "$node" rm -f /tmp/native_maintenance
    done

    log_ok "pgbench tables dropped and subscriptions recreated"
}

cmd_conflicts() {
    log_head "=== Conflict & Error Report ==="
    echo ""

    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"

        log_info "$node:"

        # Disabled subscriptions
        local disabled
        disabled=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "
            SELECT string_agg(subname, ', ') FROM pg_subscription WHERE NOT subenabled;
        " 2>/dev/null)
        if [ -n "$disabled" ] && [ "$disabled" != "" ]; then
            log_error "  DISABLED subscriptions: $disabled"
        else
            log_ok "  All subscriptions enabled"
        fi

        # Conflict stats from pg_stat_subscription_stats
        local stats
        stats=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "
            SELECT
                s.subname AS subscription,
                COALESCE(ss.confl_insert_exists, 0)           AS insert_exists,
                COALESCE(ss.confl_update_origin_differs, 0)   AS update_origin_diff,
                COALESCE(ss.confl_update_exists, 0)           AS update_exists,
                COALESCE(ss.confl_update_missing, 0)          AS update_missing,
                COALESCE(ss.confl_delete_origin_differs, 0)   AS delete_origin_diff,
                COALESCE(ss.confl_delete_missing, 0)          AS delete_missing,
                COALESCE(ss.apply_error_count, 0)             AS apply_errors,
                COALESCE(ss.sync_error_count, 0)              AS sync_errors
            FROM pg_subscription s
            LEFT JOIN pg_stat_subscription_stats ss ON s.oid = ss.subid
            ORDER BY s.subname;
        " 2>/dev/null)
        if [ -n "$stats" ]; then
            echo "$stats"
        else
            log_warn "  Could not query conflict stats"
        fi

        # Subscription worker status
        local worker_status
        worker_status=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "
            SELECT
                s.subname,
                CASE WHEN sr.pid IS NOT NULL THEN 'running' ELSE 'stopped' END AS worker,
                COALESCE(sr.received_lsn::text, 'none') AS received_lsn,
                CASE
                    WHEN sr.last_msg_send_time IS NULL THEN 'never'
                    ELSE extract(epoch FROM now() - sr.last_msg_send_time)::int::text || 's ago'
                END AS last_msg
            FROM pg_subscription s
            LEFT JOIN pg_stat_subscription sr ON s.oid = sr.subid AND sr.relid IS NULL
            ORDER BY s.subname;
        " 2>/dev/null)
        if [ -n "$worker_status" ]; then
            echo "$worker_status"
        fi
        echo ""
    done
}

cmd_repair() {
    local action="${1:-}"
    local target="${2:-}"

    if [ -z "$action" ]; then
        echo "Usage: $0 repair <action> [target]"
        echo ""
        echo "Actions:"
        echo "  enable              Re-enable all disabled subscriptions on all nodes"
        echo "  enable <node>       Re-enable disabled subscriptions on specific node (mmn-pg-node1, etc.)"
        echo "  skip <node>         Skip the current errored transaction on a node's subscriptions"
        echo "  resync <node>       Drop and recreate all subscriptions on a node (nuclear option)"
        echo "  reset-stats         Reset conflict stats counters on all nodes"
        echo ""
        echo "Examples:"
        echo "  $0 repair enable                    # Re-enable all disabled subs on all nodes"
        echo "  $0 repair enable mmn-pg-node1       # Re-enable disabled subs on node1 only"
        echo "  $0 repair skip mmn-pg-node2         # Skip stuck transaction on node2"
        echo "  $0 repair resync mmn-pg-node3       # Full resync of node3's subscriptions"
        echo "  $0 repair reset-stats               # Zero out conflict counters"
        return 1
    fi

    case "$action" in
        enable)
            if [ -n "$target" ]; then
                local port
                case "$target" in
                    mmn-pg-node1) port=5841 ;;
                    mmn-pg-node2) port=5842 ;;
                    mmn-pg-node3) port=5843 ;;
                    *) log_error "Unknown node: $target (use mmn-pg-node1, mmn-pg-node2, mmn-pg-node3)"; return 1 ;;
                esac
                log_info "Re-enabling disabled subscriptions on $target..."
                PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE NOT subenabled;" 2>/dev/null | while IFS= read -r sub; do
                    sub=$(echo "$sub" | xargs)
                    [ -z "$sub" ] && continue
                    if run_sql_rw "$port" -c "ALTER SUBSCRIPTION $sub ENABLE;"; then
                        log_ok "$target: re-enabled $sub"
                    else
                        log_error "$target: failed to re-enable $sub"
                    fi
                done
                # Unfence the node now that subscriptions are re-enabled
                unfence_node_via_docker "$target" "$port"
            else
                log_info "Re-enabling all disabled subscriptions across all nodes..."
                for i in "${!NODES[@]}"; do
                    local node="${NODES[$i]}"
                    local port="${NODE_PORTS[$i]}"
                    PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE NOT subenabled;" 2>/dev/null | while IFS= read -r sub; do
                        sub=$(echo "$sub" | xargs)
                        [ -z "$sub" ] && continue
                        if run_sql_rw "$port" -c "ALTER SUBSCRIPTION $sub ENABLE;"; then
                            log_ok "$node: re-enabled $sub"
                        else
                            log_error "$node: failed to re-enable $sub"
                        fi
                    done
                    # Unfence each node now that subscriptions are re-enabled
                    unfence_node_via_docker "$node" "$port"
                done
            fi
            log_ok "Done. Run '$0 conflicts' to verify."
            ;;

        skip)
            if [ -z "$target" ]; then
                log_error "Usage: $0 repair skip <node>"
                return 1
            fi
            local port
            case "$target" in
                mmn-pg-node1) port=5841 ;;
                mmn-pg-node2) port=5842 ;;
                mmn-pg-node3) port=5843 ;;
                *) log_error "Unknown node: $target"; return 1 ;;
            esac
            log_info "Skipping errored transactions on $target's disabled subscriptions..."
            PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE NOT subenabled;" 2>/dev/null | while IFS= read -r sub; do
                sub=$(echo "$sub" | xargs)
                [ -z "$sub" ] && continue
                log_info "$target: skipping transaction on $sub and re-enabling..."
                run_sql_rw "$port" -c "ALTER SUBSCRIPTION $sub SKIP (lsn = NONE);"
                if run_sql_rw "$port" -c "ALTER SUBSCRIPTION $sub ENABLE;"; then
                    log_ok "$target: skipped and re-enabled $sub"
                else
                    log_error "$target: failed on $sub"
                fi
            done
            # Unfence the node now that subscriptions are re-enabled
            unfence_node_via_docker "$target" "$port"
            log_warn "WARNING: Skipping transactions means some data may be missing on this node."
            log_warn "Run '$0 conflicts' to verify replication is healthy."
            ;;

        resync)
            if [ -z "$target" ]; then
                log_error "Usage: $0 repair resync <node>"
                return 1
            fi
            local port node_name
            case "$target" in
                mmn-pg-node1) port=5841; node_name="pg_node1" ;;
                mmn-pg-node2) port=5842; node_name="pg_node2" ;;
                mmn-pg-node3) port=5843; node_name="pg_node3" ;;
                *) log_error "Unknown node: $target"; return 1 ;;
            esac

            log_warn "This will DROP and RECREATE all subscriptions on $target."
            log_warn "Data will be re-synced from peer nodes (copy_data=true)."
            log_info "Press Ctrl+C to abort, or wait 5 seconds..."
            sleep 5

            local all_nodes=(pg_node1 pg_node2 pg_node3)
            local repl_pass="${POSTGRES_REPL_PASSWORD:-changeme_repl_2025}"
            local repl_user="${POSTGRES_REPL_USER:-replicator}"

            # Step 1: Drop existing subscriptions
            log_info "Dropping existing subscriptions on $target..."
            local subs_to_drop
            subs_to_drop=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription;" 2>/dev/null)
            while IFS= read -r sub; do
                sub=$(echo "$sub" | xargs)
                [ -z "$sub" ] && continue
                run_sql_rw "$port" -c "ALTER SUBSCRIPTION \"$sub\" DISABLE;"
                run_sql_rw "$port" -c "ALTER SUBSCRIPTION \"$sub\" SET (slot_name = NONE);"
                run_sql_rw "$port" -c "DROP SUBSCRIPTION \"$sub\";"
                log_ok "$target: dropped $sub"
            done <<< "$subs_to_drop"

            # Step 2: Drop orphaned replication slots on peer publishers
            log_info "Cleaning up orphaned replication slots on peer nodes..."
            for peer in "${all_nodes[@]}"; do
                [ "$peer" = "$node_name" ] && continue
                local peer_port
                case "$peer" in
                    pg_node1) peer_port=5841 ;;
                    pg_node2) peer_port=5842 ;;
                    pg_node3) peer_port=5843 ;;
                esac
                local expected_slot="sub_${peer}_to_${node_name}"
                local slot_exists
                slot_exists=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "$peer_port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM pg_replication_slots WHERE slot_name = '$expected_slot';" 2>/dev/null)
                if [ "$slot_exists" = "1" ]; then
                    PGPASSWORD="$PG_PASS" psql -h localhost -p "$peer_port" -U "$PG_USER" -d "$PG_DB" -c "SELECT pg_drop_replication_slot('$expected_slot');" 2>/dev/null
                    log_ok "Dropped orphaned slot '$expected_slot' on $peer"
                fi
            done

            # Step 3: Recreate subscriptions to each peer
            for peer in "${all_nodes[@]}"; do
                [ "$peer" = "$node_name" ] && continue
                local peer_host="${peer//_/-}"  # pg_node1 -> pg-node1
                local sub_name="sub_${peer}_to_${node_name}"
                local pub_name="pub_${peer}"
                local conninfo="host=${peer_host} port=5432 dbname=${PG_DB} user=${PG_USER} password=${PG_PASS}"

                log_info "$target: creating subscription $sub_name -> $pub_name on $peer_host..."
                if run_sql_rw "$port" -c "CREATE SUBSCRIPTION \"$sub_name\" CONNECTION '${conninfo}' PUBLICATION $pub_name WITH (copy_data = true, origin = none, disable_on_error = true, streaming = parallel);"; then
                    log_ok "$target: created $sub_name (copy_data=true — will sync data)"
                else
                    log_error "$target: failed to create $sub_name"
                fi
                sleep 2
            done

            # Unfence the node now that subscriptions are recreated
            unfence_node_via_docker "$target" "$port"
            log_ok "Resync initiated on $target. Initial data copy is running in background."
            log_info "Monitor progress with: $0 conflicts"
            ;;

        reset-stats)
            log_info "Resetting conflict stats on all nodes..."
            for i in "${!NODES[@]}"; do
                local node="${NODES[$i]}"
                local port="${NODE_PORTS[$i]}"
                PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "
                    SELECT pg_stat_reset_subscription_stats(subid)
                    FROM pg_stat_subscription_stats;
                " 2>/dev/null
                log_ok "$node: stats reset"
            done
            log_ok "All conflict counters reset to zero"
            ;;

        *)
            log_error "Unknown action: $action"
            log_info "Run '$0 repair' for usage."
            return 1
            ;;
    esac
}

cmd_psql() {
    local port="${1:-5841}"
    shift 2>/dev/null || true
    log_info "Connecting to PostgreSQL via localhost:$port..."
    PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" "$@"
}

cmd_valkey_cli() {
    docker exec -it mmn-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning "$@"
}

cmd_logs() {
    local service="${1:-}"
    if [ -n "$service" ]; then
        docker compose -f "$PROJECT_DIR/docker-compose.yml" logs -f "$service"
    else
        docker compose -f "$PROJECT_DIR/docker-compose.yml" logs -f
    fi
}

cmd_help() {
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  status               Show cluster, replication & keepalived VIP status"
    echo "  vip                  Show keepalived VIP status (which node holds VIP)"
    echo "  replication          Show detailed native replication info"
    echo "  test                 Full test: DDL + DML replication + VIP check"
    echo "  ddl \"SQL\"            Execute DDL on ALL nodes (canary test on node1 first)"
    echo "  ddl -f file.sql      Execute DDL from file on ALL nodes"
    echo "  conflicts            Show conflict stats, disabled subs, apply errors"
    echo "  repair enable        Re-enable all disabled subscriptions"
    echo "  repair skip <node>   Skip errored transaction and re-enable"
    echo "  repair resync <node> Drop + recreate subscriptions (full resync)"
    echo "  repair reset-stats   Reset conflict counters to zero"
    echo "  psql [port]          Connect via psql (default: 5841)"
    echo "  valkey-cli           Connect to Valkey CLI"
    echo "  logs [service]       Tail Docker logs"
    echo "  bench [scale]        Run pgbench benchmark (default scale=10)"
    echo "  help                 Show this help"
    echo ""
    echo "KEY FEATURE: keepalived floating VIP replaces HAProxy."
    echo "  Only ONE node holds the VIP ($VIP) at a time."
    echo "  Failover is automatic (~1-3s) when the VIP holder fails."
    echo ""
    echo "Direct ports: node1=5841, node2=5842, node3=5843"
    echo "VIP:          $VIP:5432 (reachable within Docker network)"
    echo "Container prefix: mmn-"
    echo ""
    echo "IMPORTANT: Native logical replication does NOT replicate DDL."
    echo "Use '$0 ddl' to execute DDL on all nodes simultaneously."
}

case "${1:-help}" in
    status)       cmd_status ;;
    vip)          cmd_vip_status ;;
    replication)  cmd_replication_detail ;;
    test)         cmd_test_multimaster ;;
    ddl)          cmd_ddl "${2:-}" "${3:-}" ;;
    conflicts)    cmd_conflicts ;;
    repair)       cmd_repair "${2:-}" "${3:-}" ;;
    psql)         cmd_psql "${2:-5841}" "${@:3}" ;;
    valkey-cli)   shift; cmd_valkey_cli "$@" ;;
    logs)         cmd_logs "${2:-}" ;;
    bench)        cmd_bench "${2:-10}" ;;
    help|*)       cmd_help ;;
esac
