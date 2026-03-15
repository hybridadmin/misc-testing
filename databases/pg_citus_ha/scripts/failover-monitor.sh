#!/bin/bash
# =============================================================================
# Shell-Based Failover Monitor for Citus Coordinator HA
# =============================================================================
# Replaces keepalived for environments where VRRP raw sockets are unavailable
# (e.g., Docker on Apple Silicon / Rosetta 2 emulation).
#
# Runs on BOTH coordinator nodes. Behavior depends on role:
#
# PRIMARY mode (IS_COORDINATOR_PRIMARY=true):
#   - Assigns VIP to self on startup
#   - No failover logic needed (we ARE the primary)
#   - Periodically logs health status
#
# STANDBY mode (IS_COORDINATOR_PRIMARY=false):
#   - Polls primary coordinator via pg_isready every CHECK_INTERVAL seconds
#   - After FAILOVER_THRESHOLD consecutive failures, triggers failover:
#     1. Assigns VIP to self (ip addr add)
#     2. Promotes to primary (pg_promote)
#     3. Re-registers as Citus coordinator
#   - Once promoted, stops monitoring (stays primary, no preemption)
#
# NOTE: In production on native Linux (without Rosetta), you should use
# keepalived with VRRP unicast instead. Keepalived provides ~3s failover,
# split-brain protection via VRRP advertisement, and preemption support.
# This script is a simpler fallback (~10-15s failover, no split-brain
# protection) suitable for development and testing environments.
#
# Environment variables:
#   MY_IP                  - This node's IP
#   COORDINATOR_IP         - Primary coordinator IP
#   COORDINATOR_STANDBY_IP - Standby coordinator IP
#   KEEPALIVED_VIP         - Virtual IP address
#   IS_COORDINATOR_PRIMARY - "true" for primary, "false" for standby
#   POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB - PG credentials
# =============================================================================

LOG_FILE="/tmp/failover-monitor.log"
CHECK_INTERVAL="${FAILOVER_CHECK_INTERVAL:-3}"       # seconds between checks
FAILOVER_THRESHOLD="${FAILOVER_THRESHOLD:-3}"         # consecutive failures before failover

MY_IP="${MY_IP:-}"
VIP="${KEEPALIVED_VIP:-172.34.0.100}"
PRIMARY_IP="${COORDINATOR_IP:-172.34.0.10}"
STANDBY_IP="${COORDINATOR_STANDBY_IP:-172.34.0.11}"
IS_PRIMARY="${IS_COORDINATOR_PRIMARY:-false}"
PG_USER="${POSTGRES_USER:-postgres}"
PG_PASS="${POSTGRES_PASSWORD:-changeme_postgres_2025}"
PG_DB="${POSTGRES_DB:-appdb}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [failover-monitor] $*" | tee -a "$LOG_FILE"
}

pg_local_query() {
    PGPASSWORD="$PG_PASS" psql -h 127.0.0.1 -p 5432 -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Assign VIP to this node's eth0
# ---------------------------------------------------------------------------
assign_vip() {
    # Check if VIP is already on this node
    if ip addr show eth0 | grep -q "$VIP"; then
        log "VIP $VIP already assigned to this node"
        return 0
    fi

    log "Assigning VIP $VIP to eth0..."
    ip addr add "$VIP/16" dev eth0 2>/dev/null
    if [ $? -eq 0 ]; then
        log "VIP $VIP assigned successfully"
        # Send gratuitous ARP to update network caches
        arping -c 3 -A -I eth0 "$VIP" >/dev/null 2>&1 || true
        return 0
    else
        log "ERROR: Failed to assign VIP $VIP"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Remove VIP from this node's eth0
# ---------------------------------------------------------------------------
remove_vip() {
    if ip addr show eth0 | grep -q "$VIP"; then
        log "Removing VIP $VIP from eth0..."
        ip addr del "$VIP/16" dev eth0 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Promote this standby to primary
# ---------------------------------------------------------------------------
promote_standby() {
    log "=== FAILOVER: Promoting standby to primary ==="

    # Step 1: Assign VIP
    assign_vip
    if [ $? -ne 0 ]; then
        log "ERROR: Could not assign VIP, aborting promotion"
        return 1
    fi

    # Step 2: Check if we're actually in recovery (standby)
    local is_standby
    is_standby=$(pg_local_query "SELECT pg_is_in_recovery();")

    if [ "$is_standby" != "t" ]; then
        log "Not in recovery mode — already primary, skipping promotion"
        return 0
    fi

    # Step 3: Promote via SQL
    log "Calling pg_promote()..."
    pg_local_query "SELECT pg_promote(true, 60);" >/dev/null

    # Step 4: Wait for promotion to complete
    local attempts=0
    while true; do
        local still_standby
        still_standby=$(pg_local_query "SELECT pg_is_in_recovery();")
        if [ "$still_standby" = "f" ]; then
            log "Promotion complete — node is now PRIMARY"
            break
        fi
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 30 ]; then
            log "WARNING: Promotion taking >30s, may need manual intervention"
            break
        fi
        sleep 1
    done

    # Step 5: Re-register as Citus coordinator
    log "Re-registering as Citus coordinator host..."
    pg_local_query "SELECT citus_set_coordinator_host('$(hostname)', 5432);" 2>/dev/null || \
        log "WARNING: Could not re-register coordinator host"

    log "=== FAILOVER COMPLETE ==="
    return 0
}

# ---------------------------------------------------------------------------
# PRIMARY mode: assign VIP and monitor
# ---------------------------------------------------------------------------
run_primary_monitor() {
    log "Starting in PRIMARY mode (ip=$MY_IP)"
    assign_vip

    while true; do
        sleep "$CHECK_INTERVAL"

        # Verify VIP is still on us
        if ! ip addr show eth0 | grep -q "$VIP"; then
            log "WARNING: VIP disappeared, re-assigning..."
            assign_vip
        fi
    done
}

# ---------------------------------------------------------------------------
# STANDBY mode: poll primary, failover if unreachable
# ---------------------------------------------------------------------------
run_standby_monitor() {
    log "Starting in STANDBY mode (ip=$MY_IP, monitoring primary=$PRIMARY_IP)"
    local fail_count=0
    local promoted=false

    while true; do
        sleep "$CHECK_INTERVAL"

        if [ "$promoted" = "true" ]; then
            # We've been promoted — just maintain VIP
            if ! ip addr show eth0 | grep -q "$VIP"; then
                log "WARNING: VIP disappeared after promotion, re-assigning..."
                assign_vip
            fi
            continue
        fi

        # Check primary health via pg_isready
        if pg_isready -h "$PRIMARY_IP" -p 5432 -U "$PG_USER" -t 2 >/dev/null 2>&1; then
            # Primary is alive
            if [ "$fail_count" -gt 0 ]; then
                log "Primary recovered after $fail_count failure(s)"
            fi
            fail_count=0
        else
            fail_count=$((fail_count + 1))
            log "Primary unreachable (failure $fail_count/$FAILOVER_THRESHOLD)"

            if [ "$fail_count" -ge "$FAILOVER_THRESHOLD" ]; then
                log "Primary has been down for $fail_count consecutive checks — initiating failover!"

                # Double-check: is our local PG still running?
                if ! pg_isready -h 127.0.0.1 -p 5432 -U "$PG_USER" -t 2 >/dev/null 2>&1; then
                    log "ERROR: Local PG is also down — cannot failover"
                    fail_count=0
                    continue
                fi

                promote_standby
                promoted=true
                log "Failover monitor entering maintenance mode (promoted)"
            fi
        fi
    done
}

# =============================================================================
# Main
# =============================================================================
log "============================================"
log "Failover monitor starting"
log "  MY_IP=$MY_IP"
log "  VIP=$VIP"
log "  IS_PRIMARY=$IS_PRIMARY"
log "  PRIMARY_IP=$PRIMARY_IP"
log "  STANDBY_IP=$STANDBY_IP"
log "  CHECK_INTERVAL=${CHECK_INTERVAL}s"
log "  FAILOVER_THRESHOLD=$FAILOVER_THRESHOLD"
log "============================================"

if [ "$IS_PRIMARY" = "true" ]; then
    run_primary_monitor
else
    run_standby_monitor
fi
