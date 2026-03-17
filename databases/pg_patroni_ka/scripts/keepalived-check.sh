#!/bin/bash
# =============================================================================
# keepalived Health Check Script for Patroni Primary
# =============================================================================
# Called by keepalived's vrrp_script every 3 seconds.
# Exit 0 = healthy (keep/gain VIP), Exit 1 = unhealthy (lose VIP).
#
# The VIP should only be held by the Patroni PRIMARY node.
# Unlike multi-master keepalived, we don't check subscriptions — we check
# whether this node is the current Patroni leader via the REST API.
#
# Checks:
#   1. Patroni REST API responding
#   2. This node is the Patroni primary (leader)
#   3. PostgreSQL accepting connections
# =============================================================================

PATRONI_API="http://localhost:8008"

# ---------------------------------------------------------------------------
# Check 1: Patroni REST API responding?
# ---------------------------------------------------------------------------
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${PATRONI_API}/health" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "000" ]; then
    # Patroni not responding at all — unhealthy
    exit 1
fi

# ---------------------------------------------------------------------------
# Check 2: Is this node the Patroni primary?
# The /primary endpoint returns 200 only on the leader node.
# ---------------------------------------------------------------------------
PRIMARY_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${PATRONI_API}/primary" 2>/dev/null || echo "000")
if [ "$PRIMARY_CODE" != "200" ]; then
    # Not the primary — lose the VIP
    exit 1
fi

# ---------------------------------------------------------------------------
# Check 3: PostgreSQL accepting connections?
# ---------------------------------------------------------------------------
if ! pg_isready -h /var/run/postgresql -U postgres -q 2>/dev/null; then
    exit 1
fi

# All checks passed — this node should hold the VIP
exit 0
