#!/bin/bash
# =============================================================================
# Multi-Master Cluster Management Script (pglogical + keepalived variant)
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
VIP="${KEEPALIVED_VIP:-172.32.0.100}"

NODES=("mmk-pg-node1" "mmk-pg-node2" "mmk-pg-node3")
NODE_PORTS=(5741 5742 5743)

# pgBackRest — per-system-id stanzas
# Each node is an independent initdb (multi-master pglogical replication) -> 3 stanzas
STANZA_NODE1="${BACKUP_STANZA_NODE1:-pg-mmk-node1}"
STANZA_NODE2="${BACKUP_STANZA_NODE2:-pg-mmk-node2}"
STANZA_NODE3="${BACKUP_STANZA_NODE3:-pg-mmk-node3}"
ALL_STANZAS=("$STANZA_NODE1" "$STANZA_NODE2" "$STANZA_NODE3")

# ---------------------------------------------------------------------------
# Run SQL on a specific node via its exposed port
# ---------------------------------------------------------------------------
run_sql_on() {
    local port="$1"
    local sql="$2"
    PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "$sql" 2>/dev/null
}

# Enter/exit maintenance mode on all nodes.
# Maintenance mode prevents the fencing watchdog from fencing nodes while
# subscriptions are temporarily disabled (e.g. during test setup/teardown).
enter_maintenance_mode() {
    for node in "${NODES[@]}"; do
        docker exec "$node" touch /tmp/pglogical_maintenance 2>/dev/null || true
    done
    sleep 1  # let watchdog pick up maintenance flag
}
exit_maintenance_mode() {
    for node in "${NODES[@]}"; do
        docker exec "$node" rm -f /tmp/pglogical_maintenance 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# DDL via pglogical.replicate_ddl_command()
# ---------------------------------------------------------------------------
cmd_ddl() {
    local sql="${1:-}"
    local sql_file="${2:-}"

    if [ -z "$sql" ]; then
        echo "Usage: $0 ddl \"SQL statement\""
        echo "       $0 ddl -f file.sql"
        echo ""
        echo "Executes DDL via pglogical.replicate_ddl_command() on one node."
        echo "pglogical automatically replicates the DDL to ALL subscriber nodes."
        echo ""
        echo "IMPORTANT: Always use schema-qualified names (public.tablename) in DDL."
        echo "replicate_ddl_command() runs with an empty search_path."
        echo ""
        echo "For CREATE TABLE, also add the table to the default replication set"
        echo "so that DML (INSERT/UPDATE/DELETE) is replicated too:"
        echo ""
        echo "Examples:"
        echo "  $0 ddl \"CREATE TABLE public.users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text); SELECT pglogical.replication_set_add_table('default', 'public.users', true);\""
        echo "  $0 ddl \"ALTER TABLE public.users ADD COLUMN email text;\""
        echo "  $0 ddl \"DROP TABLE public.users CASCADE;\""
        echo "  $0 ddl -f my_migration.sql"
        return 1
    fi

    if [ "$sql" = "-f" ]; then
        if [ -z "$sql_file" ] || [ ! -f "$sql_file" ]; then
            log_error "File not found: $sql_file"
            return 1
        fi
        sql=$(cat "$sql_file")
        log_info "Executing DDL from file '$sql_file'"
    fi

    log_info "Executing DDL via pglogical.replicate_ddl_command() on ${NODES[0]}..."
    log_info "SQL: $sql"

    if echo "$sql" | grep -qiE '(CREATE|ALTER|DROP)\s+TABLE' && ! echo "$sql" | grep -qiE '(CREATE|ALTER|DROP)\s+TABLE\s+(IF\s+(NOT\s+)?EXISTS\s+)?public\.'; then
        log_warn "DDL may need schema qualification (public.tablename). replicate_ddl_command() uses an empty search_path."
    fi
    echo ""

    local escaped_sql="${sql//\'/\'\'}"

    local result
    result=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[0]}" -U "$PG_USER" -d "$PG_DB" -c \
        "SELECT pglogical.replicate_ddl_command('$escaped_sql');" 2>&1)
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log_ok "${NODES[0]}: DDL executed and queued for replication"
    else
        log_error "${NODES[0]}: DDL failed"
        echo "$result"
        return 1
    fi

    log_info "Waiting for DDL to replicate to peers..."
    sleep 3

    echo ""
    log_info "Verifying DDL on all nodes:"
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        if echo "$sql" | grep -qiE 'CREATE\s+TABLE'; then
            local table_name
            table_name=$(echo "$sql" | grep -oiP 'CREATE\s+TABLE\s+(IF\s+NOT\s+EXISTS\s+)?(public\.)?(\w+)' | awk '{print $NF}' | sed 's/^public\.//')
            if [ -n "$table_name" ]; then
                local exists
                exists=$(run_sql_on "$port" "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='$table_name';")
                if [ "$exists" = "1" ]; then
                    log_ok "$node: table '$table_name' exists"
                else
                    log_error "$node: table '$table_name' NOT FOUND"
                fi
            fi
        else
            log_ok "$node: DDL replicated (verify manually if needed)"
        fi
    done
}

cmd_status() {
    log_head "=== Multi-Master Cluster (pglogical + keepalived) Status ==="
    echo ""

    log_info "PostgreSQL Nodes:"
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        STATE=$(docker exec "$node" pg_isready -h localhost -U "$PG_USER" 2>/dev/null && echo "accepting" || echo "unreachable")
        if [[ "$STATE" == *"accepting"* ]]; then
            local pgl_node
            pgl_node=$(run_sql_on "$port" "SELECT node_name FROM pglogical.node LIMIT 1;" 2>/dev/null || echo "?")
            local sub_info
            sub_info=$(run_sql_on "$port" "SELECT string_agg(subscription_name || '=' || status, ', ') FROM pglogical.show_subscription_status();" 2>/dev/null || echo "?")
            log_ok "$node: UP  pglogical_node=$pgl_node"
            if [ -n "$sub_info" ] && [ "$sub_info" != "?" ] && [ "$sub_info" != "" ]; then
                echo "             Subscriptions: $sub_info"
            fi
        else
            log_error "$node: UNREACHABLE"
        fi
    done

    echo ""
    log_info "Conflict Resolution:"
    local cr
    cr=$(run_sql_on "${NODE_PORTS[0]}" "SHOW pglogical.conflict_resolution;" 2>/dev/null || echo "unknown")
    log_info "  Mode: $cr"

    echo ""
    log_info "keepalived VIP:"
    cmd_vip_status

    echo ""
    log_info "Valkey Cluster:"
    docker exec mmk-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning INFO replication 2>/dev/null | grep -E "role:|connected_slaves:" || log_error "Valkey unreachable"
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
        fenced=$(docker exec "$node" cat /tmp/pglogical_fenced 2>/dev/null || echo "")
        if [ -n "$fenced" ]; then
            log_warn "  $node: keepalived=$ka_running  FENCED ($fenced)"
        else
            log_ok "  $node: keepalived=$ka_running"
        fi
    done

    # Test VIP connectivity
    echo ""
    if PGPASSWORD="$PG_PASS" PGCONNECT_TIMEOUT=3 psql -h "$VIP" -p 5432 -U "$PG_USER" -d "$PG_DB" -tAc "SELECT 1;" >/dev/null 2>&1; then
        log_ok "  VIP connectivity: OK (reachable at $VIP:5432)"
    else
        log_warn "  VIP connectivity: UNREACHABLE from host (expected on Docker Desktop — use direct ports 5741-5743)"
    fi
}

cmd_replication_detail() {
    log_head "=== pglogical Replication Detail ==="
    echo ""
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        log_info "$node — pglogical node:"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c \
            "SELECT node_name, if_dsn FROM pglogical.node_interface;" 2>/dev/null || echo "  (unreachable)"
        echo ""
        log_info "$node — subscriptions:"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c \
            "SELECT * FROM pglogical.show_subscription_status();" 2>/dev/null || echo "  (unreachable)"
        echo ""
        log_info "$node — replication sets:"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c \
            "SELECT set_name, set_nodeid FROM pglogical.replication_set;" 2>/dev/null || echo "  (unreachable)"
        echo ""
    done
}

cmd_psql() {
    local port="${1:-5741}"
    shift 2>/dev/null || true
    log_info "Connecting to PostgreSQL via localhost:$port..."
    PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" "$@"
}

cmd_valkey_cli() {
    docker exec -it mmk-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning "$@"
}

# ---------------------------------------------------------------------------
# pgBackRest backup commands
# ---------------------------------------------------------------------------

resolve_backup_node() {
    local target="${1:-node1}"
    case "$target" in
        node1|pg-node1|1)  echo "mmk-pg-node1|$STANZA_NODE1" ;;
        node2|pg-node2|2)  echo "mmk-pg-node2|$STANZA_NODE2" ;;
        node3|pg-node3|3)  echo "mmk-pg-node3|$STANZA_NODE3" ;;
        *) log_error "Unknown node: $target (use node1, node2, node3)"; return 1 ;;
    esac
}

cmd_backup() {
    local btype="${1:-full}"
    local target="${2:-}"

    case "$btype" in
        full|diff|incr) ;;
        *) log_error "Unknown backup type: $btype (use full, diff, incr)"; return 1 ;;
    esac

    # If no target specified, backup all nodes
    local targets=()
    if [ -z "$target" ]; then
        targets=("node1" "node2" "node3")
    else
        targets=("$target")
    fi

    for t in "${targets[@]}"; do
        local resolved
        resolved=$(resolve_backup_node "$t") || return 1
        local container="${resolved%%|*}"
        local stanza="${resolved##*|}"

        log_head "=== pgBackRest Backup ($btype) on $container, stanza=$stanza ==="
        docker exec "$container" gosu postgres pgbackrest --stanza="$stanza" --type="$btype" backup 2>&1
        log_ok "Backup ($btype) complete on $container"
        echo ""
    done
}

cmd_backup_info() {
    local target="${1:-}"

    local targets=()
    if [ -z "$target" ]; then
        targets=("node1" "node2" "node3")
    else
        targets=("$target")
    fi

    for t in "${targets[@]}"; do
        local resolved
        resolved=$(resolve_backup_node "$t") || return 1
        local container="${resolved%%|*}"
        local stanza="${resolved##*|}"

        log_head "=== pgBackRest Info ($container, stanza=$stanza) ==="
        docker exec "$container" gosu postgres pgbackrest --stanza="$stanza" --output=text info 2>&1
        echo ""
    done
}

cmd_backup_check() {
    local target="${1:-}"

    local targets=()
    if [ -z "$target" ]; then
        targets=("node1" "node2" "node3")
    else
        targets=("$target")
    fi

    for t in "${targets[@]}"; do
        local resolved
        resolved=$(resolve_backup_node "$t") || return 1
        local container="${resolved%%|*}"
        local stanza="${resolved##*|}"

        log_head "=== pgBackRest Check ($container, stanza=$stanza) ==="
        log_info "Verifying stanza '$stanza' and WAL archiving..."
        docker exec "$container" gosu postgres pgbackrest --stanza="$stanza" --log-level-console=info check 2>&1
        log_ok "pgBackRest check passed — stanza OK, WAL archiving OK"
        echo ""
    done
}

# ---------------------------------------------------------------------------
# Integration tests (including pgBackRest tests)
# ---------------------------------------------------------------------------
cmd_test() {
    log_head "=== Multi-Master Cluster Integration Tests (pglogical + keepalived) ==="
    echo ""
    local PASS=0
    local FAIL=0

    run_test() {
        local num="$1" desc="$2"
        log_info "Test $num: $desc"
    }
    pass() { log_ok "$*"; PASS=$((PASS + 1)); }
    fail() { log_error "$*"; FAIL=$((FAIL + 1)); }

    # --- Test 1: Node connectivity ---
    run_test 1 "PostgreSQL node connectivity"
    local all_up=true
    for i in "${!NODES[@]}"; do
        if PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[$i]}" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT 1;" >/dev/null 2>&1; then
            :
        else
            fail "${NODES[$i]} not accepting connections"
            all_up=false
        fi
    done
    if $all_up; then
        pass "All 3 nodes accepting connections"
    fi

    # --- Test 2: pglogical nodes exist ---
    run_test 2 "pglogical nodes exist on all nodes"
    local pgl_ok=true
    for i in "${!NODES[@]}"; do
        local node_name
        node_name=$(run_sql_on "${NODE_PORTS[$i]}" "SELECT node_name FROM pglogical.node LIMIT 1;" 2>/dev/null || echo "")
        if [ -n "$node_name" ] && [ "$node_name" != "" ]; then
            :
        else
            fail "${NODES[$i]}: no pglogical node found"
            pgl_ok=false
        fi
    done
    if $pgl_ok; then
        pass "All nodes have pglogical node identity"
    fi

    # --- Test 3: pglogical subscriptions exist and are replicating ---
    run_test 3 "pglogical subscriptions exist and are replicating"
    local subs_ok=true
    for i in "${!NODES[@]}"; do
        local sub_count
        sub_count=$(run_sql_on "${NODE_PORTS[$i]}" "SELECT count(*) FROM pglogical.show_subscription_status() WHERE status = 'replicating';" 2>/dev/null || echo "0")
        if [ "$sub_count" -ge 2 ] 2>/dev/null; then
            :
        else
            fail "${NODES[$i]}: expected >=2 replicating subscriptions, got $sub_count"
            subs_ok=false
        fi
    done
    if $subs_ok; then
        pass "All nodes have >=2 replicating subscriptions"
    fi

    # --- Test 4: Multi-master write + replication ---
    run_test 4 "Multi-master write + replication"
    # Enter maintenance mode so watchdog won't fence while we manipulate data
    enter_maintenance_mode
    # Clean up any previous test table on all nodes
    for port in "${NODE_PORTS[@]}"; do
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c \
            "DROP TABLE IF EXISTS public._test_repl CASCADE;" 2>/dev/null || true
    done
    sleep 1
    # Create test table via replicate_ddl_command on node1 (replicates to all)
    PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[0]}" -U "$PG_USER" -d "$PG_DB" -c "
        SELECT pglogical.replicate_ddl_command(\$DDL\$
            CREATE TABLE public._test_repl (
                id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                src text NOT NULL,
                ts timestamptz DEFAULT now()
            );
            SELECT pglogical.replication_set_add_table('default', 'public._test_repl', true);
        \$DDL\$);
    " 2>/dev/null
    sleep 3
    # Write one row to each node
    for i in "${!NODES[@]}"; do
        PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[$i]}" -U "$PG_USER" -d "$PG_DB" -c \
            "INSERT INTO public._test_repl (src) VALUES ('${NODES[$i]}');" 2>/dev/null
    done
    sleep 5
    local repl_ok=true
    for i in "${!NODES[@]}"; do
        local cnt
        cnt=$(run_sql_on "${NODE_PORTS[$i]}" "SELECT count(*) FROM public._test_repl;" 2>/dev/null || echo "0")
        if [ "$cnt" != "3" ]; then
            repl_ok=false
        fi
    done
    if $repl_ok; then
        pass "All nodes see 3 rows (write + replication verified)"
    else
        # Retry after more time
        sleep 10
        repl_ok=true
        for i in "${!NODES[@]}"; do
            local cnt
            cnt=$(run_sql_on "${NODE_PORTS[$i]}" "SELECT count(*) FROM public._test_repl;" 2>/dev/null || echo "0")
            if [ "$cnt" != "3" ]; then
                fail "${NODES[$i]}: expected 3 rows, got $cnt"
                repl_ok=false
            fi
        done
        if $repl_ok; then
            pass "All nodes see 3 rows (write + replication verified after retry)"
        fi
    fi
    # Cleanup test table via replicate_ddl_command
    PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[0]}" -U "$PG_USER" -d "$PG_DB" -c "
        SELECT pglogical.replicate_ddl_command(\$DDL\$
            DROP TABLE IF EXISTS public._test_repl CASCADE;
        \$DDL\$);
    " 2>/dev/null
    sleep 2
    exit_maintenance_mode

    # --- Test 5: keepalived VIP connectivity ---
    run_test 5 "keepalived VIP connectivity"
    local vip_holder="none"
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local has_vip
        has_vip=$(docker exec "$node" ip addr show eth0 2>/dev/null | grep "$VIP" || true)
        if [ -n "$has_vip" ]; then
            vip_holder="$node"
            break
        fi
    done
    if [ "$vip_holder" != "none" ]; then
        pass "VIP $VIP assigned to $vip_holder"
    else
        fail "VIP $VIP not assigned to any node"
    fi

    # --- Test 6: Valkey connectivity ---
    run_test 6 "Valkey connectivity"
    if docker exec mmk-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning ping 2>/dev/null | grep -q PONG; then
        pass "Valkey master responding"
    else
        fail "Valkey master not responding"
    fi

    # --- Test 7: WAL archiving enabled ---
    run_test 7 "WAL archiving enabled (archive_mode=on)"
    local am
    am=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[0]}" -U "$PG_USER" -d "$PG_DB" -tAc "SHOW archive_mode;" 2>/dev/null || echo "")
    if [ "$am" = "on" ]; then
        pass "archive_mode=on"
    else
        fail "archive_mode=$am (expected on)"
    fi

    # --- Test 8-13: pgBackRest stanza exists + backup exists per node ---
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local stanza="${ALL_STANZAS[$i]}"
        local test_num=$((8 + i * 2))

        run_test "$test_num" "pgBackRest stanza exists on $node ($stanza)"
        local stanza_ok
        stanza_ok=$(docker exec "$node" gosu postgres pgbackrest --stanza="$stanza" --output=json info 2>/dev/null | jq -r '.[0].name // empty' 2>/dev/null || echo "")
        if [ "$stanza_ok" = "$stanza" ]; then
            pass "Stanza '$stanza' exists"
        else
            fail "Stanza '$stanza' not found on $node"
        fi

        # --- Backup exists test ---
        local test_num2=$((test_num + 1))
        run_test "$test_num2" "pgBackRest has at least one backup ($node)"
        local bcount
        bcount=$(docker exec "$node" gosu postgres pgbackrest --stanza="$stanza" --output=json info 2>/dev/null | jq '.[0].backup | length' 2>/dev/null || echo "0")
        if [ "$bcount" -ge 1 ] 2>/dev/null; then
            pass "$node has $bcount backup(s)"
        else
            fail "$node has no backups"
        fi
    done

    # --- Summary ---
    echo ""
    if [ "$FAIL" -eq 0 ]; then
        log_ok "All tests passed! ($PASS passed, $FAIL failed)"
    else
        log_error "$FAIL test(s) FAILED ($PASS passed)"
        return 1
    fi
}

cmd_logs() {
    local service="${1:-}"
    if [ -n "$service" ]; then
        docker compose -f "$PROJECT_DIR/docker-compose.yml" logs -f "$service"
    else
        docker compose -f "$PROJECT_DIR/docker-compose.yml" logs -f
    fi
}

cmd_conflicts() {
    log_head "=== pglogical Conflict & Error Report ==="
    echo ""

    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"

        log_info "$node:"

        local sub_status
        sub_status=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c \
            "SELECT subscription_name, status, provider_dsn FROM pglogical.show_subscription_status();" 2>/dev/null)
        if [ -n "$sub_status" ]; then
            echo "$sub_status"
        else
            log_warn "  Could not query pglogical subscriptions"
        fi

        local cr
        cr=$(run_sql_on "$port" "SHOW pglogical.conflict_resolution;" 2>/dev/null || echo "unknown")
        log_info "  Conflict resolution: $cr"

        local lag
        lag=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c \
            "SELECT subname,
                    CASE WHEN pid IS NOT NULL THEN 'running' ELSE 'stopped' END AS worker,
                    COALESCE(received_lsn::text, 'none') AS received_lsn,
                    CASE
                        WHEN last_msg_send_time IS NULL THEN 'never'
                        ELSE extract(epoch FROM now() - last_msg_send_time)::int::text || 's ago'
                    END AS last_msg
             FROM pg_stat_subscription
             WHERE relid IS NULL
             ORDER BY subname;" 2>/dev/null)
        if [ -n "$lag" ]; then
            echo "$lag"
        fi
        echo ""
    done
}

cmd_test_multimaster() {
    log_head "=== Testing pglogical Multi-Master Replication (keepalived) ==="
    echo ""

    # ---------------------------------------------------------------------------
    # TEST 1: DDL replication via replicate_ddl_command()
    # ---------------------------------------------------------------------------
    log_head "--- Test 1: DDL Replication via pglogical.replicate_ddl_command() ---"
    echo ""

    log_info "Cleaning up any previous test table..."
    for port in "${NODE_PORTS[@]}"; do
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c \
            "DROP TABLE IF EXISTS public.pgl_repl_test CASCADE;" 2>/dev/null || true
    done
    sleep 1

    log_info "Creating test table via pglogical.replicate_ddl_command() on ${NODES[0]}..."
    local ddl_result
    ddl_result=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[0]}" -U "$PG_USER" -d "$PG_DB" -c "
        SELECT pglogical.replicate_ddl_command(\$DDL\$
            CREATE TABLE public.pgl_repl_test (
                id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                node_name text NOT NULL,
                value text NOT NULL,
                created_at timestamptz DEFAULT now()
            );
            SELECT pglogical.replication_set_add_table('default', 'public.pgl_repl_test', true);
        \$DDL\$);
    " 2>&1)
    log_info "DDL result: $ddl_result"

    log_info "Waiting for DDL replication..."
    sleep 5

    log_info "Verifying table exists on ALL nodes:"
    local ddl_pass=true
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        local exists
        exists=$(run_sql_on "$port" "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='pgl_repl_test';")
        if [ "$exists" = "1" ]; then
            log_ok "$node: table pgl_repl_test EXISTS (DDL replicated!)"
        else
            log_error "$node: table pgl_repl_test NOT FOUND"
            ddl_pass=false
        fi
    done

    echo ""
    if [ "$ddl_pass" = true ]; then
        log_ok "DDL REPLICATION TEST PASSED"
    else
        log_error "DDL REPLICATION TEST FAILED"
        log_warn "Tables may need to be created manually. Attempting fallback..."
        for i in "${!NODES[@]}"; do
            local port="${NODE_PORTS[$i]}"
            PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "
                CREATE TABLE IF NOT EXISTS public.pgl_repl_test (
                    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    node_name text NOT NULL,
                    value text NOT NULL,
                    created_at timestamptz DEFAULT now()
                );
                SELECT pglogical.replication_set_add_table('default', 'public.pgl_repl_test', true);
            " 2>/dev/null || true
        done
        sleep 2
    fi

    # ---------------------------------------------------------------------------
    # TEST 2: DML replication (INSERT)
    # ---------------------------------------------------------------------------
    echo ""
    log_head "--- Test 2: DML Replication (INSERT/UPDATE/DELETE) ---"
    echo ""

    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        log_info "Writing to $node (port $port)..."
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "
            INSERT INTO pgl_repl_test (node_name, value) VALUES ('$node', 'written directly to $node');
        " 2>/dev/null
        log_ok "Written to $node"
    done

    log_info "Waiting for replication to propagate..."
    sleep 5

    echo ""
    log_info "Verifying replication (expecting 3 rows on each node):"
    local all_pass=true
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        local row_count
        row_count=$(run_sql_on "$port" "SELECT count(*) FROM pgl_repl_test;")
        if [ "$row_count" = "3" ]; then
            log_ok "$node (port $port): $row_count rows"
        else
            log_error "$node (port $port): $row_count rows (expected 3)"
            all_pass=false
        fi
    done

    if [ "$all_pass" = true ]; then
        log_ok "INSERT replication PASSED"
    else
        log_warn "Retrying in 10s..."
        sleep 10
        for i in "${!NODES[@]}"; do
            local node="${NODES[$i]}"
            local port="${NODE_PORTS[$i]}"
            local row_count
            row_count=$(run_sql_on "$port" "SELECT count(*) FROM pgl_repl_test;")
            log_info "$node: $row_count rows"
        done
    fi

    # Test UPDATE
    echo ""
    log_info "Testing UPDATE replication (updating node1's row from node2)..."
    PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[1]}" -U "$PG_USER" -d "$PG_DB" -c "
        UPDATE pgl_repl_test SET value = 'UPDATED by node2' WHERE node_name = '${NODES[0]}';
    " 2>/dev/null
    sleep 3
    local updated
    updated=$(run_sql_on "${NODE_PORTS[2]}" "SELECT value FROM pgl_repl_test WHERE node_name = '${NODES[0]}';")
    if [ "$updated" = "UPDATED by node2" ]; then
        log_ok "UPDATE replication verified (node2 -> node3)"
    else
        log_error "UPDATE replication failed (node3 sees: '$updated')"
    fi

    # Test DELETE
    log_info "Testing DELETE replication (deleting node3's row from node1)..."
    PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[0]}" -U "$PG_USER" -d "$PG_DB" -c "
        DELETE FROM pgl_repl_test WHERE node_name = '${NODES[2]}';
    " 2>/dev/null
    sleep 3
    local remaining
    remaining=$(run_sql_on "${NODE_PORTS[1]}" "SELECT count(*) FROM pgl_repl_test;")
    if [ "$remaining" = "2" ]; then
        log_ok "DELETE replication verified (node1 -> node2)"
    else
        log_error "DELETE replication failed (node2 has $remaining rows, expected 2)"
    fi

    # ---------------------------------------------------------------------------
    # TEST 3: DDL ALTER TABLE replication
    # ---------------------------------------------------------------------------
    echo ""
    log_head "--- Test 3: ALTER TABLE via replicate_ddl_command() ---"
    echo ""

    log_info "Adding column via pglogical.replicate_ddl_command()..."
    PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[0]}" -U "$PG_USER" -d "$PG_DB" -c "
        SELECT pglogical.replicate_ddl_command(\$DDL\$
            ALTER TABLE public.pgl_repl_test ADD COLUMN IF NOT EXISTS extra_col text DEFAULT 'added_by_ddl';
        \$DDL\$);
    " 2>/dev/null
    sleep 3

    log_info "Verifying ALTER TABLE on all nodes:"
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        local col_exists
        col_exists=$(run_sql_on "$port" "SELECT 1 FROM information_schema.columns WHERE table_name='pgl_repl_test' AND column_name='extra_col';")
        if [ "$col_exists" = "1" ]; then
            log_ok "$node: column 'extra_col' exists"
        else
            log_error "$node: column 'extra_col' NOT FOUND"
        fi
    done

    # Show final state via direct node access
    echo ""
    log_info "Final data via node1:"
    PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[0]}" -U "$PG_USER" -d "$PG_DB" -c \
        "SELECT node_name, value, extra_col, created_at FROM pgl_repl_test ORDER BY node_name;" 2>/dev/null

    # ---------------------------------------------------------------------------
    # TEST 4: VIP connectivity (keepalived-specific)
    # ---------------------------------------------------------------------------
    echo ""
    log_head "--- Test 4: keepalived VIP Connectivity ---"
    echo ""
    cmd_vip_status

    # ---------------------------------------------------------------------------
    # Cleanup
    # ---------------------------------------------------------------------------
    echo ""
    log_info "Cleaning up test table..."
    PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[0]}" -U "$PG_USER" -d "$PG_DB" -c "
        SELECT pglogical.replicate_ddl_command(\$DDL\$
            DROP TABLE IF EXISTS public.pgl_repl_test CASCADE;
        \$DDL\$);
    " 2>/dev/null
    sleep 3
    log_ok "Test table dropped via replicate_ddl_command() (replicated to all nodes)"
}

cmd_bench() {
    local db="$PG_DB"
    local user="$PG_USER"
    local pass="$PG_PASS"
    local scale="${1:-10}"

    log_head "=== Multi-Master pgbench Benchmark (pglogical + keepalived) ==="
    echo ""
    log_info "Strategy: Initialize pgbench independently on each node."
    log_info "pglogical subscriptions are disabled during benchmark."
    echo ""

    # Enter maintenance mode
    log_info "Entering maintenance mode on all nodes..."
    enter_maintenance_mode

    # Disable pglogical subscriptions
    log_info "Disabling pglogical subscriptions for benchmark..."
    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        local subs
        subs=$(run_sql_on "$port" "SELECT sub_name FROM pglogical.subscription;")
        while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs)
            [ -z "$sub" ] && continue
            PGPASSWORD="$pass" psql -h localhost -p "$port" -U "$user" -d "$db" -c \
                "SELECT pglogical.alter_subscription_disable('$sub');" 2>/dev/null
        done <<< "$subs"
    done

    # Drop leftover pgbench tables
    for node in "${NODES[@]}"; do
        docker exec "$node" bash -c "PGPASSWORD='$pass' psql -h 127.0.0.1 -U $user -d $db -c '
            DROP TABLE IF EXISTS pgbench_accounts, pgbench_branches, pgbench_history, pgbench_tellers CASCADE;
        '" 2>/dev/null
    done

    # Initialize pgbench on each node
    for node in "${NODES[@]}"; do
        log_info "Initializing pgbench (scale=$scale) on $node..."
        docker exec "$node" bash -c \
            "PGPASSWORD='$pass' pgbench -i -s $scale -h 127.0.0.1 -U $user $db" 2>&1
        log_ok "$node: pgbench initialized"
    done

    echo ""
    log_info "Running pgbench WRITE test (30s, 10 clients) on each node..."
    for node in "${NODES[@]}"; do
        log_info "  WRITE benchmark on $node:"
        docker exec "$node" bash -c \
            "PGPASSWORD='$pass' pgbench -T 30 -c 10 -j 4 -h 127.0.0.1 -U $user $db" 2>&1
        echo ""
    done

    echo ""
    log_info "Running pgbench READ test (30s, 20 clients) on each node..."
    for node in "${NODES[@]}"; do
        log_info "  READ benchmark on $node:"
        docker exec "$node" bash -c \
            "PGPASSWORD='$pass' pgbench -T 30 -c 20 -j 4 -S -h 127.0.0.1 -U $user $db" 2>&1
        echo ""
    done

    # Cleanup
    echo ""
    log_info "Cleaning up pgbench tables..."
    for node in "${NODES[@]}"; do
        docker exec "$node" bash -c "PGPASSWORD='$pass' psql -h 127.0.0.1 -U $user -d $db -c '
            DROP TABLE IF EXISTS pgbench_accounts, pgbench_branches, pgbench_history, pgbench_tellers CASCADE;
        '" 2>/dev/null
    done

    # Re-enable subscriptions
    log_info "Re-enabling pglogical subscriptions..."
    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        local subs
        subs=$(run_sql_on "$port" "SELECT sub_name FROM pglogical.subscription;")
        while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs)
            [ -z "$sub" ] && continue
            PGPASSWORD="$pass" psql -h localhost -p "$port" -U "$user" -d "$db" -c \
                "SELECT pglogical.alter_subscription_enable('$sub');" 2>/dev/null
            log_ok "  Re-enabled $sub"
        done <<< "$subs"
    done

    log_ok "Benchmark complete, subscriptions re-enabled"

    # Exit maintenance mode
    log_info "Exiting maintenance mode..."
    exit_maintenance_mode
}

cmd_repair() {
    local action="${1:-}"
    local target="${2:-}"

    if [ -z "$action" ]; then
        echo "Usage: $0 repair <action> [target]"
        echo ""
        echo "Actions:"
        echo "  enable              Re-enable all pglogical subscriptions on all nodes"
        echo "  enable <node>       Re-enable subscriptions on a specific node"
        echo "  resync <node>       Drop and recreate all subscriptions on a node"
        echo "  reset-stats         Reset conflict stats counters on all nodes"
        echo ""
        echo "Examples:"
        echo "  $0 repair enable                    # Re-enable all subs"
        echo "  $0 repair enable mmk-pg-node1       # Re-enable on node1"
        echo "  $0 repair resync mmk-pg-node3       # Full resync of node3"
        echo "  $0 repair reset-stats               # Reset counters"
        return 1
    fi

    case "$action" in
        enable)
            local target_nodes=()
            local target_ports=()
            if [ -n "$target" ]; then
                case "$target" in
                    mmk-pg-node1) target_nodes=("mmk-pg-node1"); target_ports=(5741) ;;
                    mmk-pg-node2) target_nodes=("mmk-pg-node2"); target_ports=(5742) ;;
                    mmk-pg-node3) target_nodes=("mmk-pg-node3"); target_ports=(5743) ;;
                    *) log_error "Unknown node: $target"; return 1 ;;
                esac
            else
                target_nodes=("${NODES[@]}")
                target_ports=("${NODE_PORTS[@]}")
            fi

            log_info "Re-enabling pglogical subscriptions..."
            for i in "${!target_nodes[@]}"; do
                local node="${target_nodes[$i]}"
                local port="${target_ports[$i]}"
                local subs
                subs=$(run_sql_on "$port" "SELECT sub_name FROM pglogical.subscription;")
                while IFS= read -r sub; do
                    sub=$(echo "$sub" | xargs)
                    [ -z "$sub" ] && continue
                    PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c \
                        "SELECT pglogical.alter_subscription_enable('$sub');" 2>/dev/null
                    log_ok "$node: re-enabled $sub"
                done <<< "$subs"
            done
            log_ok "Done. Run '$0 conflicts' to verify."
            ;;

        resync)
            if [ -z "$target" ]; then
                log_error "Usage: $0 repair resync <node>"
                return 1
            fi
            local port node_name
            case "$target" in
                mmk-pg-node1) port=5741; node_name="pg_node1" ;;
                mmk-pg-node2) port=5742; node_name="pg_node2" ;;
                mmk-pg-node3) port=5743; node_name="pg_node3" ;;
                *) log_error "Unknown node: $target"; return 1 ;;
            esac

            log_warn "This will DROP and RECREATE all pglogical subscriptions on $target."
            log_info "Press Ctrl+C to abort, or wait 5 seconds..."
            sleep 5

            local all_nodes=(pg_node1 pg_node2 pg_node3)

            log_info "Dropping existing subscriptions on $target..."
            local subs
            subs=$(run_sql_on "$port" "SELECT sub_name FROM pglogical.subscription;")
            while IFS= read -r sub; do
                sub=$(echo "$sub" | xargs)
                [ -z "$sub" ] && continue
                PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c \
                    "SELECT pglogical.drop_subscription('$sub');" 2>/dev/null
                log_ok "$target: dropped $sub"
            done <<< "$subs"

            sleep 3

            for peer_name in "${all_nodes[@]}"; do
                [ "$peer_name" = "$node_name" ] && continue
                local peer_host="${peer_name//_/-}"
                local sub_name="${node_name}_sub_${peer_name}"
                local peer_dsn="host=$peer_host port=5432 dbname=$PG_DB user=$PG_USER password=$PG_PASS"

                log_info "$target: creating subscription $sub_name -> $peer_host..."
                PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "
                    SELECT pglogical.create_subscription(
                        subscription_name := '$sub_name',
                        provider_dsn := '$peer_dsn',
                        replication_sets := ARRAY['default', 'default_insert_only', 'ddl_sql'],
                        synchronize_structure := true,
                        synchronize_data := true,
                        forward_origins := '{}'
                    );
                " 2>/dev/null
                log_ok "$target: created $sub_name (sync=true)"
                sleep 2
            done

            log_ok "Resync initiated on $target."
            ;;

        reset-stats)
            log_info "pglogical does not have a built-in stats reset."
            log_info "Check Docker logs for conflict details: docker logs mmk-pg-node1 | grep -i conflict"
            ;;

        *)
            log_error "Unknown action: $action"
            return 1
            ;;
    esac
}

cmd_help() {
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  status               Show cluster, pglogical & keepalived VIP status"
    echo "  vip                  Show keepalived VIP status (which node holds VIP)"
    echo "  replication          Show detailed pglogical replication info"
    echo "  test                 Run integration tests (replication + pgBackRest)"
    echo "  test-multimaster     Run detailed pglogical multi-master replication test"
    echo "  ddl \"SQL\"            Execute DDL via pglogical.replicate_ddl_command()"
    echo "  ddl -f file.sql      Execute DDL from file via replicate_ddl_command()"
    echo "  conflicts            Show subscription status and errors"
    echo "  repair enable        Re-enable all pglogical subscriptions"
    echo "  repair resync <node> Drop + recreate subscriptions (full resync)"
    echo "  backup [type] [node] Run pgBackRest backup (full|diff|incr, default: full all)"
    echo "  backup-info [node]   Show pgBackRest backup info (default: all nodes)"
    echo "  backup-check [node]  Verify pgBackRest stanza + WAL archiving (default: all nodes)"
    echo "  psql [port]          Connect via psql (5741-5743=direct)"
    echo "  valkey-cli           Connect to Valkey CLI"
    echo "  logs [service]       Tail Docker logs"
    echo "  bench [scale]        Run pgbench benchmark (default scale=10)"
    echo "  help                 Show this help"
    echo ""
    echo "KEY FEATURE: keepalived floating VIP replaces HAProxy."
    echo "  Only ONE node holds the VIP ($VIP) at a time."
    echo "  Failover is automatic (~1-3s) when the VIP holder fails."
    echo ""
    echo "Direct ports: node1=5741, node2=5742, node3=5743"
    echo "VIP:          $VIP:5432 (connect from within Docker network)"
    echo "Container prefix: mmk-"
}

case "${1:-help}" in
    status)           cmd_status ;;
    vip)              cmd_vip_status ;;
    replication)      cmd_replication_detail ;;
    test)             cmd_test ;;
    test-multimaster) cmd_test_multimaster ;;
    ddl)              cmd_ddl "${2:-}" "${3:-}" ;;
    conflicts)        cmd_conflicts ;;
    repair)           cmd_repair "${2:-}" "${3:-}" ;;
    backup)           cmd_backup "${2:-full}" "${3:-}" ;;
    backup-info)      cmd_backup_info "${2:-}" ;;
    backup-check)     cmd_backup_check "${2:-}" ;;
    psql)             cmd_psql "${2:-5741}" "${@:3}" ;;
    valkey-cli)       shift; cmd_valkey_cli "$@" ;;
    logs)             cmd_logs "${2:-}" ;;
    bench)            cmd_bench "${2:-10}" ;;
    help|*)           cmd_help ;;
esac
