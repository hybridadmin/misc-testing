#!/bin/bash
set -e

echo "Waiting for PostgreSQL to accept TCP connections on 127.0.0.1..."
until pg_isready -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-postgres}" >/dev/null 2>&1; do
    sleep 2
done

echo "PostgreSQL is up! Initializing Barman..."

# Ensure log file exists
touch /var/log/barman/barman.log
chown postgres:postgres /var/log/barman/barman.log

# Set up passwordless login for Barman on localhost
export PGPASSFILE=/var/lib/postgresql/.pgpass
echo "127.0.0.1:5432:*:${POSTGRES_USER:-postgres}:${POSTGRES_PASSWORD:-postgres}" > $PGPASSFILE
# Barman user
echo "127.0.0.1:5432:*:barman:${BARMAN_PASSWORD}" >> $PGPASSFILE
chown postgres:postgres $PGPASSFILE
chmod 0600 $PGPASSFILE

# Start cron daemon
echo "${BACKUP_SCHEDULE:-0 2 * * *} postgres /usr/bin/barman backup pg" > /etc/cron.d/barman-backup
chmod 0644 /etc/cron.d/barman-backup
crontab /etc/cron.d/barman-backup
cron

# Wait a moment to ensure roles are fully active
sleep 2

# Ensure replication slot exists
gosu postgres barman receive-wal --create-slot pg || echo "Slot might already exist."

# Start WAL streaming
gosu postgres barman receive-wal pg &

# Initial backup
(
    sleep 15
    if [ ! -d "/var/lib/barman/pg/base" ] || [ -z "$(ls -A /var/lib/barman/pg/base 2>/dev/null)" ]; then
        echo "No backups found. Taking initial base backup to satisfy redundancy requirements..."
        # Force a WAL switch to ensure WAL archiving check passes before the backup
        psql -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -c "SELECT pg_switch_wal();" >/dev/null 2>&1 || true
        sleep 5
        gosu postgres barman backup pg --wait || echo "Initial backup encountered an issue."
    fi
) &

# Tail barman logs to container stdout
exec gosu postgres tail -f /var/log/barman/barman.log
