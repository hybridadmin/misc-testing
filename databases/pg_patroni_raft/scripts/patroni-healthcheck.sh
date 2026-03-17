#!/bin/bash
# Patroni health check script
# Returns 0 if this node is healthy (either primary or replica)
set -e

PATRONI_API="http://localhost:8008"

# Check if Patroni API is responding
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${PATRONI_API}/health" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
    exit 0
else
    exit 1
fi
