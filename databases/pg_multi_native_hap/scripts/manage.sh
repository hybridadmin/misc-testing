#!/bin/bash
# =============================================================================
# Multi-Master Cluster Management Script
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
NODES=("mm-pg-node1" "mm-pg-node2" "mm-pg-node3")
NODE_PORTS=(5441 5442 5443)

# pgBackRest — per-system-id stanzas
# Each node is an independent initdb (multi-master logical replication) -> 3 stanzas
STANZA_NODE1="${BACKUP_STANZA_NODE1:-pg-mm-node1}"
STANZA_NODE2="${BACKUP_STANZA_NODE2:-pg-mm-node2}"
STANZA_NODE3="${BACKUP_STANZA_NODE3:-pg-mm-node3}"
ALL_STANZAS=("$STANZA_NODE1" "$STANZA_NODE2" "$STANZA_NODE3")

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
# Skips disabled subscriptions (REFRESH is not allowed on disabled subs)
refresh_all_subscriptions() {
    log_info "Refreshing subscriptions on all nodes..."
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port="${NODE_PORTS[$i]}"
        # Each node has 2 subscriptions — get ENABLED ones and refresh each
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs)  # trim whitespace
            [ -z "$sub" ] && continue
            if PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION $sub REFRESH PUBLICATION WITH (copy_data = false);" 2>/dev/null; then
                log_ok "$node: refreshed $sub"
            else
                log_error "$node: failed to refresh $sub"
            fi
        done
    done
}

cmd_status() {
    log_head "=== Multi-Master Cluster Status ==="
    echo ""

    log_info "PostgreSQL Nodes:"
    for node in "${NODES[@]}"; do
        STATE=$(docker exec "$node" pg_isready -h localhost -U "$PG_USER" 2>/dev/null && echo "accepting connections" || echo "unreachable")
        if [[ "$STATE" == *"accepting"* ]]; then
            # Get replication info
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
    log_info "HAProxy Stats: http://localhost:${HAPROXY_STATS_PORT:-7000}/stats"
    log_info "  Write endpoint (all nodes): localhost:${HAPROXY_WRITE_PORT:-5432}"
    log_info "  Read endpoint (all nodes):  localhost:${HAPROXY_READ_PORT:-5433}"

    echo ""
    log_info "Valkey Cluster:"
    docker exec mm-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning INFO replication 2>/dev/null | grep -E "role:|connected_slaves:" || log_error "Valkey unreachable"
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
    local port="${1:-5432}"
    shift 2>/dev/null || true
    log_info "Connecting to PostgreSQL via localhost:$port..."
    PGPASSWORD="$PG_PASS" psql \
        -h localhost -p "$port" \
        -U "$PG_USER" \
        -d "$PG_DB" "$@"
}

cmd_valkey_cli() {
    docker exec -it mm-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning "$@"
}

cmd_logs() {
    local service="${1:-}"
    if [ -n "$service" ]; then
        docker compose -f "$PROJECT_DIR/docker-compose.yml" logs -f "$service"
    else
        docker compose -f "$PROJECT_DIR/docker-compose.yml" logs -f
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
    PGPASSWORD="$PG_PASS" psql -h localhost -p 5442 -U "$PG_USER" -d "$PG_DB" -c "
        UPDATE mm_repl_test SET value = 'UPDATED by node2' WHERE node_name = 'mm-pg-node1';
    " 2>/dev/null
    sleep 2
    UPDATED=$(PGPASSWORD="$PG_PASS" psql -h localhost -p 5443 -U "$PG_USER" -d "$PG_DB" -tAc "SELECT value FROM mm_repl_test WHERE node_name = 'mm-pg-node1';" 2>/dev/null)
    if [ "$UPDATED" = "UPDATED by node2" ]; then
        log_ok "UPDATE replication verified (node2 -> node3)"
    else
        log_error "UPDATE replication failed (node3 sees: '$UPDATED')"
    fi

    # Step 8: Test DELETE replication
    log_info "Testing DELETE replication (deleting node3's row from node1)..."
    PGPASSWORD="$PG_PASS" psql -h localhost -p 5441 -U "$PG_USER" -d "$PG_DB" -c "
        DELETE FROM mm_repl_test WHERE node_name = 'mm-pg-node3';
    " 2>/dev/null
    sleep 2
    REMAINING=$(PGPASSWORD="$PG_PASS" psql -h localhost -p 5442 -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM mm_repl_test;" 2>/dev/null)
    if [ "$REMAINING" = "2" ]; then
        log_ok "DELETE replication verified (node1 -> node2)"
    else
        log_error "DELETE replication failed (node2 has $REMAINING rows, expected 2)"
    fi

    # Show final state via HAProxy
    echo ""
    log_info "Final data via HAProxy read endpoint:"
    PGPASSWORD="$PG_PASS" psql -h localhost -p "${HAPROXY_READ_PORT:-5433}" -U "$PG_USER" -d "$PG_DB" -c "SELECT node_name, value, created_at FROM mm_repl_test ORDER BY node_name;" 2>/dev/null

    # Cleanup: disable subs, drop table on all nodes, re-enable subs
    # Must disable subscriptions FIRST to prevent poisoned WAL entries from
    # DROP TABLE on one node cascading through replication to other nodes
    echo ""
    log_info "Cleaning up test table (disabling subs -> drop -> re-enable)..."

    # Disable all subscriptions
    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs)
            [ -z "$sub" ] && continue
            PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION \"$sub\" DISABLE;" 2>/dev/null
        done
    done

    # Drop table on all nodes (with subs disabled, no WAL poisoning)
    for port in "${NODE_PORTS[@]}"; do
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "DROP TABLE IF EXISTS mm_repl_test;" 2>/dev/null
    done

    # Re-enable all subscriptions
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

    log_head "=== Multi-Master pgbench Benchmark ==="
    echo ""
    log_info "Strategy: Initialize pgbench independently on each node."
    log_info "Subscriptions are disabled during benchmark to prevent replication conflicts."
    log_info "Benchmarks each node directly to measure raw PG performance per node."
    echo ""

    # Step 1: Disable all subscriptions for the entire benchmark
    # pgbench tables are included in FOR ALL TABLES publications automatically.
    # If subs are enabled, pgbench init (CREATE TABLE + INSERT 1M rows) and the
    # benchmark writes would replicate to peers, causing duplicate key conflicts.
    # We keep subs disabled for the entire bench: init -> run -> cleanup -> re-enable.
    log_info "Disabling all subscriptions for benchmark..."
    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$pass" psql -h localhost -p "$port" -U "$user" -d "$db" -tAc "SELECT subname FROM pg_subscription WHERE subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs)
            [ -z "$sub" ] && continue
            PGPASSWORD="$pass" psql -h localhost -p "$port" -U "$user" -d "$db" -c "ALTER SUBSCRIPTION \"$sub\" DISABLE;" 2>/dev/null
        done
    done

    # Step 2: Drop any leftover pgbench tables on all nodes (subs already disabled)
    for node in "${NODES[@]}"; do
        docker exec "$node" bash -c "PGPASSWORD='$pass' psql -h 127.0.0.1 -U $user -d $db -c '
            DROP TABLE IF EXISTS pgbench_accounts, pgbench_branches, pgbench_history, pgbench_tellers CASCADE;
        '" 2>/dev/null
    done

    # Step 3: Initialize pgbench independently on EACH node
    # Each node gets identical data (pgbench -i is deterministic for a given scale)
    # Subscriptions remain disabled so pgbench DML doesn't replicate
    for node in "${NODES[@]}"; do
        log_info "Initializing pgbench (scale=$scale) on $node..."
        docker exec "$node" bash -c \
            "PGPASSWORD='$pass' pgbench -i -s $scale -h 127.0.0.1 -U $user $db" 2>&1
        log_ok "$node: pgbench initialized"
    done

    # Verify row counts match
    echo ""
    log_info "Verifying pgbench_accounts row counts:"
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local count
        count=$(docker exec "$node" bash -c "PGPASSWORD='$pass' psql -h 127.0.0.1 -U $user -d $db -tAc 'SELECT count(*) FROM pgbench_accounts;'" 2>/dev/null || echo "?")
        log_info "  $node: $count rows"
    done

    # Step 4: Run write benchmark directly against nodes (not HAProxy)
    # Subscriptions are disabled so HAProxy agent-check reports "drain".
    # We benchmark each node directly to measure raw PG write performance.
    echo ""
    log_info "Running pgbench WRITE test (30s, 10 clients) on each node directly..."
    for node in "${NODES[@]}"; do
        log_info "  WRITE benchmark on $node:"
        docker exec "$node" bash -c \
            "PGPASSWORD='$pass' pgbench -T 30 -c 10 -j 4 -h 127.0.0.1 -U $user $db" 2>&1
        echo ""
    done

    # Step 5: Run read benchmark directly against nodes
    echo ""
    log_info "Running pgbench READ test (30s, 20 clients, select-only) on each node directly..."
    for node in "${NODES[@]}"; do
        log_info "  READ benchmark on $node:"
        docker exec "$node" bash -c \
            "PGPASSWORD='$pass' pgbench -T 30 -c 20 -j 4 -S -h 127.0.0.1 -U $user $db" 2>&1
        echo ""
    done

    # Step 6: Cleanup — drop tables, drop and recreate subscriptions from current LSN
    # Cannot simply re-enable subscriptions because WAL accumulated while they were
    # disabled includes CREATE TABLE, INSERT, and DROP TABLE for pgbench tables.
    # Replaying that WAL would crash the subscription workers. Drop+recreate starts
    # each subscription from the CURRENT LSN, skipping all the bench WAL.
    echo ""
    log_info "Cleaning up pgbench tables..."

    # Drop tables on all nodes (subs already disabled)
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
        # Get subscription details: name, conninfo, publications
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

    # Step 1: Dry-run on node1 first
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
        echo "  enable <node>       Re-enable disabled subscriptions on specific node (mm-pg-node1, etc.)"
        echo "  skip <node>         Skip the current errored transaction on a node's subscriptions"
        echo "  resync <node>       Drop and recreate all subscriptions on a node (nuclear option)"
        echo "  reset-stats         Reset conflict stats counters on all nodes"
        echo ""
        echo "Examples:"
        echo "  $0 repair enable                    # Re-enable all disabled subs on all nodes"
        echo "  $0 repair enable mm-pg-node1        # Re-enable disabled subs on node1 only"
        echo "  $0 repair skip mm-pg-node2          # Skip stuck transaction on node2"
        echo "  $0 repair resync mm-pg-node3        # Full resync of node3's subscriptions"
        echo "  $0 repair reset-stats               # Zero out conflict counters"
        return 1
    fi

    case "$action" in
        enable)
            if [ -n "$target" ]; then
                # Enable on specific node
                local port
                case "$target" in
                    mm-pg-node1) port=5441 ;;
                    mm-pg-node2) port=5442 ;;
                    mm-pg-node3) port=5443 ;;
                    *) log_error "Unknown node: $target (use mm-pg-node1, mm-pg-node2, mm-pg-node3)"; return 1 ;;
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
                # Enable on all nodes
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
                mm-pg-node1) port=5441 ;;
                mm-pg-node2) port=5442 ;;
                mm-pg-node3) port=5443 ;;
                *) log_error "Unknown node: $target"; return 1 ;;
            esac
            log_info "Skipping errored transactions on $target's disabled subscriptions..."
            PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE NOT subenabled;" 2>/dev/null | while IFS= read -r sub; do
                sub=$(echo "$sub" | xargs)
                [ -z "$sub" ] && continue
                log_info "$target: skipping transaction on $sub and re-enabling..."
                # ALTER SUBSCRIPTION ... SKIP (lsn = NONE) skips the current errored xact
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
                mm-pg-node1) port=5441; node_name="pg_node1" ;;
                mm-pg-node2) port=5442; node_name="pg_node2" ;;
                mm-pg-node3) port=5443; node_name="pg_node3" ;;
                *) log_error "Unknown node: $target"; return 1 ;;
            esac

            log_warn "This will DROP and RECREATE all subscriptions on $target."
            log_warn "Data will be re-synced from peer nodes (copy_data=true)."
            log_info "Press Ctrl+C to abort, or wait 5 seconds..."
            sleep 5

            local all_nodes=(pg_node1 pg_node2 pg_node3)
            local repl_pass="${POSTGRES_REPL_PASSWORD:-changeme_repl_2025}"
            local repl_user="${POSTGRES_REPL_USER:-replicator}"

            # Step 1: Drop existing subscriptions (each ALTER/DROP must be a separate psql call)
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

            # Step 2: Drop orphaned replication slots on peer publishers
            # When we detached with SET (slot_name = NONE), the remote slots are orphaned
            log_info "Cleaning up orphaned replication slots on peer nodes..."
            for peer in "${all_nodes[@]}"; do
                [ "$peer" = "$node_name" ] && continue
                local peer_port
                case "$peer" in
                    pg_node1) peer_port=5441 ;;
                    pg_node2) peer_port=5442 ;;
                    pg_node3) peer_port=5443 ;;
                esac
                local expected_slot="sub_${peer}_to_${node_name}"
                local slot_exists
                slot_exists=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "$peer_port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM pg_replication_slots WHERE slot_name = '$expected_slot';" 2>/dev/null)
                if [ "$slot_exists" = "1" ]; then
                    PGPASSWORD="$PG_PASS" psql -h localhost -p "$peer_port" -U "$PG_USER" -d "$PG_DB" -c "SELECT pg_drop_replication_slot('$expected_slot');" 2>/dev/null
                    log_ok "Dropped orphaned slot '$expected_slot' on $peer"
                fi
            done

            # Step 3: Recreate subscriptions to each peer (each CREATE SUBSCRIPTION is a separate call)
            for peer in "${all_nodes[@]}"; do
                [ "$peer" = "$node_name" ] && continue
                local peer_host="${peer//_/-}"  # pg_node1 -> pg-node1
                local sub_name="sub_${peer}_to_${node_name}"
                local pub_name="pub_${peer}"
                local conninfo="host=mm-${peer_host} port=5432 dbname=${PG_DB} user=${repl_user} password=${repl_pass}"

                log_info "$target: creating subscription $sub_name -> $pub_name on $peer_host..."
                PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "CREATE SUBSCRIPTION \"$sub_name\" CONNECTION '${conninfo}' PUBLICATION $pub_name WITH (copy_data = true, origin = none, disable_on_error = true, streaming = parallel);" 2>/dev/null
                if [ $? -eq 0 ]; then
                    log_ok "$target: created $sub_name (copy_data=true — will sync data)"
                else
                    log_error "$target: failed to create $sub_name"
                fi
                sleep 2
            done

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

# ---------------------------------------------------------------------------
# pgBackRest helpers
# ---------------------------------------------------------------------------
# Resolve node alias to container name and stanza
resolve_backup_node() {
    local target="${1:-node1}"
    case "$target" in
        node1|pg-node1|1)  echo "mm-pg-node1|$STANZA_NODE1" ;;
        node2|pg-node2|2)  echo "mm-pg-node2|$STANZA_NODE2" ;;
        node3|pg-node3|3)  echo "mm-pg-node3|$STANZA_NODE3" ;;
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
    log_head "=== Multi-Master Cluster Integration Tests ==="
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

    # --- Test 2: Publications exist ---
    run_test 2 "Publications exist on all nodes"
    local pubs_ok=true
    for i in "${!NODES[@]}"; do
        local pub_count
        pub_count=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[$i]}" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM pg_publication;" 2>/dev/null || echo "0")
        if [ "$pub_count" -ge 1 ] 2>/dev/null; then
            :
        else
            fail "${NODES[$i]}: no publications found"
            pubs_ok=false
        fi
    done
    if $pubs_ok; then
        pass "All nodes have publications"
    fi

    # --- Test 3: Subscriptions exist and are enabled ---
    run_test 3 "Subscriptions exist and are enabled"
    local subs_ok=true
    for i in "${!NODES[@]}"; do
        local sub_count
        sub_count=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[$i]}" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM pg_subscription WHERE subenabled;" 2>/dev/null || echo "0")
        if [ "$sub_count" -ge 2 ] 2>/dev/null; then
            :
        else
            fail "${NODES[$i]}: expected >=2 enabled subscriptions, got $sub_count"
            subs_ok=false
        fi
    done
    if $subs_ok; then
        pass "All nodes have >=2 enabled subscriptions"
    fi

    # --- Test 4: Multi-master write + replication ---
    run_test 4 "Multi-master write + replication"
    # Create test table on all nodes (DDL doesn't replicate)
    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs); [ -z "$sub" ] && continue
            PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION \"$sub\" DISABLE;" 2>/dev/null
        done
    done
    for port in "${NODE_PORTS[@]}"; do
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "DROP TABLE IF EXISTS _test_repl;" 2>/dev/null
    done
    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE NOT subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs); [ -z "$sub" ] && continue
            PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION \"$sub\" ENABLE;" 2>/dev/null
        done
    done
    for port in "${NODE_PORTS[@]}"; do
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "CREATE TABLE IF NOT EXISTS _test_repl (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), src text, ts timestamptz DEFAULT now());" 2>/dev/null
    done
    # Refresh subscriptions
    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs); [ -z "$sub" ] && continue
            PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION \"$sub\" REFRESH PUBLICATION WITH (copy_data = false);" 2>/dev/null
        done
    done
    sleep 2
    # Write one row to each node
    for i in "${!NODES[@]}"; do
        PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[$i]}" -U "$PG_USER" -d "$PG_DB" -c "INSERT INTO _test_repl (src) VALUES ('${NODES[$i]}');" 2>/dev/null
    done
    sleep 5
    local repl_ok=true
    for i in "${!NODES[@]}"; do
        local cnt
        cnt=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[$i]}" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM _test_repl;" 2>/dev/null || echo "0")
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
            cnt=$(PGPASSWORD="$PG_PASS" psql -h localhost -p "${NODE_PORTS[$i]}" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM _test_repl;" 2>/dev/null || echo "0")
            if [ "$cnt" != "3" ]; then
                fail "${NODES[$i]}: expected 3 rows, got $cnt"
                repl_ok=false
            fi
        done
        if $repl_ok; then
            pass "All nodes see 3 rows (write + replication verified after retry)"
        fi
    fi
    # Cleanup test table
    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs); [ -z "$sub" ] && continue
            PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION \"$sub\" DISABLE;" 2>/dev/null
        done
    done
    for port in "${NODE_PORTS[@]}"; do
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "DROP TABLE IF EXISTS _test_repl;" 2>/dev/null
    done
    for i in "${!NODES[@]}"; do
        local port="${NODE_PORTS[$i]}"
        PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT subname FROM pg_subscription WHERE NOT subenabled;" 2>/dev/null | while IFS= read -r sub; do
            sub=$(echo "$sub" | xargs); [ -z "$sub" ] && continue
            PGPASSWORD="$PG_PASS" psql -h localhost -p "$port" -U "$PG_USER" -d "$PG_DB" -c "ALTER SUBSCRIPTION \"$sub\" ENABLE;" 2>/dev/null
        done
    done

    # --- Test 5: HAProxy connectivity ---
    run_test 5 "HAProxy connectivity"
    if PGPASSWORD="$PG_PASS" psql -h localhost -p "${HAPROXY_WRITE_PORT:-5432}" -U "$PG_USER" -d "$PG_DB" -tAc "SELECT 1;" >/dev/null 2>&1; then
        pass "HAProxy write endpoint responding"
    else
        fail "HAProxy write endpoint not responding"
    fi

    # --- Test 6: Valkey connectivity ---
    run_test 6 "Valkey connectivity"
    if docker exec mm-valkey-master valkey-cli -a "${VALKEY_PASSWORD:-changeme_valkey_2025}" --no-auth-warning ping 2>/dev/null | grep -q PONG; then
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
    log_info "Cleaning up test tables..."
    echo ""
    if [ "$FAIL" -eq 0 ]; then
        log_ok "All tests passed! ($PASS passed, $FAIL failed)"
    else
        log_error "$FAIL test(s) FAILED ($PASS passed)"
        return 1
    fi
}

cmd_help() {
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  status               Show cluster & replication status"
    echo "  replication          Show detailed replication info (publications/subscriptions)"
    echo "  test                 Run integration tests (replication + pgBackRest)"
    echo "  test-multimaster     Run detailed multi-master replication test"
    echo "  ddl \"SQL\"           Execute DDL on ALL nodes (canary test on node1 first)"
    echo "  ddl -f file.sql     Execute DDL from file on ALL nodes"
    echo "  conflicts            Show conflict stats, disabled subs, apply errors"
    echo "  repair enable        Re-enable all disabled subscriptions"
    echo "  repair skip <node>   Skip errored transaction and re-enable"
    echo "  repair resync <node> Drop + recreate subscriptions (full resync)"
    echo "  repair reset-stats   Reset conflict counters to zero"
    echo "  backup [type] [node] Run pgBackRest backup (full|diff|incr, default: full all)"
    echo "  backup-info [node]   Show pgBackRest backup info (default: all nodes)"
    echo "  backup-check [node]  Verify pgBackRest stanza + WAL archiving (default: all nodes)"
    echo "  psql [port]          Connect via psql (default: 5432=write, 5433=read)"
    echo "  valkey-cli           Connect to Valkey CLI"
    echo "  logs [service]       Tail logs (optionally for specific service)"
    echo "  bench [scale]        Run pgbench benchmark (default scale=10)"
    echo "  help                 Show this help"
    echo ""
    echo "Direct ports: node1=5441, node2=5442, node3=5443"
    echo "HAProxy:      write=5432, read=5433, stats=http://localhost:7000/stats"
    echo ""
    echo "IMPORTANT: Logical replication does NOT replicate DDL (CREATE/ALTER/DROP TABLE)."
    echo "Use '$0 ddl' to execute DDL on all nodes simultaneously."
}

case "${1:-help}" in
    status)           cmd_status ;;
    replication)      cmd_replication_detail ;;
    test)             cmd_test ;;
    test-multimaster) cmd_test_multimaster ;;
    ddl)              cmd_ddl "${2:-}" "${3:-}" ;;
    conflicts)        cmd_conflicts ;;
    repair)           cmd_repair "${2:-}" "${3:-}" ;;
    backup)           cmd_backup "${2:-full}" "${3:-}" ;;
    backup-info)      cmd_backup_info "${2:-}" ;;
    backup-check)     cmd_backup_check "${2:-}" ;;
    psql)             cmd_psql "${2:-5432}" "${@:3}" ;;
    valkey-cli)       shift; cmd_valkey_cli "$@" ;;
    logs)             cmd_logs "${2:-}" ;;
    bench)            cmd_bench "${2:-10}" ;;
    help|*)           cmd_help ;;
esac
