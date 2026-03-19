#!/bin/bash
set -e

PROVIDER_HOST="${1:-postgres_provider}"
PROVIDER_PORT="${2:-5432}"
REPLICATOR_USER="${3:-replicator}"
REPLICATOR_PASSWORD="${4:-repl_password_secure_2024}"

echo "=========================================="
echo "  Creating Replication Slot"
echo "=========================================="
echo "Provider: $PROVIDER_HOST:$PROVIDER_PORT"

docker exec turboapi_postgres_provider psql -h "$PROVIDER_HOST" -p "$PROVIDER_PORT" -U "$REPLICATOR_USER" -d app_db <<-EOSQL
    SELECT slot_name FROM pg_replication_slots WHERE slot_name = 'app_subscription';
EOSQL

echo ""
echo ">> Creating replication slot on provider..."
docker exec turboapi_postgres_provider psql -h "$PROVIDER_HOST" -p "$PROVIDER_PORT" -U "$REPLICATOR_USER" -d app_db <<-EOSQL
    SELECT pg_create_logical_replication_slot('app_subscription', 'pglogical');
EOSQL
