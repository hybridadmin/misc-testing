#!/bin/bash
# =============================================================================
# Post-bootstrap script — runs once after Patroni initializes the cluster
# Creates the application database, enables extensions, and sets up pgBackRest
# =============================================================================
set -euo pipefail

echo "[post-bootstrap] Creating application database 'appdb'..."
psql -U postgres -c "CREATE DATABASE appdb;" 2>/dev/null || echo "[post-bootstrap] appdb already exists"

echo "[post-bootstrap] Enabling pg_stat_statements extension..."
psql -U postgres -d appdb -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" 2>/dev/null || true

echo "[post-bootstrap] Initializing pgBackRest stanza..."
# pgBackRest stanza-create needs PostgreSQL running with archive_mode=on
# This runs inside the primary after bootstrap, so PG is available
pgbackrest --stanza=pg-autobase stanza-create 2>&1 || echo "[post-bootstrap] pgBackRest stanza-create returned non-zero (may already exist)"

echo "[post-bootstrap] Running pgBackRest check..."
pgbackrest --stanza=pg-autobase check 2>&1 || echo "[post-bootstrap] pgBackRest check returned non-zero (archive may not be ready yet)"

echo "[post-bootstrap] Creating initial full backup (background)..."
# Run the first full backup in background so bootstrap doesn't block
nohup pgbackrest --stanza=pg-autobase --type=full backup > /var/log/pgbackrest/initial-backup.log 2>&1 &

echo "[post-bootstrap] Done."
