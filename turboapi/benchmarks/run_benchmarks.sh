#!/bin/bash
set -e

echo "=========================================="
echo "  TurboAPI Performance Benchmark Suite"
echo "=========================================="

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check if services are running
check_service() {
    local url=$1
    local name=$2
    echo -n "Checking $name... "
    if curl -sf "$url/health" > /dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
        return 0
    else
        echo -e "${YELLOW}FAILED${NC}"
        return 1
    fi
}

echo ""
echo ">> Checking services..."
check_service "http://localhost:8001" "FastAPI"
check_service "http://localhost:8002" "TurboAPI"
echo ""

# Run benchmarks using local wrk (not container)
if command -v wrk &> /dev/null; then
    echo ">> Running benchmarks with local wrk..."
    echo ""
    
    echo "=== FastAPI /health ==="
    wrk -t4 -c100 -d10s http://localhost:8001/health
    echo ""
    
    echo "=== TurboAPI /health ==="
    wrk -t4 -c100 -d10s http://localhost:8002/health
    echo ""
    
    echo "=== FastAPI /db-test ==="
    wrk -t4 -c50 -d10s http://localhost:8001/db-test
    echo ""
    
    echo "=== TurboAPI /db-test ==="
    wrk -t4 -c50 -d10s http://localhost:8002/db-test
    echo ""
    
    echo "=== FastAPI /cached endpoint ==="
    wrk -t4 -c100 -d10s "http://localhost:8001/cached%20endpoint"
    echo ""
    
    echo "=== TurboAPI /cached endpoint ==="
    wrk -t4 -c100 -d10s "http://localhost:8002/cached%20endpoint"
    echo ""

else
    echo ">> wrk not found locally. Install with:"
    echo "   macOS: brew install wrk"
    echo "   Ubuntu/Debian: sudo apt install wrk"
    echo ""
    echo ">> Or use Locust for distributed testing:"
    echo "   docker compose --profile benchmark up -d"
    echo "   # Then open http://localhost:8089"
fi

echo "=========================================="
echo "  Benchmark Complete"
echo "=========================================="
