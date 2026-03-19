#!/bin/bash
set -e

PROVIDER_HOST="${1:-postgres_provider}"
PROVIDER_PORT="${2:-5432}"
REPLICATOR_USER="${3:-replicator}"
REPLICATOR_PASSWORD="${4:-repl_password_secure_2024}"

echo "=========================================="
echo "  Creating Subscription on Replica"
echo "=========================================="
echo "Provider: $PROVIDER_HOST:$PROVIDER_PORT"
echo "Replica: localhost"

wait_for_postgres() {
    echo ">> Waiting for replica PostgreSQL to be ready..."
    until pg_isready -h localhost -p 5432 -U appuser -d app_db &>/dev/null; do
        echo "  Waiting..."
        sleep 1
    done
    echo ">> Replica PostgreSQL is ready!"
}

create_subscription() {
    echo ">> Creating subscription..."
    docker exec turboapi_postgres_replica psql -U appuser -d app_db <<-EOSQL
        DROP SUBSCRIPTION IF EXISTS app_subscription;
        
        CREATE SUBSCRIPTION app_subscription
        CONNECTION 'host=${PROVIDER_HOST} port=${PROVIDER_PORT} dbname=app_db user=${REPLICATOR_USER} password=${REPLICATOR_PASSWORD}'
        PUBLICATION app_replication_set
        WITH (slot_name = 'app_subscription', create_slot = true);
EOSQL

    echo ">> Verifying subscription..."
    docker exec turboapi_postgres_replica psql -U appuser -d app_db <<-EOSQL
        SELECT 
            subname,
            subenabled,
            subpublications,
            subslotname,
            subconninfo
        FROM pglogical.subscription;
EOSQL

    echo ">> Checking replication status..."
    sleep 2
    docker exec turboapi_postgres_replica psql -U appuser -d app_db <<-EOSQL
        SELECT 
            s.subname,
            r.state,
            r.sent_lsn,
            r.write_lsn,
            r.flush_lsn,
            r.replay_lsn,
            pg_wal_lsn_diff(r.sent_lsn, r.replay_lsn) AS lag_bytes
        FROM pglogical.subscription s
        LEFT JOIN pg_stat_replication r ON r.application_name = s.subname;
EOSQL
}

wait_for_postgres
create_subscription

echo ""
echo ">> Testing data replication..."
echo "Provider row count:"
docker exec turboapi_postgres_provider psql -U appuser -d app_db -t -c "SELECT count(*) FROM benchmark_table;"

echo "Replica row count:"
docker exec turboapi_postgres_replica psql -U appuser -d app_db -t -c "SELECT count(*) FROM benchmark_table;"

echo ""
echo "=========================================="
echo "  Subscription setup complete!"
echo "=========================================="
echo ""
echo "To check replication lag:"
echo "  docker exec turboapi_postgres_replica psql -U appuser -d app_db -c \"SELECT * FROM pg_stat_replication;\""
