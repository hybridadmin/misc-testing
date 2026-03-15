#!/bin/bash
# =============================================================================
# PostgreSQL health check for Patroni-managed nodes
# Checks both Patroni REST API and pg_isready
# =============================================================================

# Check Patroni REST API is responding
PATRONI_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8008/patroni 2>/dev/null)
if [ "$PATRONI_RESPONSE" != "200" ]; then
    exit 1
fi

# Check PostgreSQL is ready
pg_isready -U postgres -q
