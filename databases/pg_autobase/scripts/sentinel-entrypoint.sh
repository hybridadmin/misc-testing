#!/bin/bash
# =============================================================================
# Valkey Sentinel entrypoint
# Copies and configures sentinel.conf, then starts sentinel
# =============================================================================
set -euo pipefail

SENTINEL_CONF="/tmp/sentinel.conf"

# Copy template (sentinel modifies its config at runtime)
cp /etc/valkey/sentinel.conf "$SENTINEL_CONF"

# Substitute passwords from environment
if [ -n "${VALKEY_PASSWORD:-}" ]; then
    sed -i \
        -e "s|changeme_valkey_2025|${VALKEY_PASSWORD}|g" \
        "$SENTINEL_CONF"
fi

echo "[sentinel-entrypoint] Starting Valkey Sentinel"
exec valkey-sentinel "$SENTINEL_CONF"
