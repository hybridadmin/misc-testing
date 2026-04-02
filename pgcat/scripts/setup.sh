#!/usr/bin/env bash
# =============================================================================
# Setup & Start the PgCat benchmark environment
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "============================================"
echo "  PgCat Benchmark Environment Setup"
echo "============================================"
echo ""

# Clean up any previous runs
echo "[1/5] Cleaning up previous containers and volumes..."
docker compose down -v --remove-orphans 2>/dev/null || true

# Build and start services
echo "[2/5] Starting PostgreSQL primary..."
docker compose up -d pg-primary
echo "  Waiting for primary to be healthy..."
until docker compose exec -T pg-primary pg_isready -U postgres > /dev/null 2>&1; do
    sleep 2
done
echo "  Primary is ready."

echo "[3/5] Starting PostgreSQL replica..."
docker compose up -d pg-replica
echo "  Waiting for replica to be healthy..."
sleep 5
until docker compose exec -T pg-replica pg_isready -U postgres > /dev/null 2>&1; do
    sleep 2
done
echo "  Replica is ready."

# Verify replication
echo "  Verifying streaming replication..."
REPL_STATE=$(docker compose exec -T pg-primary psql -U postgres -tAc \
    "SELECT state FROM pg_stat_replication WHERE application_name = 'walreceiver';" 2>/dev/null || echo "unknown")
if [ "$REPL_STATE" = "streaming" ]; then
    echo "  Replication status: STREAMING (OK)"
else
    echo "  WARNING: Replication state is '$REPL_STATE' (may still be initializing)"
fi

echo "[4/5] Starting PgCat pooler..."
docker compose up -d pgcat
sleep 3
echo "  PgCat is running on port 6432."

echo "[5/5] Starting pgbench runner container..."
docker compose up -d pgbench
sleep 2

echo ""
echo "============================================"
echo "  Environment is ready!"
echo "============================================"
echo ""
echo "Connection endpoints:"
echo "  PostgreSQL Primary:  localhost:5432"
echo "  PostgreSQL Replica:  localhost:5433"
echo "  PgCat Pooler:        localhost:6432"
echo ""
echo "Credentials:"
echo "  User:     bench_user"
echo "  Password: bench_password"
echo "  Database: benchdb"
echo ""
echo "Quick test:"
echo "  psql -h localhost -p 6432 -U bench_user benchdb"
echo ""
echo "Run benchmarks:"
echo "  ./scripts/bench.sh"
echo ""
echo "PgCat admin stats:"
echo "  psql -h localhost -p 6432 -U pgcat pgcat -c 'SHOW POOLS;'"
echo ""
