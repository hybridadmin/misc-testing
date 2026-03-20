#!/bin/bash
# ============================================================
# run_benchmarks.sh
#
# Runs sequential wrk benchmarks against FastAPI and TurboAPI,
# then prints a side-by-side comparison table.
#
# Usage:
#   ./benchmarks/run_benchmarks.sh            # defaults
#   ./benchmarks/run_benchmarks.sh -d 15 -c 200  # custom duration/concurrency
#
# Prerequisites: wrk  (brew install wrk / apt install wrk)
# ============================================================
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────
DURATION="${DURATION:-10}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-100}"
FASTAPI_BASE="${FASTAPI_URL:-http://localhost:8001}"
TURBOAPI_BASE="${TURBOAPI_URL:-http://localhost:8002}"
RESULTS_DIR="$(dirname "$0")/results"

while getopts "d:t:c:" opt; do
    case $opt in
        d) DURATION="$OPTARG" ;;
        t) THREADS="$OPTARG" ;;
        c) CONNECTIONS="$OPTARG" ;;
        *) ;;
    esac
done

mkdir -p "$RESULTS_DIR"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Pre-flight ───────────────────────────────────────────────
if ! command -v wrk &>/dev/null; then
    echo "ERROR: wrk not found. Install with:"
    echo "  macOS:  brew install wrk"
    echo "  Linux:  apt install wrk"
    exit 1
fi

check_service() {
    local url="$1" name="$2"
    printf "Checking %-10s ... " "$name"
    if curl -sf "${url}/health" >/dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}FAILED${NC} (${url})"
        exit 1
    fi
}

echo ""
echo "=========================================="
echo "  TurboAPI vs FastAPI Benchmark"
echo "=========================================="
echo "  Duration:    ${DURATION}s per test"
echo "  Threads:     ${THREADS}"
echo "  Connections: ${CONNECTIONS}"
echo "=========================================="
echo ""

check_service "$FASTAPI_BASE"  "FastAPI"
check_service "$TURBOAPI_BASE" "TurboAPI"

# ── Benchmark function ────────────────────────────────────────
ENDPOINTS=(
    "/health"
    "/db-test"
    "/cache-test"
    "/cached-endpoint"
    "/complex-query?n=100"
)

run_wrk() {
    local name="$1" url="$2" endpoint="$3" label="$4"
    local full_url="${url}${endpoint}"
    local out_file="${RESULTS_DIR}/${label}_$(echo "$endpoint" | sed 's/[^a-zA-Z0-9]/_/g').txt"

    echo -e "${CYAN}>> ${name} ${endpoint}${NC}"
    wrk -t"$THREADS" -c"$CONNECTIONS" -d"${DURATION}s" \
        --latency "$full_url" 2>&1 | tee "$out_file"
    echo ""
}

# ── Run all benchmarks ────────────────────────────────────────
echo ""
echo "─── FastAPI ────────────────────────────────"
for ep in "${ENDPOINTS[@]}"; do
    run_wrk "FastAPI" "$FASTAPI_BASE" "$ep" "fastapi"
done

echo ""
echo "─── TurboAPI ───────────────────────────────"
for ep in "${ENDPOINTS[@]}"; do
    run_wrk "TurboAPI" "$TURBOAPI_BASE" "$ep" "turboapi"
done

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  Benchmark Complete"
echo "=========================================="
echo "  Raw results saved to: $RESULTS_DIR/"
echo ""
echo "  To run with Locust (distributed / web UI):"
echo "    docker compose --profile benchmark up -d benchmark"
echo "    Then inside the container:"
echo "      locust -f locustfile.py --host http://app_fastapi:8001"
echo "    Or:"
echo "      locust -f locustfile.py --host http://app_turbo:8002"
echo "=========================================="
