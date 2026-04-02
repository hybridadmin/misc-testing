#!/usr/bin/env bash
# =============================================================================
# Tear down the PgCat benchmark environment
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "============================================"
echo "  Tearing Down PgCat Environment"
echo "============================================"
echo ""

read -p "Remove volumes (all data will be lost)? [y/N] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Stopping containers and removing volumes..."
    docker compose down -v --remove-orphans
    echo "All containers and volumes removed."
else
    echo "Stopping containers (preserving volumes)..."
    docker compose down --remove-orphans
    echo "Containers stopped. Data volumes preserved."
    echo "Run with -v to also remove volumes: docker compose down -v"
fi

echo ""
echo "Done."
