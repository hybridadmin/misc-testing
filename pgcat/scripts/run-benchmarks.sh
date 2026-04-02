#!/usr/bin/env bash
# =============================================================================
# PgCat Benchmark Suite
# Runs a comprehensive set of pgbench tests through PgCat and directly against
# PostgreSQL for comparison.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PGCAT_HOST="${PGCAT_HOST:-pgcat}"
PGCAT_PORT="${PGCAT_PORT:-6432}"
DIRECT_HOST="${DIRECT_HOST:-pg-primary}"
DIRECT_PORT="${DIRECT_PORT:-5432}"
DB_NAME="${PGDATABASE:-benchdb}"
DB_USER="${PGUSER:-bench_user}"
DB_PASS="${PGPASSWORD:-bench_password}"

SCALE="${BENCH_SCALE:-10}"
CLIENTS="${BENCH_CLIENTS:-10}"
THREADS="${BENCH_THREADS:-4}"
DURATION="${BENCH_DURATION:-30}"
RESULTS_DIR="/scripts/results"

export PGPASSWORD="$DB_PASS"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log() { echo "[$(timestamp)] $*"; }

separator() {
    echo ""
    echo "=================================================================="
    echo "  $1"
    echo "=================================================================="
    echo ""
}

mkdir -p "$RESULTS_DIR"

REPORT_FILE="$RESULTS_DIR/benchmark-report-$(date '+%Y%m%d-%H%M%S').txt"

# Tee all output to the report file
exec > >(tee -a "$REPORT_FILE") 2>&1

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
separator "PgCat Benchmark Report"
log "Date:       $(date)"
log "Scale:      $SCALE"
log "Clients:    $CLIENTS"
log "Threads:    $THREADS"
log "Duration:   ${DURATION}s"
log "PgCat:      $PGCAT_HOST:$PGCAT_PORT"
log "Direct PG:  $DIRECT_HOST:$DIRECT_PORT"
echo ""

# ---------------------------------------------------------------------------
# 1. Initialize pgbench tables
# ---------------------------------------------------------------------------
separator "1. Initializing pgbench tables (scale=$SCALE)"

log "Initializing via PgCat..."
pgbench -i -s "$SCALE" \
    -h "$PGCAT_HOST" -p "$PGCAT_PORT" -U "$DB_USER" "$DB_NAME" 2>&1 || {
    log "WARNING: pgbench init via PgCat failed, trying direct..."
    pgbench -i -s "$SCALE" \
        -h "$DIRECT_HOST" -p "$DIRECT_PORT" -U "$DB_USER" "$DB_NAME" 2>&1
}

log "pgbench tables initialized successfully."

# ---------------------------------------------------------------------------
# 2. Built-in TPC-B (read-write) - Direct vs PgCat
# ---------------------------------------------------------------------------
separator "2. TPC-B Read-Write Benchmark (built-in)"

log "--- Direct to PostgreSQL ---"
pgbench -c "$CLIENTS" -j "$THREADS" -T "$DURATION" -P 5 --progress-timestamp \
    -h "$DIRECT_HOST" -p "$DIRECT_PORT" -U "$DB_USER" "$DB_NAME" 2>&1 \
    | tee "$RESULTS_DIR/tpcb-rw-direct.txt"

echo ""
log "--- Through PgCat ---"
pgbench -c "$CLIENTS" -j "$THREADS" -T "$DURATION" -P 5 --progress-timestamp \
    -h "$PGCAT_HOST" -p "$PGCAT_PORT" -U "$DB_USER" "$DB_NAME" 2>&1 \
    | tee "$RESULTS_DIR/tpcb-rw-pgcat.txt"

# ---------------------------------------------------------------------------
# 3. Select-Only Benchmark - Direct vs PgCat
# ---------------------------------------------------------------------------
separator "3. Select-Only Benchmark (built-in -S)"

log "--- Direct to PostgreSQL ---"
pgbench -c "$CLIENTS" -j "$THREADS" -T "$DURATION" -S -P 5 --progress-timestamp \
    -h "$DIRECT_HOST" -p "$DIRECT_PORT" -U "$DB_USER" "$DB_NAME" 2>&1 \
    | tee "$RESULTS_DIR/select-only-direct.txt"

echo ""
log "--- Through PgCat ---"
pgbench -c "$CLIENTS" -j "$THREADS" -T "$DURATION" -S -P 5 --progress-timestamp \
    -h "$PGCAT_HOST" -p "$PGCAT_PORT" -U "$DB_USER" "$DB_NAME" 2>&1 \
    | tee "$RESULTS_DIR/select-only-pgcat.txt"

# ---------------------------------------------------------------------------
# 4. Custom Read-Heavy Workload
# ---------------------------------------------------------------------------
separator "4. Custom Read-Heavy Workload"

log "--- Through PgCat (read queries routed to replica) ---"
pgbench -c "$CLIENTS" -j "$THREADS" -T "$DURATION" -P 5 --progress-timestamp \
    -f /sql/bench-read-heavy.sql \
    -h "$PGCAT_HOST" -p "$PGCAT_PORT" -U "$DB_USER" "$DB_NAME" 2>&1 \
    | tee "$RESULTS_DIR/read-heavy-pgcat.txt"

# ---------------------------------------------------------------------------
# 5. Custom Write-Heavy Workload
# ---------------------------------------------------------------------------
separator "5. Custom Write-Heavy Workload"

log "--- Through PgCat ---"
pgbench -c "$CLIENTS" -j "$THREADS" -T "$DURATION" -P 5 --progress-timestamp \
    -f /sql/bench-write-heavy.sql \
    -h "$PGCAT_HOST" -p "$PGCAT_PORT" -U "$DB_USER" "$DB_NAME" 2>&1 \
    | tee "$RESULTS_DIR/write-heavy-pgcat.txt"

# ---------------------------------------------------------------------------
# 6. Custom Mixed Workload (70% read / 30% write)
# ---------------------------------------------------------------------------
separator "6. Mixed Workload (70% read / 30% write)"

log "--- Through PgCat ---"
pgbench -c "$CLIENTS" -j "$THREADS" -T "$DURATION" -P 5 --progress-timestamp \
    -f /sql/bench-read-heavy.sql -f /sql/bench-write-heavy.sql \
    -h "$PGCAT_HOST" -p "$PGCAT_PORT" -U "$DB_USER" "$DB_NAME" 2>&1 \
    | tee "$RESULTS_DIR/mixed-pgcat.txt"

# ---------------------------------------------------------------------------
# 7. Connection Scalability Test
# ---------------------------------------------------------------------------
separator "7. Connection Scalability Test"

for c in 1 5 10 25 50; do
    log "--- $c clients through PgCat ---"
    pgbench -c "$c" -j "$THREADS" -T 15 -S \
        -h "$PGCAT_HOST" -p "$PGCAT_PORT" -U "$DB_USER" "$DB_NAME" 2>&1 \
        | tail -6
    echo ""
done

# ---------------------------------------------------------------------------
# 8. Latency Distribution Test
# ---------------------------------------------------------------------------
separator "8. Latency Distribution (PgCat)"

pgbench -c "$CLIENTS" -j "$THREADS" -T "$DURATION" -S -r \
    -h "$PGCAT_HOST" -p "$PGCAT_PORT" -U "$DB_USER" "$DB_NAME" 2>&1 \
    | tee "$RESULTS_DIR/latency-pgcat.txt"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
separator "Benchmark Complete"
log "Results saved to: $RESULTS_DIR/"
log "Full report: $REPORT_FILE"
echo ""
log "Files generated:"
ls -la "$RESULTS_DIR/"
