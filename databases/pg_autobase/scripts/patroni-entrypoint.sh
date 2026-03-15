#!/bin/bash
# =============================================================================
# Patroni entrypoint — starts Patroni agent which manages PostgreSQL
# Includes pgBackRest directory setup
# =============================================================================
set -euo pipefail

PATRONI_CONFIG="/etc/patroni/patroni.yml"

# Replace placeholders in patroni.yml with environment variables
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

# Ensure pgBackRest directories exist and are writable
for dir in /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest; do
    mkdir -p "$dir" 2>/dev/null || true
    # Don't fail if we can't chown (shared volume may be owned by another process)
    chown postgres:postgres "$dir" 2>/dev/null || true
done

echo "[patroni-entrypoint] Starting Patroni as node: ${PATRONI_NAME:-$(hostname)}"
echo "[patroni-entrypoint] pgBackRest stanza: pg-autobase"
exec patroni "$PATRONI_CONFIG"
