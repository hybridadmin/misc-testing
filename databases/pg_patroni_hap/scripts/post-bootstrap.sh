#!/bin/bash
# =============================================================================
# Post-bootstrap script — runs once after Patroni initializes the cluster
# Creates the application database and initializes pgBackRest
# =============================================================================
set -euo pipefail

STANZA="${PGBACKREST_STANZA:-pg-patroni-hap}"

echo "[post-bootstrap] Creating application database 'appdb'..."
psql -U postgres -c "CREATE DATABASE appdb;" 2>/dev/null || echo "[post-bootstrap] appdb already exists"

# --- pgBackRest: stanza creation + initial full backup ---
echo "[post-bootstrap] Creating pgBackRest stanza '$STANZA'..."
pgbackrest --stanza="$STANZA" stanza-create || echo "[post-bootstrap] stanza-create failed (may retry)"

echo "[post-bootstrap] Running pgBackRest check..."
pgbackrest --stanza="$STANZA" check || echo "[post-bootstrap] check failed (archive may not be ready yet)"

echo "[post-bootstrap] Starting initial full backup in background..."
nohup pgbackrest --stanza="$STANZA" --type=full backup > /tmp/pgbackrest-initial-backup.log 2>&1 &

echo "[post-bootstrap] Done."
