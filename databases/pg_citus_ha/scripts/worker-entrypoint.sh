#!/bin/bash
# =============================================================================
# Worker Entrypoint for Citus 14.0 Distributed Cluster
# =============================================================================
# Simple entrypoint: copies custom configs into PGDATA on first run.
# The Citus image handles extension creation via initdb.d scripts.
# =============================================================================
set -e

mkdir -p /docker-entrypoint-initdb.d

cat > /docker-entrypoint-initdb.d/002-copy-configs.sh << 'CONFEOF'
#!/bin/bash
set -e
echo "=== Copying custom postgresql.conf and pg_hba.conf ==="
if [ -f /etc/postgresql/postgresql.conf ]; then
    cp /etc/postgresql/postgresql.conf "$PGDATA/postgresql.conf"
    echo "Copied postgresql.conf to $PGDATA"
fi
if [ -f /etc/postgresql/pg_hba.conf ]; then
    cp /etc/postgresql/pg_hba.conf "$PGDATA/pg_hba.conf"
    echo "Copied pg_hba.conf to $PGDATA"
fi
CONFEOF
chmod +x /docker-entrypoint-initdb.d/002-copy-configs.sh

cat > /docker-entrypoint-initdb.d/003-create-repl-user.sh << 'REPLEOF'
#!/bin/bash
set -e
echo "=== Creating replication user ==="
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${POSTGRES_REPL_USER:-replicator}') THEN
            CREATE ROLE ${POSTGRES_REPL_USER:-replicator} WITH LOGIN REPLICATION PASSWORD '${POSTGRES_REPL_PASSWORD:-changeme_repl_2025}';
        END IF;
    END
    \$\$;
SQL
echo "=== Replication user ready ==="
REPLEOF
chmod +x /docker-entrypoint-initdb.d/003-create-repl-user.sh

exec docker-entrypoint.sh "$@"
