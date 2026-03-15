#!/bin/bash
# =============================================================================
# Citus Cluster Setup — runs on the primary coordinator after PG is ready
# =============================================================================
# Registers the coordinator host and adds all workers to the cluster.
# Idempotent: safe to re-run (citus_add_node is a no-op for existing nodes).
# =============================================================================
set -e

PG_USER="${POSTGRES_USER:-postgres}"
PG_PASS="${POSTGRES_PASSWORD:-changeme_postgres_2025}"
PG_DB="${POSTGRES_DB:-appdb}"
WORKERS="${CITUS_WORKERS:-worker1,worker2}"

run_sql() {
    PGPASSWORD="$PG_PASS" psql -h 127.0.0.1 -p 5432 -U "$PG_USER" -d "$PG_DB" -tAc "$1"
}

echo "=== [cluster-setup] Registering coordinator host ==="
run_sql "SELECT citus_set_coordinator_host('coordinator', 5432);"

IFS=',' read -ra WORKER_LIST <<< "$WORKERS"
for worker in "${WORKER_LIST[@]}"; do
    worker=$(echo "$worker" | xargs)  # trim whitespace
    echo "=== [cluster-setup] Waiting for worker $worker ==="
    attempts=0
    while ! pg_isready -h "$worker" -p 5432 -U "$PG_USER" -t 2 >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 60 ]; then
            echo "=== [cluster-setup] ERROR: worker $worker not ready after 120s ==="
            continue 2
        fi
        sleep 2
    done

    # Extra wait for citus extension on the worker
    w_attempts=0
    while true; do
        result=$(PGPASSWORD="$PG_PASS" psql -h "$worker" -p 5432 -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM pg_extension WHERE extname='citus';" 2>/dev/null)
        if [ "$result" = "1" ]; then
            break
        fi
        w_attempts=$((w_attempts + 1))
        if [ "$w_attempts" -ge 30 ]; then
            echo "=== [cluster-setup] ERROR: citus not ready on $worker after 60s ==="
            continue 2
        fi
        sleep 2
    done

    echo "=== [cluster-setup] Adding worker $worker ==="
    run_sql "SELECT * FROM citus_add_node('$worker', 5432);"
done

echo "=== [cluster-setup] Cluster topology ==="
run_sql "SELECT nodename, nodeport, noderole, isactive FROM pg_dist_node ORDER BY nodeid;"

echo "=== [cluster-setup] Active workers ==="
run_sql "SELECT * FROM citus_get_active_worker_nodes();"
