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
: "${PGDATA:=/var/lib/postgresql/data}"

log() { echo "[entrypoint:${NODE_NAME}] $*"; }

# --- Ensure PGDATA has correct ownership and permissions ---
# Docker volumes are created as root; PostgreSQL requires 0700
mkdir -p "$PGDATA"
chown postgres:postgres "$PGDATA"
chmod 0700 "$PGDATA"

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
  cat >> "$PGDATA/postgresql.conf" <<-'CONF'

# =============================================================================
# Spock / Replication (required for multi-master + streaming replicas)
# =============================================================================
listen_addresses = '*'
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
# WAL
# =============================================================================
wal_buffers = '8MB'
min_wal_size = '128MB'
max_wal_size = '512MB'
checkpoint_completion_target = 0.9
checkpoint_timeout = '10min'

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
  gosu postgres pg_ctl -D "$PGDATA" -o "-c listen_addresses='localhost'" -w start

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
CONF

  # Inject node name into log_line_prefix
  echo "log_line_prefix = '[${NODE_NAME}] %t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '" >> "$PGDATA/postgresql.conf"

  log "Replica initialization complete"
}

# =============================================================================
# Main
# =============================================================================
case "$NODE_ROLE" in
  primary)
    init_primary
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
