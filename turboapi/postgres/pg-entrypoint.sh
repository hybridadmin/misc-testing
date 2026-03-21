#!/bin/bash
# =============================================================================
# Custom entrypoint for PG18 turboapi nodes (pglogical multi-master)
# =============================================================================
set -e

generate_pgbackrest_conf() {
    local stanza="${PGBACKREST_STANZA:-turboapi-node}"
    local pgdata="${PGDATA:-/var/lib/postgresql/18/docker}"
    local pguser="${POSTGRES_USER:-appuser}"
    local pgpass="${POSTGRES_PASSWORD:-changeme_prod_2024}"

    cat > /etc/pgbackrest/pgbackrest.conf <<PGBR_EOF
[${stanza}]
pg1-path=${pgdata}
pg1-port=5432
pg1-socket-path=/var/run/postgresql
pg1-host-user=postgres

[global]
repo1-path=/var/lib/pgbackrest
repo1-type=posix
repo1-retention-full=2
repo1-retention-diff=3
repo1-retention-archive=2
compress-type=lz4
compress-level=1
archive-async=y
spool-path=/var/spool/pgbackrest
start-fast=y
process-max=2
log-level-console=warn
log-path=/var/log/pgbackrest

[global:archive-push]
compress-level=3
log-level-console=info
PGBR_EOF
    chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
    echo "=== [pgbackrest] Generated config for stanza '${stanza}' ==="
}

generate_pgbackrest_conf

STANZA="${PGBACKREST_STANZA:-turboapi-node}"

cat > /docker-entrypoint-initdb.d/00-copy-configs.sh << 'CONFEOF'
#!/bin/bash
set -e
if [ -f /etc/postgresql/postgresql.conf ]; then
    cp /etc/postgresql/postgresql.conf "$PGDATA/postgresql.conf"
    echo "Copied postgresql.conf to $PGDATA"
fi
if [ -f /etc/postgresql/pg_hba.conf ]; then
    cp /etc/postgresql/pg_hba.conf "$PGDATA/pg_hba.conf"
    echo "Copied pg_hba.conf to $PGDATA"
fi
CONFEOF
chmod +x /docker-entrypoint-initdb.d/00-copy-configs.sh

init_pgbackrest_bg() {
    nohup setsid bash -c '
        trap "exit 0" ERR EXIT

        STANZA="'"${STANZA}"'"
        PGUSER="${POSTGRES_USER:-appuser}"
        PGPASS="${POSTGRES_PASSWORD:-changeme_prod_2024}"

        echo "=== [pgbackrest] Waiting for PG to be ready ==="
        attempts=0
        while ! pg_isready -h /var/run/postgresql -U "$PGUSER" 2>/dev/null; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 90 ]; then
                echo "=== [pgbackrest] ERROR: PG not ready after 180s, giving up ==="
                exit 0
            fi
            sleep 2
        done

        echo "=== [pgbackrest] Creating postgres superuser for pgbackrest ==="
        PGPASSWORD="$PGPASS" psql -h /var/run/postgresql -U "$PGUSER" -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname = '\''postgres'\''" 2>/dev/null | grep -q 1 || \
            PGPASSWORD="$PGPASS" psql -h /var/run/postgresql -U "$PGUSER" -d postgres -c "CREATE ROLE postgres WITH SUPERUSER LOGIN PASSWORD '\''postgres'\''" 2>/dev/null

        echo "=== [pgbackrest] Setting archive_command ==="
        PGPASSWORD="$PGPASS" psql -h /var/run/postgresql -U "$PGUSER" -d postgres -c "ALTER SYSTEM SET archive_command = '\''pgbackrest --stanza='"${STANZA}"' archive-push %p'\'';" 2>/dev/null

        echo "=== [pgbackrest] Reloading PG to apply archive_command ==="
        sleep 5
        gosu postgres pg_ctl reload -D "$PGDATA" 2>/dev/null || true

        echo "=== [pgbackrest] Creating stanza ${STANZA} ==="
        gosu postgres pgbackrest --stanza="$STANZA" stanza-create 2>&1 || true

        echo "=== [pgbackrest] Running initial full backup for ${STANZA} ==="
        gosu postgres pgbackrest --stanza="$STANZA" --type=full backup 2>&1 || true

        echo "=== [pgbackrest] Background init complete ==="
    ' > /tmp/pgbackrest-init.log 2>&1 &
    disown
}

init_pgbackrest_bg

exec docker-entrypoint.sh "$@"
