#!/bin/bash
set -euo pipefail

# =============================================================================
# Entrypoint for PostgreSQL 18 + Spock nodes
#
# Supports two modes:
#   NODE_ROLE=primary  -> init from scratch, run as R/W node (Spock multi-master)
#   NODE_ROLE=replica  -> set up streaming replication from REPLICA_PRIMARY_HOST
#
# PostgreSQL tuning follows autobase best practices:
#   - SSD-optimized planner (random_page_cost=1.1, effective_io_concurrency=200)
#   - Aggressive autovacuum (1% scale factors, 1s naptime, 500 cost limit)
#   - JIT disabled (OLTP recommendation — JIT overhead outweighs gains)
#   - pg_stat_statements for query monitoring
#   - Data checksums enabled at initdb
#   - scram-sha-256 password encryption
# =============================================================================

: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_PASSWORD:=postgres}"
: "${POSTGRES_DB:=spockdb}"
: "${NODE_ROLE:=primary}"
: "${NODE_NAME:=node1}"
: "${REPLICA_PRIMARY_HOST:=}"
: "${REPLICA_SLOT_NAME:=}"
: "${PGDATA:=/var/lib/postgresql/data}"

# pgBackRest stanza: each independent PG cluster (unique system-id) needs its own stanza.
# node1+node3 share a system-id (node3 is pg_basebackup of node1) -> pg-spock-node1
# node2+node4 share a system-id (node4 is pg_basebackup of node2) -> pg-spock-node2
: "${PGBACKREST_STANZA:=pg-spock-${NODE_NAME}}"

log() { echo "[entrypoint:${NODE_NAME}] $*"; }

# --- Ensure PGDATA has correct ownership and permissions ---
# Docker volumes are created as root; PostgreSQL requires 0700
mkdir -p "$PGDATA"
chown postgres:postgres "$PGDATA"
chmod 0700 "$PGDATA"

# --- Ensure pgBackRest directories exist and are writable ---
for dir in /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest; do
    mkdir -p "$dir" 2>/dev/null || true
    chown postgres:postgres "$dir" 2>/dev/null || true
done

# --- Generate per-node pgbackrest.conf ---
# Each independent PG instance (different system-id) MUST have its own stanza.
# node1 & node3 share system-id -> stanza pg-spock-node1
# node2 & node4 share system-id -> stanza pg-spock-node2
generate_pgbackrest_conf() {
  local stanza="$1"
  cat > /etc/pgbackrest/pgbackrest.conf <<EOF
[global]
repo1-path=/var/lib/pgbackrest
repo1-type=posix

# Retention
repo1-retention-full=2
repo1-retention-diff=3
repo1-retention-archive=2
repo1-retention-archive-type=full

# Performance
process-max=2
compress-type=lz4
compress-level=1

# Reliability
start-fast=y
delta=y
resume=n

# Logging
log-level-console=warn
log-path=/var/log/pgbackrest

# Archive async
archive-async=y
spool-path=/var/spool/pgbackrest

[global:archive-push]
compress-level=3
log-level-console=info

[global:archive-get]
process-max=2

[${stanza}]
pg1-path=${PGDATA}
pg1-port=5432
pg1-socket-path=/var/run/postgresql
EOF
  chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
  log "Generated pgbackrest.conf with stanza='${stanza}'"
}

mkdir -p /etc/pgbackrest
generate_pgbackrest_conf "$PGBACKREST_STANZA"

# --- Helper: wait for PG to accept connections ---
wait_for_pg() {
  local host="${1:-localhost}"
  local port="${2:-5432}"
  local max_attempts=60
  for i in $(seq 1 $max_attempts); do
    if pg_isready -h "$host" -p "$port" -U "$POSTGRES_USER" -q 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  log "ERROR: PostgreSQL at $host:$port not ready after ${max_attempts}s"
  return 1
}

# =============================================================================
# Init primary from scratch
# =============================================================================
init_primary() {
  if [ -s "$PGDATA/PG_VERSION" ]; then
    log "Data directory already initialized, skipping initdb"
    return 0
  fi

  log "Initializing primary database (with data checksums)..."
  gosu postgres initdb \
    --username="$POSTGRES_USER" \
    --encoding=UTF8 \
    --locale=en_US.UTF-8 \
    --data-checksums

  # --- postgresql.conf (autobase-style tuning) ---
  # NOTE: archive_command uses the per-node stanza (variable interpolation required)
  cat >> "$PGDATA/postgresql.conf" <<CONF

# =============================================================================
# Spock / Replication (required for multi-master + streaming replicas)
# =============================================================================
listen_addresses = '*'
unix_socket_directories = '/var/run/postgresql'
wal_level = logical
max_worker_processes = 16
max_replication_slots = 20
max_wal_senders = 20
track_commit_timestamp = on
shared_preload_libraries = 'spock,pg_stat_statements'

# --- Streaming replication for RO replicas ---
hot_standby = on
hot_standby_feedback = on
wal_log_hints = on
wal_compression = on

# =============================================================================
# Connection (autobase defaults)
# =============================================================================
max_connections = 200
superuser_reserved_connections = 5
idle_in_transaction_session_timeout = '10min'
statement_timeout = '60s'
tcp_keepalives_count = 10
tcp_keepalives_idle = 300
tcp_keepalives_interval = 30

# =============================================================================
# Memory (conservative for Docker VM — 4 PG nodes sharing resources)
# =============================================================================
shared_buffers = '128MB'
effective_cache_size = '384MB'
work_mem = '8MB'
maintenance_work_mem = '64MB'
huge_pages = off

# =============================================================================
# WAL + Archiving (pgBackRest)
# =============================================================================
wal_buffers = '8MB'
min_wal_size = '128MB'
max_wal_size = '512MB'
checkpoint_completion_target = 0.9
checkpoint_timeout = '10min'
archive_mode = on
archive_timeout = 300
archive_command = 'pgbackrest --stanza=${PGBACKREST_STANZA} archive-push %p'

# =============================================================================
# Query Planner (SSD-optimized, autobase defaults)
# =============================================================================
random_page_cost = 1.1
seq_page_cost = 1
effective_io_concurrency = 200
default_statistics_target = 500
jit = off

# =============================================================================
# Autovacuum (autobase aggressive defaults)
# =============================================================================
autovacuum = on
autovacuum_max_workers = 3
autovacuum_analyze_scale_factor = 0.01
autovacuum_vacuum_scale_factor = 0.01
autovacuum_vacuum_cost_limit = 500
autovacuum_vacuum_cost_delay = 2
autovacuum_naptime = '1s'

# =============================================================================
# Logging (autobase-style)
# =============================================================================
log_destination = 'stderr'
logging_collector = off
log_min_duration_statement = 1000
log_checkpoints = on
log_connections = off
log_disconnections = off
log_lock_waits = on
log_temp_files = 0
track_io_timing = on
track_activity_query_size = 4096
track_functions = 'all'

# =============================================================================
# Extensions — pg_stat_statements
# =============================================================================
pg_stat_statements.max = 10000
pg_stat_statements.track = 'all'
pg_stat_statements.track_planning = on
pg_stat_statements.track_utility = off
pg_stat_statements.save = on

# =============================================================================
# Security
# =============================================================================
password_encryption = 'scram-sha-256'
max_locks_per_transaction = 512
CONF

  # Inject the node name into log_line_prefix (uses variable, can't be in heredoc with 'CONF')
  echo "log_line_prefix = '[${NODE_NAME}] %t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '" >> "$PGDATA/postgresql.conf"

  # --- pg_hba.conf ---
  cat > "$PGDATA/pg_hba.conf" <<-HBA
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     trust
host    all             all             0.0.0.0/0               scram-sha-256
host    replication     all             0.0.0.0/0               scram-sha-256
HBA

  # Start temporarily to create DB, users, extensions
  gosu postgres pg_ctl -D "$PGDATA" -o "-c listen_addresses='localhost' -c unix_socket_directories='/var/run/postgresql'" -w start

  # All psql commands must connect via /var/run/postgresql
  export PGHOST=/var/run/postgresql

  # Set superuser password
  gosu postgres psql -v ON_ERROR_STOP=1 <<-SQL
    ALTER USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';
SQL

  # Create application database
  if [ "$POSTGRES_DB" != "postgres" ]; then
    gosu postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${POSTGRES_DB};"
  fi

  # Create replication user
  gosu postgres psql -v ON_ERROR_STOP=1 <<-SQL
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') THEN
        CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator';
      END IF;
    END
    \$\$;
    GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO replicator;
SQL

  # Install extensions
  gosu postgres psql -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 <<-SQL
    CREATE EXTENSION IF NOT EXISTS spock;
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL

  # Create a physical replication slot for the streaming replica.
  # This prevents the primary from recycling WAL segments before the replica
  # has consumed them, and silences the spock_failover_slots
  # "primary_slot_name is not set" error on the replica side.
  if [ -n "${REPLICA_SLOT_NAME:-}" ]; then
    log "Creating physical replication slot '${REPLICA_SLOT_NAME}'..."
    gosu postgres psql -v ON_ERROR_STOP=1 -c \
      "SELECT pg_create_physical_replication_slot('${REPLICA_SLOT_NAME}');" || true
  fi

  # Run any init scripts
  for f in /docker-entrypoint-initdb.d/*; do
    [ -e "$f" ] || continue
    case "$f" in
      *.sh)  log "Running $f"; . "$f" ;;
      *.sql) log "Running $f"; gosu postgres psql -d "$POSTGRES_DB" -f "$f" ;;
    esac
  done

  gosu postgres pg_ctl -D "$PGDATA" -w stop
  log "Primary initialization complete"
}

# =============================================================================
# Init streaming replica
# =============================================================================
init_replica() {
  if [ -s "$PGDATA/PG_VERSION" ]; then
    log "Data directory already initialized, skipping basebackup"
    return 0
  fi

  log "Waiting for primary at ${REPLICA_PRIMARY_HOST}:5432..."
  wait_for_pg "$REPLICA_PRIMARY_HOST" 5432

  log "Taking base backup from ${REPLICA_PRIMARY_HOST} (checkpoint=fast)..."
  PGPASSWORD="${POSTGRES_PASSWORD}" gosu postgres pg_basebackup \
    -h "$REPLICA_PRIMARY_HOST" \
    -p 5432 \
    -U "$POSTGRES_USER" \
    -D "$PGDATA" \
    -Fp -Xs -P -R \
    --checkpoint=fast \
    --max-rate=100M

  # Adjust config for replica
  cat >> "$PGDATA/postgresql.conf" <<-CONF

# === Replica overrides ===
hot_standby = on
primary_conninfo = 'host=${REPLICA_PRIMARY_HOST} port=5432 user=${POSTGRES_USER} password=${POSTGRES_PASSWORD}'
restore_command = 'pgbackrest --stanza=${PGBACKREST_STANZA} archive-get %f "%p"'

# Spock failover slot synchronization: spock_failover_slots worker uses this DSN
# to connect to the primary for slot position sync. Without it, the worker tries
# to connect without a password, causing recurring FATAL auth errors in primary logs.
spock.primary_dsn = 'host=${REPLICA_PRIMARY_HOST} port=5432 dbname=${POSTGRES_DB} user=${POSTGRES_USER} password=${POSTGRES_PASSWORD}'
CONF

  # Set primary_slot_name if a dedicated replication slot was created on the primary.
  # This also silences the spock_failover_slots "primary_slot_name is not set" error.
  if [ -n "${REPLICA_SLOT_NAME:-}" ]; then
    echo "primary_slot_name = '${REPLICA_SLOT_NAME}'" >> "$PGDATA/postgresql.conf"
  fi

  # Inject node name into log_line_prefix
  echo "log_line_prefix = '[${NODE_NAME}] %t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '" >> "$PGDATA/postgresql.conf"

  log "Replica initialization complete"
}

# =============================================================================
# pgBackRest init (runs in background after PG is fully up, primaries only)
# Each primary creates its own stanza (different system-ids from separate initdb).
# =============================================================================
init_pgbackrest_bg() {
  local stanza="$PGBACKREST_STANZA"
  (
    # Wait for PostgreSQL to be ready
    sleep 3
    local max_wait=60
    for i in $(seq 1 "$max_wait"); do
      if gosu postgres pg_isready -q 2>/dev/null; then
        break
      fi
      sleep 1
    done

    log "Initializing pgBackRest stanza '${stanza}'..."
    gosu postgres pgbackrest --stanza="$stanza" stanza-create 2>&1 || log "WARN: pgbackrest stanza-create failed (may already exist)"

    log "Running pgBackRest check..."
    gosu postgres pgbackrest --stanza="$stanza" check 2>&1 || log "WARN: pgbackrest check failed"

    log "Creating initial full backup for stanza '${stanza}' (background)..."
    gosu postgres pgbackrest --stanza="$stanza" --type=full backup > /var/log/pgbackrest/initial-backup.log 2>&1 || log "WARN: initial backup failed"

    log "pgBackRest initialization complete (stanza='${stanza}')"
  ) &
}

# =============================================================================
# Main
# =============================================================================
case "$NODE_ROLE" in
  primary)
    init_primary
    # Both primaries create their own pgBackRest stanza + initial backup.
    # Each has a unique system-id from independent initdb, so each needs its own stanza.
    init_pgbackrest_bg
    ;;
  replica)
    init_replica
    ;;
  *)
    log "ERROR: Unknown NODE_ROLE=$NODE_ROLE (expected 'primary' or 'replica')"
    exit 1
    ;;
esac

log "Starting PostgreSQL (role=${NODE_ROLE})..."
exec gosu postgres postgres -D "$PGDATA"
