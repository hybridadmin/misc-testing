#!/usr/bin/env bash
# =============================================================================
# Quick connectivity and functionality test
# Verifies that PgCat is working correctly before running full benchmarks.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "  [PASS] $desc"
        ((PASS++))
    else
        echo "  [FAIL] $desc"
        ((FAIL++))
    fi
}

echo "============================================"
echo "  PgCat Quick Connectivity Test"
echo "============================================"
echo ""

echo "--- Direct PostgreSQL Connections ---"
check "Primary accepts connections" \
    docker compose exec -T pg-primary pg_isready -U postgres

check "Replica accepts connections" \
    docker compose exec -T pg-replica pg_isready -U postgres

check "Primary: benchdb exists" \
    docker compose exec -T pg-primary psql -U bench_user -d benchdb -c "SELECT 1;"

check "Replica: benchdb is readable" \
    docker compose exec -T pg-replica psql -U bench_user -d benchdb -c "SELECT 1;"

check "Replica: is in recovery mode" \
    docker compose exec -T pg-replica psql -U postgres -tAc "SELECT pg_is_in_recovery();" \
    | grep -q "t"

echo ""
echo "--- PgCat Connections ---"
check "PgCat: bench_user can connect" \
    docker compose exec -T pgbench psql -h pgcat -p 6432 -U bench_user -d benchdb -c "SELECT 1;"

check "PgCat: can read pgbench_accounts (after init)" \
    docker compose exec -T pgbench psql -h pgcat -p 6432 -U bench_user -d benchdb \
    -c "SELECT count(*) FROM app_metrics;"

check "PgCat: can write through pooler" \
    docker compose exec -T pgbench psql -h pgcat -p 6432 -U bench_user -d benchdb \
    -c "INSERT INTO app_metrics (metric_name, metric_value) VALUES ('test', 1.0);"

echo ""
echo "--- Replication ---"
REPL_STATE=$(docker compose exec -T pg-primary psql -U postgres -tAc \
    "SELECT state FROM pg_stat_replication LIMIT 1;" 2>/dev/null | tr -d ' ')
if [ "$REPL_STATE" = "streaming" ]; then
    echo "  [PASS] Streaming replication is active"
    ((PASS++))
else
    echo "  [FAIL] Replication state: '$REPL_STATE' (expected 'streaming')"
    ((FAIL++))
fi

echo ""
echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
