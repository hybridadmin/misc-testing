#!/usr/bin/env bash
# =============================================================================
# Show status of the PgCat benchmark environment
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "============================================"
echo "  PgCat Environment Status"
echo "============================================"
echo ""

# Container status
echo "--- Container Status ---"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
echo ""

# Check primary
echo "--- PostgreSQL Primary ---"
if docker compose exec -T pg-primary pg_isready -U postgres > /dev/null 2>&1; then
    echo "  Status: HEALTHY"
    CONN_COUNT=$(docker compose exec -T pg-primary psql -U postgres -tAc \
        "SELECT count(*) FROM pg_stat_activity WHERE datname = 'benchdb';" 2>/dev/null || echo "N/A")
    echo "  Active connections (benchdb): $CONN_COUNT"
    
    DB_SIZE=$(docker compose exec -T pg-primary psql -U postgres -tAc \
        "SELECT pg_size_pretty(pg_database_size('benchdb'));" 2>/dev/null || echo "N/A")
    echo "  Database size: $DB_SIZE"
else
    echo "  Status: DOWN"
fi
echo ""

# Check replica
echo "--- PostgreSQL Replica ---"
if docker compose exec -T pg-replica pg_isready -U postgres > /dev/null 2>&1; then
    echo "  Status: HEALTHY"
    IS_RECOVERY=$(docker compose exec -T pg-replica psql -U postgres -tAc \
        "SELECT pg_is_in_recovery();" 2>/dev/null || echo "N/A")
    echo "  In recovery mode: $IS_RECOVERY"
    
    REPLAY_LAG=$(docker compose exec -T pg-primary psql -U postgres -tAc \
        "SELECT COALESCE(replay_lag::text, 'N/A') FROM pg_stat_replication LIMIT 1;" 2>/dev/null || echo "N/A")
    echo "  Replication lag: $REPLAY_LAG"
else
    echo "  Status: DOWN"
fi
echo ""

# Check PgCat
echo "--- PgCat Pooler ---"
if docker compose exec -T pgcat pg_isready -h 127.0.0.1 -p 6432 > /dev/null 2>&1; then
    echo "  Status: HEALTHY (port 6432)"
else
    echo "  Status: RUNNING (admin check may not respond to pg_isready)"
fi

# Try to get PgCat stats
echo ""
echo "--- PgCat Pool Stats ---"
PGPASSWORD=pgcat_admin psql -h localhost -p 6432 -U pgcat pgcat \
    -c "SHOW POOLS;" 2>/dev/null || echo "  (Could not connect to PgCat admin - is it running?)"
echo ""
