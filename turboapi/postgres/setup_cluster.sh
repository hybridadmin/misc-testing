#!/bin/bash
set -e

echo "=========================================="
echo "  TurboAPI PostgreSQL Cluster Setup"
echo "=========================================="

PGUSER="${PGUSER:-appuser}"
PGDATABASE="${PGDATABASE:-app_db}"
REPLICATOR_USER="${REPLICATOR_USER:-replicator}"
REPLICATOR_PASSWORD="${REPLICATOR_PASSWORD:-repl_password_secure_2024}"

wait_for_postgres() {
    local container=$1
    local name=$2
    echo ">> Waiting for $name to be ready..."
    for i in {1..60}; do
        if docker exec "$container" pg_isready -U "$PGUSER" -d "$PGDATABASE" &>/dev/null; then
            echo ">> $name is ready!"
            return 0
        fi
        echo "  Attempt $i/60..."
        sleep 1
    done
    echo ">> ERROR: $name failed to start"
    return 1
}

setup_provider() {
    echo ""
    echo ">> Setting up Provider node..."
    
    docker exec turboapi_postgres_provider psql -U "$PGUSER" -d "$PGDATABASE" <<-EOSQL
        CREATE EXTENSION IF NOT EXISTS pglogical;
EOSQL
    
    echo ">> Creating provider node..."
    docker exec turboapi_postgres_provider psql -U "$PGUSER" -d "$PGDATABASE" <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM pglogical.node WHERE node_name = 'provider') THEN
                PERFORM pglogical.create_node(
                    node_name := 'provider',
                    dsn := 'host=postgres_provider port=5432 dbname=${PGDATABASE} user=${PGUSER}'
                );
            END IF;
        END
        \$\$;
EOSQL

    echo ">> Creating replication set..."
    docker exec turboapi_postgres_provider psql -U "$PGUSER" -d "$PGDATABASE" <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM pglogical.replication_set WHERE set_name = 'app_replication_set') THEN
                PERFORM pglogical.create_replication_set(
                    set_name := 'app_replication_set',
                    replicate_insert := true,
                    replicate_update := true,
                    replicate_delete := true,
                    replicate_truncate := true
                );
            END IF;
        END
        \$\$;
EOSQL

    echo ">> Setting up tables for replication..."
    docker exec turboapi_postgres_provider psql -U "$PGUSER" -d "$PGDATABASE" <<-EOSQL
        ALTER TABLE benchmark_table REPLICA IDENTITY FULL;
        ALTER TABLE users REPLICA IDENTITY FULL;
        ALTER TABLE posts REPLICA IDENTITY FULL;
        
        DO \$\$
        BEGIN
            PERFORM pglogical.replication_set_add_table(
                set_name := 'app_replication_set',
                relation := 'benchmark_table',
                synchronize_data := true
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'benchmark_table: %', SQLERRM;
        END
        \$\$;
        
        DO \$\$
        BEGIN
            PERFORM pglogical.replication_set_add_table(
                set_name := 'app_replication_set',
                relation := 'users',
                synchronize_data := true
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'users: %', SQLERRM;
        END
        \$\$;
        
        DO \$\$
        BEGIN
            PERFORM pglogical.replication_set_add_table(
                set_name := 'app_replication_set',
                relation := 'posts',
                synchronize_data := true
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'posts: %', SQLERRM;
        END
        \$\$;
EOSQL

    echo ">> Creating replicator role..."
    docker exec turboapi_postgres_provider psql -U "$PGUSER" -d "$PGDATABASE" <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${REPLICATOR_USER}') THEN
                CREATE ROLE ${REPLICATOR_USER} WITH REPLICATION LOGIN PASSWORD '${REPLICATOR_PASSWORD}';
            END IF;
            GRANT CONNECT ON DATABASE ${PGDATABASE} TO ${REPLICATOR_USER};
            GRANT USAGE ON SCHEMA pglogical TO ${REPLICATOR_USER};
            GRANT SELECT ON pglogical.tables TO ${REPLICATOR_USER};
            GRANT SELECT ON pglogical.replication_set_tables TO ${REPLICATOR_USER};
        END
        \$\$;
EOSQL
}

setup_replica() {
    local replica_name=$1
    local slot_name=$2
    
    echo ""
    echo ">> Setting up Replica: $replica_name..."
    
    echo ">> Creating subscription on $replica_name..."
    docker exec "$replica_name" psql -U "$PGUSER" -d "$PGDATABASE" <<-EOSQL
        DROP SUBSCRIPTION IF EXISTS ${slot_name}_subscription;
        
        CREATE SUBSCRIPTION ${slot_name}_subscription
        CONNECTION 'host=postgres_provider port=5432 dbname=${PGDATABASE} user=${REPLICATOR_USER} password=${REPLICATOR_PASSWORD}'
        PUBLICATION app_replication_set
        WITH (slot_name = '${slot_name}_subscription', create_slot = true, copy_data = true);
EOSQL

    echo ">> Verifying subscription on $replica_name..."
    docker exec "$replica_name" psql -U "$PGUSER" -d "$PGDATABASE" <<-EOSQL
        SELECT subname, subenabled, subpublications FROM pglogical.subscription;
EOSQL
}

show_status() {
    echo ""
    echo "=========================================="
    echo "  Cluster Status"
    echo "=========================================="
    
    echo ""
    echo ">> Provider nodes:"
    docker exec turboapi_postgres_provider psql -U "$PGUSER" -d "$PGDATABASE" -c "SELECT node_name, dsn FROM pglogical.node;" 2>/dev/null || echo "  (pglogical not ready)"
    
    echo ""
    echo ">> Replication sets:"
    docker exec turboapi_postgres_provider psql -U "$PGUSER" -d "$PGDATABASE" -c "SELECT set_name FROM pglogical.replication_set WHERE set_name NOT LIKE 'default%';" 2>/dev/null || echo "  (pglogical not ready)"
    
    echo ""
    echo ">> Provider row count:"
    docker exec turboapi_postgres_provider psql -U "$PGUSER" -d "$PGDATABASE" -t -c "SELECT count(*) FROM benchmark_table;"
    
    echo ""
    echo ">> Replica1 row count:"
    docker exec turboapi_postgres_replica1 psql -U "$PGUSER" -d "$PGDATABASE" -t -c "SELECT count(*) FROM benchmark_table;" 2>/dev/null || echo "  (not available)"
    
    echo ""
    echo ">> Replica2 row count:"
    docker exec turboapi_postgres_replica2 psql -U "$PGUSER" -d "$PGDATABASE" -t -c "SELECT count(*) FROM benchmark_table;" 2>/dev/null || echo "  (not available)"
    
    echo ""
    echo ">> Replication status on Provider:"
    docker exec turboapi_postgres_provider psql -U "$PGUSER" -d "$PGDATABASE" -c "
        SELECT 
            client_addr,
            state,
            sent_lsn,
            write_lsn,
            flush_lsn,
            replay_lsn,
            pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
        FROM pg_stat_replication;
    " 2>/dev/null || echo "  (no replicas connected)"
}

test_replication() {
    echo ""
    echo ">> Testing replication by inserting test data..."
    
    docker exec turboapi_postgres_provider psql -U "$PGUSER" -d "$PGDATABASE" <<-EOSQL
        INSERT INTO benchmark_table (data) VALUES ('cluster_test_\$(date +%s)') RETURNING id, data;
EOSQL
    
    sleep 2
    
    echo ">> Checking replicated data on Replica1:"
    docker exec turboapi_postgres_replica1 psql -U "$PGUSER" -d "$PGDATABASE" -t -c "SELECT id, data FROM benchmark_table ORDER BY id DESC LIMIT 3;"
}

main() {
    echo ""
    echo ">> Waiting for all PostgreSQL nodes to be ready..."
    wait_for_postgres "turboapi_postgres_provider" "Provider"
    wait_for_postgres "turboapi_postgres_replica1" "Replica1"
    wait_for_postgres "turboapi_postgres_replica2" "Replica2"
    
    setup_provider
    setup_replica "turboapi_postgres_replica1" "replica1"
    setup_replica "turboapi_postgres_replica2" "replica2"
    
    sleep 3
    show_status
    test_replication
    
    echo ""
    echo "=========================================="
    echo "  Cluster setup complete!"
    echo "=========================================="
}

main "$@"
