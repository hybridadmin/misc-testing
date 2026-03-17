#!/bin/bash
# =============================================================================
# Patroni entrypoint — starts Patroni agent which manages PostgreSQL
# =============================================================================
set -euo pipefail

PATRONI_CONFIG="/etc/patroni/patroni.yml"

# Replace placeholders in patroni.yml with environment variables
# Patroni also reads PATRONI_* env vars directly, but we template the YAML
# for clarity and to ensure passwords aren't in env output.
if [ -f "$PATRONI_CONFIG" ]; then
    sed -i \
        -e "s|PATRONI_NAME|${PATRONI_NAME:-$(hostname)}|g" \
        -e "s|POSTGRES_PASSWORD|${POSTGRES_PASSWORD:-changeme_postgres_2025}|g" \
        -e "s|REPL_PASSWORD|${POSTGRES_REPL_PASSWORD:-changeme_repl_2025}|g" \
        "$PATRONI_CONFIG"
fi

# Ensure data directory permissions
if [ -d /var/lib/postgresql/data ]; then
    chmod 700 /var/lib/postgresql/data 2>/dev/null || true
fi

# Ensure pgBackRest directories exist with correct ownership
mkdir -p /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest /etc/pgbackrest
chown postgres:postgres /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest /etc/pgbackrest 2>/dev/null || true

echo "[patroni-entrypoint] Starting Patroni as node: ${PATRONI_NAME:-$(hostname)}"
exec patroni "$PATRONI_CONFIG"
