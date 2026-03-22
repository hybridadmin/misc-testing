#!/bin/bash
set -e

# Setup the Barman role and necessary permissions
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE ROLE barman WITH REPLICATION LOGIN PASSWORD '$BARMAN_PASSWORD';
    GRANT pg_read_all_settings TO barman;
    GRANT pg_read_all_stats TO barman;
    GRANT pg_read_all_data TO barman;
    GRANT EXECUTE ON FUNCTION pg_backup_start(text, boolean) TO barman;
    GRANT EXECUTE ON FUNCTION pg_backup_stop(boolean) TO barman;
    GRANT EXECUTE ON FUNCTION pg_switch_wal() TO barman;
    GRANT EXECUTE ON FUNCTION pg_create_restore_point(text) TO barman;
    -- Barman will create the replication slot automatically since 'create_slot = auto' is set
EOSQL

echo "host all barman 127.0.0.1/32 scram-sha-256" >> "$PGDATA/pg_hba.conf"
echo "host replication barman 127.0.0.1/32 scram-sha-256" >> "$PGDATA/pg_hba.conf"
echo "host all barman all scram-sha-256" >> "$PGDATA/pg_hba.conf"
echo "host replication barman all scram-sha-256" >> "$PGDATA/pg_hba.conf"
