#!/bin/bash
set -e

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-appuser}"
PGDATABASE="${PGDATABASE:-app_db}"

echo "=========================================="
echo "  pglogical Replication Setup"
echo "=========================================="
echo "Provider: $PGHOST:$PGPORT"
echo "Database: $PGDATABASE"
echo "User: $PGUSER"

wait_for_postgres() {
    echo ">> Waiting for PostgreSQL to be ready..."
    until pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" &>/dev/null; do
        echo "  Waiting..."
        sleep 1
    done
    echo ">> PostgreSQL is ready!"
}

setup_provider() {
    echo ""
    echo ">> Setting up Provider (node: provider)..."
    
    docker exec "$CONTAINER_NAME" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" <<-EOSQL
        -- Create pglogical extension if not exists
        CREATE EXTENSION IF NOT EXISTS pglogical;
		
        -- Create provider node
		DO \$\$
		BEGIN
		    IF NOT EXISTS (SELECT 1 FROM pglogical.node WHERE node_name = 'provider') THEN
		        PERFORM pglogical.create_node(
		            node_name := 'provider',
		            dsn := 'host=postgres port=5432 dbname=${PGDATABASE} user=${PGUSER}'
		        );
		    END IF;
		END
		\$\$;
EOSQL

    echo ">> Creating replication set..."
    docker exec "$CONTAINER_NAME" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" <<-EOSQL
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

    echo ">> Adding tables to replication set..."
    docker exec "$CONTAINER_NAME" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" <<-EOSQL
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
    docker exec "$CONTAINER_NAME" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
                CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'repl_password_secure_2024';
            END IF;
            GRANT CONNECT ON DATABASE ${PGDATABASE} TO replicator;
            GRANT USAGE ON SCHEMA pglogical TO replicator;
            GRANT SELECT ON pglogical.tables TO replicator;
            GRANT SELECT ON pglogical.replication_set_tables TO replicator;
            GRANT SELECT ON pglogical.replication_set_seq TO replicator;
            GRANT SELECT ON pglogical.sequence_to_replicate TO replicator;
        END
        \$\$;
EOSQL

    echo ">> Verifying setup..."
    docker exec "$CONTAINER_NAME" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" <<-EOSQL
        SELECT 'Nodes:' as info;
        SELECT node_name FROM pglogical.node;
        SELECT 'Replication Sets:' as info;
        SELECT set_name FROM pglogical.replication_set WHERE set_name NOT LIKE 'default%';
        SELECT 'Tables in replication set:' as info;
        SELECT set_nspname || '.' || set_relname AS table_name 
        FROM pglogical.replication_set_table;
EOSQL
}

CONTAINER_NAME="${CONTAINER_NAME:-turboapi_postgres_provider}"

wait_for_postgres
setup_provider

echo ""
echo "=========================================="
echo "  Provider setup complete!"
echo "=========================================="
