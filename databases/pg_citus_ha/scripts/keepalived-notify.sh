#!/bin/bash
# =============================================================================
# Keepalived Notify Script for Citus Coordinator HA
# =============================================================================
# Called by keepalived when this node's VRRP state changes:
#   MASTER — we got the VIP (promote if standby)
#   BACKUP — we lost the VIP
#   FAULT  — health check failing
#
# Usage in keepalived.conf:
#   notify /usr/local/bin/keepalived-notify.sh
# =============================================================================

LOG_FILE="/tmp/keepalived-notify.log"
PG_USER="${POSTGRES_USER:-postgres}"
PG_PASS="${POSTGRES_PASSWORD:-changeme_postgres_2025}"
PG_DB="${POSTGRES_DB:-appdb}"
PGDATA="${PGDATA:-/var/lib/postgresql/18/docker}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [keepalived-notify] $*" | tee -a "$LOG_FILE"
}

pg_query() {
    PGPASSWORD="$PG_PASS" psql -h 127.0.0.1 -p 5432 -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null
}

TYPE=$1    # GROUP or INSTANCE
NAME=$2    # Instance name (e.g., VI_CITUS)
STATE=$3   # MASTER, BACKUP, or FAULT

log "=== State change: TYPE=$TYPE NAME=$NAME STATE=$STATE ==="

case "$STATE" in
    "MASTER")
        log "Transitioning to MASTER — checking if promotion is needed..."

        # Check if we're in recovery (= standby)
        IS_STANDBY=$(pg_query "SELECT pg_is_in_recovery();" 2>/dev/null)

        if [ "$IS_STANDBY" = "t" ]; then
            log "This node is a standby — PROMOTING to primary!"

            # Promote via SQL
            pg_query "SELECT pg_promote(true, 60);" 2>/dev/null
            PROMOTE_RESULT=$?

            if [ $PROMOTE_RESULT -eq 0 ]; then
                log "pg_promote() called successfully"

                # Wait for promotion to complete
                attempts=0
                while true; do
                    IS_STILL_STANDBY=$(pg_query "SELECT pg_is_in_recovery();" 2>/dev/null)
                    if [ "$IS_STILL_STANDBY" = "f" ]; then
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

                # Re-register as Citus coordinator
                # After promotion, this node needs to be known as the coordinator
                log "Re-registering as Citus coordinator host..."
                pg_query "SELECT citus_set_coordinator_host('coordinator-standby', 5432);" 2>/dev/null || \
                    log "WARNING: Could not re-register coordinator host"

                log "Promotion and re-registration complete"
            else
                log "ERROR: pg_promote() failed (exit=$PROMOTE_RESULT)"
            fi
        else
            log "Already primary (not in recovery) — no promotion needed"
        fi
        ;;

    "BACKUP")
        log "Transitioning to BACKUP — no action needed"
        ;;

    "FAULT")
        log "Transitioning to FAULT — health check failing"
        ;;

    *)
        log "Unknown state: $STATE"
        ;;
esac
