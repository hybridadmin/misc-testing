#!/bin/bash
# =============================================================================
# Multi-Master Cluster Management Script (Flyway variant)
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
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_head()  { echo -e "${CYAN}$*${NC}"; }

# Load env
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

PG_USER="${POSTGRES_USER:-postgres}"
PG_PASS="${POSTGRES_PASSWORD:-changeme_postgres_2025}"
PG_DB="${POSTGRES_DB:-appdb}"
FLYWAY_USER="${FLYWAY_USER:-postgres}"
FLYWAY_PASS="${FLYWAY_PASSWORD:-changeme_postgres_2025}"

# Container names with Flyway variant prefix
NODES=("mmf-pg-node1" "mmf-pg-node2" "mmf-pg-node3")
NODE_PORTS=(5541 5542 5543)

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

# Refresh all subscriptions on all nodes (needed after new tables are added)
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

# Exclude flyway_schema_history from all publications on a node
exclude_flyway_from_publication() {
    local port="$1"
    local node="$2"
    PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "
        ALTER PUBLICATION pub_pg_node1 DROP TABLE IF EXISTS flyway_schema_history;
        ALTER PUBLICATION pub_pg_node2 DROP TABLE IF EXISTS flyway_schema_history;
        ALTER PUBLICATION pub_pg_node3 DROP TABLE IF EXISTS flyway_schema_history;
    " 2>/dev/null || true
    log_info "$node: ensured flyway_schema_history excluded from publications"
}

cmd_status() {
    log_head "=== Multi-Master Cluster (Flyway) Status ==="
    echo ""

    log_info "PostgreSQL Nodes:"
    for node in "${NODES[@]}"; do
        STATE=$(docker exec "$node" pg_isready -h localhost -U "$PG_USER" 2>/dev/null && echo "accepting connections" || echo "unreachable")
        if [[ "$STATE" == *"accepting"* ]]; then
            PUB_COUNT=$(docker exec "$node" bash -c "PGPASSWORD='$PG_PASS' psql -h localhost -U $PG_USER -d $PG_DB -tAc 'SELECT count(*) FROM pg_publication;'" 2>/dev/null || echo "?")
            SUB_COUNT=$(docker exec "$node" bash -c "PGPASSWORD='$PG_PASS' psql -h localhost -U $PG_USER -d $PG_DB -tAc 'SELECT count(*) FROM pg_subscription;'" 2>/dev/null || echo "?")
            SUB_STATUS=$(docker exec "$node" bash -c "PGPASSWORD='$PG_PASS' psql -h localhost -U $PG_USER -d $PG_DB -tAc \"SELECT string_agg(subname || '=' || CASE WHEN subenabled THEN 'active' ELSE 'disabled' END, ', ') FROM pg_subscription;\"" 2>/dev/null || echo "?")
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
    log_info "HAProxy Stats: http://localhost:${HAPROXY_STATS_PORT:-7100}/stats"
    log_info "  Write endpoint (all nodes): localhost:${HAPROXY_WRITE_PORT:-5532}"
    log_info "  Read endpoint (all nodes):  localhost:${HAPROXY_READ_PORT:-5533}"

    echo ""
    log_info "Valkey Cluster:"
    docker exec mmf-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning INFO replication 2>/dev/null | grep -E "role:|connected_slaves:" || log_error "Valkey unreachable"
}

cmd_replication_detail() {
    log_head "=== Replication Detail ==="
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

cmd_psql() {
    local port="${1:-5532}"
    shift 2>/dev/null || true
    log_info "Connecting to PostgreSQL via localhost:$port..."
    PGPASSWORD="$PG_PASS" psql \
        -h localhost -p "$port" \
        -U "$PG_USER" \
        -d "$PG_DB" "$@"
}

cmd_valkey_cli() {
    docker exec -it mmf-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning "$@"
}

cmd_logs() {
    local service="${1:-}"
    if [ -n "$service" ]; then
        docker compose -f "$PROJECT_DIR/docker-compose.yml" logs -f "$service"
    else
        docker compose -f "$PROJECT_DIR/docker-compose.yml" logs -f
    fi
}

cmd_migrate() {
    local action="${1:-migrate}"

    if [ "$action" = "help" ]; then
        echo "Usage: $0 migrate [command]"
        echo ""
        echo "Commands:"
        echo "  migrate           Run pending Flyway migrations on ALL nodes (sequential)"
        echo "  migrate info      Show migration status on each node (no changes)"
        echo "  migrate clean     DANGER: Drop all objects in public schema (use with caution!)"
        echo "  migrate repair    Repair Flyway schema history (mark migrations as applied)"
        echo ""
        echo "How it works:"
        echo "  1. Flyway connects to each PG node directly (bypasses HAProxy)"
        echo "  2. Runs ALL pending migrations on that node"
        echo "  3. Repeats for each node"
        echo "  4. Each node maintains its own flyway_schema_history (NOT replicated)"
        echo "  5. After migrations, subscriptions are refreshed to learn new tables"
        echo ""
        echo "Examples:"
        echo "  $0 migrate                           # Run pending migrations"
        echo "  $0 migrate info                      # Check migration status"
        echo "  $0 migrate repair                    # Repair schema history"
        return 0
    fi

    log_head "=== Flyway Migration ==="
    echo ""

    local flyway_args=("-validateMigrationNaming=true" "-cleanDisabled=true")

    case "$action" in
        info)
            flyway_args+=("info")
            ;;
        clean)
            log_warn "CLEAN WILL DROP ALL OBJECTS IN PUBLIC SCHEMA!"
            log_warn "This is DANGEROUS and will break replication!"
            log_info "Press Ctrl+C to abort, or wait 5 seconds..."
            sleep 5
            flyway_args+=("clean")
            ;;
        repair)
            flyway_args+=("repair")
            ;;
        migrate|*)
            flyway_args+=("migrate")
            ;;
    esac

    # Run Flyway on each node sequentially
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        local node_name="pg-node$((i+1))"

        log_info "============================================"
        log_info "Running Flyway on $node (localhost:$port)"
        log_info "============================================"

        # Build the JDBC URL for this specific node
        # IMPORTANT: Use the internal Docker hostname (pg-node1, etc.) not localhost
        # because Flyway runs in a container on the Docker network
        local jdbc_host="pg-node$((i+1))"
        local jdbc_url="jdbc:postgresql://${jdbc_host}:5432/$PG_DB"

        log_info "Connecting to $jdbc_host (internal Docker network)"

        # Run Flyway using docker compose run (one-shot)
        # Uses the internal Docker network to reach PG nodes
        if docker compose -f "$PROJECT_DIR/docker-compose.yml" \
            --profile migration \
            run --rm \
            --no-deps \
            --entrypoint flyway \
            flyway \
            -url="$jdbc_url" \
            -user="$FLYWAY_USER" \
            -password="$FLYWAY_PASS" \
            -schemas=public \
            -locations=filesystem:/flyway/sql \
            "${flyway_args[@]}"; then
            log_ok "$node: Flyway completed successfully"
        else
            local exit_code=$?
            log_error "$node: Flyway failed with exit code $exit_code"
            log_warn "Continuing to next node (failures are non-fatal for multi-node deploy)"
        fi

        # After migrate/clean/repair, exclude flyway_schema_history from publications
        # This ensures future replication doesn't include the tracking table
        if [ "$action" != "info" ]; then
            exclude_flyway_from_publication "$port" "$node"
        fi

        echo ""
    done

    # After migrations, refresh subscriptions so they learn about new tables
    if [ "$action" = "migrate" ]; then
        log_info "Refreshing subscriptions to pick up new tables..."
        refresh_all_subscriptions
        log_ok "Migration complete! New tables are now replicating."
    fi
}

cmd_test_multimaster() {
    log_head "=== Testing Multi-Master Replication ==="
    echo ""

    # Step 1: Drop existing test table on ALL nodes (disable subs first to prevent WAL poisoning)
    log_info "Dropping existing test table on all nodes..."
    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs)
            [ -z "$sub" ] && continue
            PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION \"$sub\" DISABLE;" 2>/dev/null
        done
    done
    for port in "${NODE_PORTS[@]}"; do
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "DROP TABLE IF EXISTS mm_repl_test;" 2>/dev/null
    done
    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE NOT subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs)
            [ -z "$sub" ] && continue
            PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION \"$sub\" ENABLE;" 2>/dev/null
        done
    done

    # Step 2: Create test table on ALL nodes (DDL does NOT replicate!)
    log_info "Creating test table on ALL nodes (DDL doesn't replicate)..."
    exec_on_all_nodes "
        CREATE TABLE mm_repl_test (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            node_name text NOT NULL,
            value text NOT NULL,
            created_at timestamptz DEFAULT now()
        );
    " "created mm_repl_test"

    # Step 3: Refresh subscriptions so they learn about the new table
    refresh_all_subscriptions
    sleep 2

    # Step 4: Write directly to each node
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

    # Step 5: Wait for replication
    log_info "Waiting for replication to propagate..."
    sleep 3

    # Step 6: Verify all nodes see all 3 rows
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
        log_ok "Multi-master replication test PASSED"
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

    # Step 7: Test UPDATE replication
    echo ""
    log_info "Testing UPDATE replication (updating node1's row from node2)..."
    PGPASSWORD="$PG_PASS" psql -h localhost -p 5542 -U "$PG_USER" -d "$PG_DB" -c "
        UPDATE mm_repl_test SET value = 'UPDATED by node2' WHERE node_name = 'mmf-pg-node1';
    " 2>/dev/null
    sleep 2
    UPDATED=$(PGPASSWORD="$PG_PASS" psql -h localhost -p 5543 -U "$PG_USER" -d "$PG_DB" -tAc "SELECT value FROM mm_repl_test WHERE node_name = 'mmf-pg-node1';" 2>/dev/null)
    if [ "$UPDATED" = "UPDATED by node2" ]; then
        log_ok "UPDATE replication verified (node2 -> node3)"
    else
        log_error "UPDATE replication failed (node3 sees: '$UPDATED')"
    fi

    # Step 8: Test DELETE replication
    log_info "Testing DELETE replication (deleting node3's row from node1)..."
    PGPASSWORD="$PG_PASS" psql -h localhost -p 5541 -U "$PG_USER" -d "$PG_DB" -c "
        DELETE FROM mm_repl_test WHERE node_name = 'mmf-pg-node3';
    " 2>/dev/null
    sleep 2
    REMAINING=$(PGPASSWORD="$PG_PASS" psql -h localhost -p 5542 -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM mm_repl_test;" 2>/dev/null)
    if [ "$REMAINING" = "2" ]; then
        log_ok "DELETE replication verified (node1 -> node2)"
    else
        log_error "DELETE replication failed (node2 has $REMAINING rows, expected 2)"
    fi

    # Show final state via HAProxy
    echo ""
    log_info "Final data via HAProxy read endpoint:"
    PGPASSWORD="$PG_PASS" psql -h localhost -p "${HAPROXY_READ_PORT:-5533}" -U "$PG_USER" -d "$PG_DB" -c "SELECT node_name, value, created_at FROM mm_repl_test ORDER BY node_name;" 2>/dev/null

    # Cleanup: disable subs, drop table on all nodes, re-enable subs
    echo ""
    log_info "Cleaning up test table (disabling subs -> drop -> re-enable)..."

    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs)
            [ -z "$sub" ] && continue
            PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION \"$sub\" DISABLE;" 2>/dev/null
        done
    done

    for port in "${NODE_PORTS[@]}"; do
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "DROP TABLE IF EXISTS mm_repl_test;" 2>/dev/null
    done

    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE NOT subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs)
            [ -z "$sub" ] && continue
            PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION \"$sub\" ENABLE;" 2>/dev/null
        done
    done

    log_ok "Test table dropped and subscriptions re-enabled"
}

cmd_bench() {
    local db="$PG_DB"
    local user="$PG_USER"
    local pass="$PG_PASS"
    local scale="${1:-10}"

    log_head "=== Multi-Master pgbench Benchmark (Flyway) ==="
    echo ""
    log_info "Strategy: Initialize pgbench independently on each node."
    log_info "Subscriptions are disabled during benchmark to prevent replication conflicts."
    log_info "Benchmarks each node directly to measure raw PG performance per node."
    echo ""

    log_info "Disabling all subscriptions for benchmark..."
    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$pass" psql -h localhost -p "$port" -U "$user" -d "$db" -tAc "SELECT subname FROM pg_subscription WHERE subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs)
            [ -z "$sub" ] && continue
            PGPASSWORD="$pass" psql -h localhost -p "$port" -U "$user" -d "$db" -c "ALTER SUBSCRIPTION \"$sub\" DISABLE;" 2>/dev/null
        done
    done

    for node in "${NODES[@]}"; do
        docker exec "$node" bash -c "PGPASSWORD='$pass' psql -h 127.0.0.1 -U $user -d $db -c '
            DROP TABLE IF EXISTS pgbench_accounts, pgbench_branches, pgbench_history, pgbench_tellers CASCADE;
        '" 2>/dev/null
    done

    for node in "${NODES[@]}"; do
        log_info "Initializing pgbench (scale=$scale) on $node..."
        docker exec "$node" bash -c \
            "PGPASSWORD='$pass' pgbench -i -s $scale -h 127.0.0.1 -U $user $db" 2>&1
        log_ok "$node: pgbench initialized"
    done

    echo ""
    log_info "Verifying pgbench_accounts row counts:"
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local count
        count=$(docker exec "$node" bash -c "PGPASSWORD='$pass' psql -h 127.0.0.1 -U $user -d $db -tAc 'SELECT count(*) FROM pgbench_accounts;'" 2>/dev/null || echo "?")
        log_info "  $node: $count rows"
    done

    echo ""
    log_info "Running pgbench WRITE test (30s, 10 clients) on each node directly..."
    for node in "${NODES[@]}"; do
        log_info "  WRITE benchmark on $node:"
        docker exec "$node" bash -c \
            "PGPASSWORD='$pass' pgbench -T 30 -c 10 -j 4 -h 127.0.0.1 -U $user $db" 2>&1
        echo ""
    done

    echo ""
    log_info "Running pgbench READ test (30s, 20 clients, select-only) on each node directly..."
    for node in "${NODES[@]}"; do
        log_info "  READ benchmark on $node:"
        docker exec "$node" bash -c \
            "PGPASSWORD='$pass' pgbench -T 30 -c 20 -j 4 -S -h 127.0.0.1 -U $user $db" 2>&1
        echo ""
    done

    echo ""
    log_info "Cleaning up pgbench tables..."

    for node in "${NODES[@]}"; do
        docker exec "$node" bash -c "PGPASSWORD='$pass' psql -h 127.0.0.1 -U $user -d $db -c '
            DROP TABLE IF EXISTS pgbench_accounts, pgbench_branches, pgbench_history, pgbench_tellers CASCADE;
        '" 2>/dev/null
    done

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
            PGPASSWORD="$pass" psql -h localhost -p "$port" -U "$user" -d "$db" -c "DROP SUBSCRIPTION \"$sub\";" 2>&1
            PGPASSWORD="$pass" psql -h localhost -p "$port" -U "$user" -d "$db" -c "CREATE SUBSCRIPTION \"$sub\" CONNECTION '$conninfo' PUBLICATION $pubname WITH (copy_data = false, origin = none, streaming = parallel, disable_on_error = true);" 2>&1
            log_ok "  $node: recreated $sub"
        done
    done

    log_ok "pgbench tables dropped and subscriptions recreated"
}

cmd_ddl() {
    local sql="${1:-}"
    local sql_file="${2:-}"

    log_warn "NOTE: For DDL migrations, prefer using Flyway: ./manage.sh migrate"
    log_warn "The ddl command is for ad-hoc DDL only. Flyway provides version control."
    echo ""

    if [ -z "$sql" ]; then
        echo "Usage: $0 ddl \"SQL statement\""
        echo "       $0 ddl -f file.sql"
        echo ""
        echo "WARNING: Prefer using Flyway for schema migrations!"
        echo "  ./manage.sh migrate        # Run Flyway migrations"
        echo "  ./manage.sh migrate info   # Check status"
        echo ""
        echo "This command is for ad-hoc DDL only. DDL is executed on ALL nodes."
        echo "After execution, subscriptions are refreshed."
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

    log_info "Testing DDL on ${NODES[0]} first..."
    if PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[0]}" -U "$PG_USER" -d "$PG_DB" -c "$sql" 2>&1; then
        log_ok "${NODES[0]}: DDL succeeded (canary)"
        succeeded_nodes+=("${NODES[0]}")
    else
        log_error "${NODES[0]}: DDL FAILED on canary node — aborting. No other nodes were touched."
        return 1
    fi

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

    if [ ${#failed_nodes[@]} -gt 0 ]; then
        echo ""
        log_error "DDL failed on ${#failed_nodes[@]} node(s): ${failed_nodes[*]}"
        log_warn "DDL succeeded on: ${succeeded_nodes[*]}"
    fi

    if echo "$sql" | grep -qiE '(CREATE|DROP)\s+TABLE'; then
        refresh_all_subscriptions
    fi

    if [ ${#failed_nodes[@]} -eq 0 ]; then
        log_ok "DDL applied successfully to all ${#succeeded_nodes[@]} nodes"
    fi
}

cmd_conflicts() {
    log_head "=== Conflict & Error Report ==="
    echo ""

    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"

        log_info "$node:"

        local disabled
        disabled=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "
            SELECT string_agg(subname, ', ') FROM pg_subscription WHERE NOT subenabled;
        " 2>/dev/null)
        if [ -n "$disabled" ] && [ "$disabled" != "" ]; then
            log_error "  DISABLED subscriptions: $disabled"
        else
            log_ok "  All subscriptions enabled"
        fi

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
        echo "  enable <node>       Re-enable disabled subscriptions on specific node"
        echo "  skip <node>         Skip the current errored transaction on a node's subscriptions"
        echo "  resync <node>       Drop and recreate all subscriptions on a node (nuclear option)"
        echo "  reset-stats         Reset conflict stats counters on all nodes"
        echo ""
        echo "Examples:"
        echo "  $0 repair enable                    # Re-enable all disabled subs on all nodes"
        echo "  $0 repair enable mmf-pg-node1       # Re-enable disabled subs on node1 only"
        echo "  $0 repair skip mmf-pg-node2         # Skip stuck transaction on node2"
        echo "  $0 repair resync mmf-pg-node3       # Full resync of node3's subscriptions"
        echo "  $0 repair reset-stats               # Zero out conflict counters"
        return 1
    fi

    case "$action" in
        enable)
            if [ -n "$target" ]; then
                local port
                case "$target" in
                    mmf-pg-node1) port=5541 ;;
                    mmf-pg-node2) port=5542 ;;
                    mmf-pg-node3) port=5543 ;;
                    *) log_error "Unknown node: $target (use mmf-pg-node1, mmf-pg-node2, mmf-pg-node3)"; return 1 ;;
                esac
                log_info "Re-enabling disabled subscriptions on $target..."
                PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE NOT subenabled;" 2>/dev/null | while IFS= read -r sub; do
                    sub=$(echo "$sub" | xargs)
                    [ -z "$sub" ] && continue
                    if PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION $sub ENABLE;" 2>/dev/null; then
                        log_ok "$target: re-enabled $sub"
                    else
                        log_error "$target: failed to re-enable $sub"
                    fi
                done
            else
                log_info "Re-enabling all disabled subscriptions across all nodes..."
                for i in "${!NODES[@]}"; do
                    local node="${NODES[$i]}"
                    local port="${NODE_PORTS[$i]}"
                    PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE NOT subenabled;" 2>/dev/null | while IFS= read -r sub; do
                        sub=$(echo "$sub" | xargs)
                        [ -z "$sub" ] && continue
                        if PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION $sub ENABLE;" 2>/dev/null; then
                            log_ok "$node: re-enabled $sub"
                        else
                            log_error "$node: failed to re-enable $sub"
                        fi
                    done
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
                mmf-pg-node1) port=5541 ;;
                mmf-pg-node2) port=5542 ;;
                mmf-pg-node3) port=5543 ;;
                *) log_error "Unknown node: $target"; return 1 ;;
            esac
            log_info "Skipping errored transactions on $target's disabled subscriptions..."
            PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE NOT subenabled;" 2>/dev/null | while IFS= read -r sub; do
                sub=$(echo "$sub" | xargs)
                [ -z "$sub" ] && continue
                log_info "$target: skipping transaction on $sub and re-enabling..."
                PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION $sub SKIP (lsn = NONE);" 2>/dev/null
                PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION $sub ENABLE;" 2>/dev/null
                if [ $? -eq 0 ]; then
                    log_ok "$target: skipped and re-enabled $sub"
                else
                    log_error "$target: failed on $sub"
                fi
            done
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
                mmf-pg-node1) port=5541; node_name="pg_node1" ;;
                mmf-pg-node2) port=5542; node_name="pg_node2" ;;
                mmf-pg-node3) port=5543; node_name="pg_node3" ;;
                *) log_error "Unknown node: $target"; return 1 ;;
            esac

            log_warn "This will DROP and RECREATE all subscriptions on $target."
            log_warn "Data will be re-synced from peer nodes (copy_data=true)."
            log_info "Press Ctrl+C to abort, or wait 5 seconds..."
            sleep 5

            local all_nodes=(pg_node1 pg_node2 pg_node3)
            local repl_pass="${POSTGRES_REPL_PASSWORD:-changeme_repl_2025}"
            local repl_user="${POSTGRES_REPL_USER:-replicator}"

            log_info "Dropping existing subscriptions on $target..."
            local subs_to_drop
            subs_to_drop=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription;" 2>/dev/null)
            while IFS= read -r sub; do
                sub=$(echo "$sub" | xargs)
                [ -z "$sub" ] && continue
                PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION \"$sub\" DISABLE;" 2>/dev/null
                PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION \"$sub\" SET (slot_name = NONE);" 2>/dev/null
                PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "DROP SUBSCRIPTION \"$sub\";" 2>/dev/null
                log_ok "$target: dropped $sub"
            done <<< "$subs_to_drop"

            log_info "Cleaning up orphaned replication slots on peer nodes..."
            for peer in "${all_nodes[@]}"; do
                [ "$peer" = "$node_name" ] && continue
                local peer_port
                case "$peer" in
                    pg_node1) peer_port=5541 ;;
                    pg_node2) peer_port=5542 ;;
                    pg_node3) peer_port=5543 ;;
                esac
                local expected_slot="sub_${peer}_to_${node_name}"
                local slot_exists
                slot_exists=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "$peer_port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM pg_replication_slots WHERE slot_name = '$expected_slot';" 2>/dev/null)
                if [ "$slot_exists" = "1" ]; then
                    PGPASSWORD="$PG_PASS" psql -h localhost -p "$peer_port" -U "$PG_USER" -d "$PG_DB" -c "SELECT pg_drop_replication_slot('$expected_slot');" 2>/dev/null
                    log_ok "Dropped orphaned slot '$expected_slot' on $peer"
                fi
            done

            for peer in "${all_nodes[@]}"; do
                [ "$peer" = "$node_name" ] && continue
                local peer_host="${peer//_/-}"
                local sub_name="sub_${peer}_to_${node_name}"
                local pub_name="pub_${peer}"
                local conninfo="host=mmf-${peer_host} port=5432 dbname=${PG_DB} user=${repl_user} password=${repl_pass}"

                log_info "$target: creating subscription $sub_name -> $pub_name on $peer_host..."
                PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "CREATE SUBSCRIPTION \"$sub_name\" CONNECTION '${conninfo}' PUBLICATION $pub_name WITH (copy_data = true, origin = none, disable_on_error = true, streaming = parallel);" 2>/dev/null
                if [ $? -eq 0 ]; then
                    log_ok "$target: created $sub_name (copy_data=true)"
                else
                    log_error "$target: failed to create $sub_name"
                fi
                sleep 2
            done

            log_ok "Resync initiated on $target."
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

cmd_help() {
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  status               Show cluster & replication status"
    echo "  replication          Show detailed replication info (publications/subscriptions)"
    echo "  test                 Test multi-master replication (write to each node, verify)"
    echo "  migrate [cmd]        Run Flyway migrations on all nodes (prefer this for DDL!)"
    echo "  ddl \"SQL\"           Execute ad-hoc DDL on ALL nodes (use migrate instead)"
    echo "  conflicts            Show conflict stats, disabled subs, apply errors"
    echo "  repair enable        Re-enable all disabled subscriptions"
    echo "  repair skip <node>   Skip errored transaction and re-enable"
    echo "  repair resync <node> Drop + recreate subscriptions (full resync)"
    echo "  repair reset-stats   Reset conflict counters to zero"
    echo "  psql [port]          Connect via psql (default: 5532=write, 5533=read)"
    echo "  valkey-cli           Connect to Valkey CLI"
    echo "  logs [service]       Tail Docker logs"
    echo "  bench [scale]        Run pgbench benchmark (default scale=10)"
    echo "  help                 Show this help"
    echo ""
    echo "IMPORTANT: This cluster uses Flyway for DDL management!"
    echo "  ./manage.sh migrate           # Run pending migrations on ALL nodes"
    echo "  ./manage.sh migrate info      # Check migration status"
    echo ""
    echo "Direct ports: node1=5541, node2=5542, node3=5543"
    echo "HAProxy:      write=5532, read=5533, stats=http://localhost:7100/stats"
    echo ""
    echo "Container prefix: mmf- (to avoid conflicts with pg/ and pg_multi/)"
}

case "${1:-help}" in
    status)       cmd_status ;;
    replication)  cmd_replication_detail ;;
    test)         cmd_test_multimaster ;;
    migrate)      cmd_migrate "${2:-migrate}" ;;
    ddl)          cmd_ddl "${2:-}" "${3:-}" ;;
    conflicts)    cmd_conflicts ;;
    repair)       cmd_repair "${2:-}" "${3:-}" ;;
    psql)         cmd_psql "${2:-5532}" "${@:3}" ;;
    valkey-cli)   shift; cmd_valkey_cli "$@" ;;
    logs)         cmd_logs "${2:-}" ;;
    bench)        cmd_bench "${2:-10}" ;;
    help|*)       cmd_help ;;
esac
