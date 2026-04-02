#!/usr/bin/env bash
# =============================================================================
# Run pgbench benchmarks inside the Docker container
# Accepts optional arguments to customize the benchmark run.
#
# Usage:
#   ./scripts/bench.sh                    # Run with defaults
#   ./scripts/bench.sh --scale 20         # Custom scale factor
#   ./scripts/bench.sh --clients 50       # Custom client count
#   ./scripts/bench.sh --duration 60      # Custom duration (seconds)
#   ./scripts/bench.sh --quick            # Quick smoke test
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Defaults
SCALE=10
CLIENTS=10
THREADS=4
DURATION=30

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --scale)    SCALE="$2";    shift 2 ;;
        --clients)  CLIENTS="$2";  shift 2 ;;
        --threads)  THREADS="$2";  shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --quick)
            SCALE=1; CLIENTS=2; THREADS=2; DURATION=10
            shift ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --scale N      pgbench scale factor (default: 10)"
            echo "  --clients N    number of concurrent clients (default: 10)"
            echo "  --threads N    number of threads (default: 4)"
            echo "  --duration N   test duration in seconds (default: 30)"
            echo "  --quick        quick smoke test (scale=1, clients=2, duration=10)"
            echo "  -h, --help     show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "============================================"
echo "  Running PgCat Benchmarks"
echo "============================================"
echo "  Scale:    $SCALE"
echo "  Clients:  $CLIENTS"
echo "  Threads:  $THREADS"
echo "  Duration: ${DURATION}s"
echo "============================================"
echo ""

# Ensure pgbench container is running
if ! docker compose ps pgbench --format '{{.State}}' 2>/dev/null | grep -q running; then
    echo "Starting pgbench container..."
    docker compose up -d pgbench
    sleep 2
fi

# Run the benchmark suite inside the container
docker compose exec -T \
    -e BENCH_SCALE="$SCALE" \
    -e BENCH_CLIENTS="$CLIENTS" \
    -e BENCH_THREADS="$THREADS" \
    -e BENCH_DURATION="$DURATION" \
    pgbench bash /scripts/run-benchmarks.sh

echo ""
echo "Results are saved in ./scripts/results/"
