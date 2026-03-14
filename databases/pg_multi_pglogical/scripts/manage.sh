#!/bin/bash
# =============================================================================
# Multi-Master Cluster Management Script (pglogical variant)
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

NODES=("mmp-pg-node1" "mmp-pg-node2" "mmp-pg-node3")
NODE_PORTS=(5641 5642 5643)

# ---------------------------------------------------------------------------
# Run SQL on a specific node via its exposed port
# ---------------------------------------------------------------------------
run_sql_on() {
    local port="$1"
    local sql="$2"
    PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "$sql" 2>/dev/null
}

# ---------------------------------------------------------------------------
# DDL via pglogical.replicate_ddl_command()
# This is THE key feature: executes DDL locally AND replicates it to all
# subscribers automatically. No need to run on each node manually.
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
        echo "  $0 ddl -f migrations/001_create_users.sql"
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

    # Warn if DDL references tables without schema qualification
    if echo "$sql" | grep -qiE '(CREATE|ALTER|DROP)\s+TABLE' && ! echo "$sql" | grep -qiE '(CREATE|ALTER|DROP)\s+TABLE\s+(IF\s+(NOT\s+)?EXISTS\s+)?public\.'; then
        log_warn "DDL may need schema qualification (public.tablename). replicate_ddl_command() uses an empty search_path."
    fi
    echo ""

    # Escape single quotes in the SQL for embedding in the function call
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

    # Wait for replication to propagate
    log_info "Waiting for DDL to replicate to peers..."
    sleep 3

    # Verify on all nodes
    echo ""
    log_info "Verifying DDL on all nodes:"
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        # Check if the DDL seems to involve a table creation
        if echo "$sql" | grep -qiE 'CREATE\s+TABLE'; then
            local table_name
            # Extract table name, stripping optional public. prefix
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
    log_head "=== Multi-Master Cluster (pglogical) Status ==="
    echo ""

    log_info "PostgreSQL Nodes:"
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        STATE=$(docker exec "$node" pg_isready -h localhost -U "$PG_USER" 2>/dev/null && echo "accepting" || echo "unreachable")
        if [[ "$STATE" == *"accepting"* ]]; then
            # pglogical node info
            local pgl_node
            pgl_node=$(run_sql_on "$port" "SELECT node_name FROM pglogical.node LIMIT 1;" 2>/dev/null || echo "?")
            # pglogical subscription count + status
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
    log_info "HAProxy Stats: http://localhost:${HAPROXY_STATS_PORT:-7200}/stats"
    log_info "  Write endpoint: localhost:${HAPROXY_WRITE_PORT:-5632}"
    log_info "  Read endpoint:  localhost:${HAPROXY_READ_PORT:-5633}"

    echo ""
    log_info "Valkey Cluster:"
    docker exec mmp-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning INFO replication 2>/dev/null | grep -E "role:|connected_slaves:" || log_error "Valkey unreachable"
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
    local port="${1:-5632}"
    shift 2>/dev/null || true
    log_info "Connecting to PostgreSQL via localhost:$port..."
    PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" "$@"
}

cmd_valkey_cli() {
    docker exec -it mmp-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning "$@"
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

        # Subscription statuses
        local sub_status
        sub_status=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c \
            "SELECT subscription_name, status, provider_dsn FROM pglogical.show_subscription_status();" 2>/dev/null)
        if [ -n "$sub_status" ]; then
            echo "$sub_status"
        else
            log_warn "  Could not query pglogical subscriptions"
        fi

        # Check conflict resolution setting
        local cr
        cr=$(run_sql_on "$port" "SHOW pglogical.conflict_resolution;" 2>/dev/null || echo "unknown")
        log_info "  Conflict resolution: $cr"

        # Also check native pg_stat_subscription for lag info
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
    log_head "=== Testing pglogical Multi-Master Replication ==="
    echo ""

    # ---------------------------------------------------------------------------
    # TEST 1: DDL replication via replicate_ddl_command()
    # ---------------------------------------------------------------------------
    log_head "--- Test 1: DDL Replication via pglogical.replicate_ddl_command() ---"
    echo ""

    # Clean up any previous test table (CASCADE needed — repset membership depends on it)
    log_info "Cleaning up any previous test table..."
    for port in "${NODE_PORTS[@]}"; do
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c \
            "DROP TABLE IF EXISTS public.pgl_repl_test CASCADE;" 2>/dev/null || true
    done
    sleep 1

    # NOTE: replicate_ddl_command() requires explicit schema (public.) because
    # it executes in a context where search_path doesn't include public.
    # We also add the table to the 'default' replication set inside the same
    # DDL command so that DML replication works immediately on all nodes.
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

    # Show final state via HAProxy
    echo ""
    log_info "Final data via HAProxy read endpoint:"
    PGPASSWORD="$PG_PASS" psql -h localhost -p "${HAPROXY_READ_PORT:-5633}" -U "$PG_USER" -d "$PG_DB" -c \
        "SELECT node_name, value, extra_col, created_at FROM pgl_repl_test ORDER BY node_name;" 2>/dev/null

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

    log_head "=== Multi-Master pgbench Benchmark (pglogical) ==="
    echo ""
    log_info "Strategy: Initialize pgbench independently on each node."
    log_info "pglogical subscriptions are disabled during benchmark."
    echo ""

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
        echo "  $0 repair enable mmp-pg-node1       # Re-enable on node1"
        echo "  $0 repair resync mmp-pg-node3       # Full resync of node3"
        echo "  $0 repair reset-stats               # Reset counters"
        return 1
    fi

    case "$action" in
        enable)
            local target_nodes=()
            local target_ports=()
            if [ -n "$target" ]; then
                case "$target" in
                    mmp-pg-node1) target_nodes=("mmp-pg-node1"); target_ports=(5641) ;;
                    mmp-pg-node2) target_nodes=("mmp-pg-node2"); target_ports=(5642) ;;
                    mmp-pg-node3) target_nodes=("mmp-pg-node3"); target_ports=(5643) ;;
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
                mmp-pg-node1) port=5641; node_name="pg_node1" ;;
                mmp-pg-node2) port=5642; node_name="pg_node2" ;;
                mmp-pg-node3) port=5643; node_name="pg_node3" ;;
                *) log_error "Unknown node: $target"; return 1 ;;
            esac

            log_warn "This will DROP and RECREATE all pglogical subscriptions on $target."
            log_info "Press Ctrl+C to abort, or wait 5 seconds..."
            sleep 5

            local all_nodes=(pg_node1 pg_node2 pg_node3)

            # Drop existing subscriptions
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

            # Recreate subscriptions
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
            log_info "Check Docker logs for conflict details: docker logs mmp-pg-node1 | grep -i conflict"
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
    echo "  status               Show cluster & pglogical status"
    echo "  replication          Show detailed pglogical replication info"
    echo "  test                 Full test: DDL replication + DML replication"
    echo "  ddl \"SQL\"            Execute DDL via pglogical.replicate_ddl_command()"
    echo "  ddl -f file.sql      Execute DDL from file via replicate_ddl_command()"
    echo "  conflicts            Show subscription status and errors"
    echo "  repair enable        Re-enable all pglogical subscriptions"
    echo "  repair resync <node> Drop + recreate subscriptions (full resync)"
    echo "  psql [port]          Connect via psql (5632=write, 5633=read)"
    echo "  valkey-cli           Connect to Valkey CLI"
    echo "  logs [service]       Tail Docker logs"
    echo "  bench [scale]        Run pgbench benchmark (default scale=10)"
    echo "  help                 Show this help"
    echo ""
    echo "KEY FEATURE: DDL replication via pglogical.replicate_ddl_command()"
    echo "  $0 ddl \"CREATE TABLE users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text);\""
    echo "  This executes DDL on one node and pglogical replicates it to ALL peers."
    echo ""
    echo "Direct ports: node1=5641, node2=5642, node3=5643"
    echo "HAProxy:      write=5632, read=5633, stats=http://localhost:7200/stats"
    echo "Container prefix: mmp-"
}

case "${1:-help}" in
    status)       cmd_status ;;
    replication)  cmd_replication_detail ;;
    test)         cmd_test_multimaster ;;
    ddl)          cmd_ddl "${2:-}" "${3:-}" ;;
    conflicts)    cmd_conflicts ;;
    repair)       cmd_repair "${2:-}" "${3:-}" ;;
    psql)         cmd_psql "${2:-5632}" "${@:3}" ;;
    valkey-cli)   shift; cmd_valkey_cli "$@" ;;
    logs)         cmd_logs "${2:-}" ;;
    bench)        cmd_bench "${2:-10}" ;;
    help|*)       cmd_help ;;
esac
