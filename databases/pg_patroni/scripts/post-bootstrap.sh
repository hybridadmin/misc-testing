#!/bin/bash
# =============================================================================
# Post-bootstrap script — runs once after Patroni initializes the cluster
# Creates the application database and any initial schema
# =============================================================================
set -euo pipefail

echo "[post-bootstrap] Creating application database 'appdb'..."
psql -U postgres -c "CREATE DATABASE appdb;" 2>/dev/null || echo "[post-bootstrap] appdb already exists"

echo "[post-bootstrap] Done."
