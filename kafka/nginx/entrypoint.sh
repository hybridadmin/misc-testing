#!/usr/bin/env bash
###############################################################################
# Entrypoint — runs Nginx as PID 1, with Filebeat as a background sidecar.
#
# - The script performs setup, launches Filebeat, then exec's nginx so that
#   nginx becomes PID 1 and receives Docker signals (SIGTERM, SIGQUIT)
#   directly.
# - A lightweight monitor watches Filebeat in the background; if Filebeat
#   exits unexpectedly, it sends SIGQUIT to PID 1 (nginx) so the container
#   stops and Docker's restart policy kicks in.
###############################################################################
set -euo pipefail

# --------------------------------------------------------------------------
# 1. Fix log files — the base image symlinks them to /dev/stdout which
#    Filebeat cannot tail.
# --------------------------------------------------------------------------
rm -f /var/log/nginx/access.log /var/log/nginx/error.log
touch /var/log/nginx/access.log /var/log/nginx/error.log

# --------------------------------------------------------------------------
# 2. Start Filebeat in the background
# --------------------------------------------------------------------------
echo "[entrypoint] starting filebeat..."
filebeat -e --strict.perms=false -c /etc/filebeat/filebeat.yml &
FILEBEAT_PID=$!

# --------------------------------------------------------------------------
# 3. Filebeat watchdog — if filebeat dies, tell nginx (PID 1) to quit
# --------------------------------------------------------------------------
(
    while kill -0 "$FILEBEAT_PID" 2>/dev/null; do
        sleep 5
    done
    echo "[watchdog] filebeat (PID $FILEBEAT_PID) exited, stopping nginx..."
    kill -s QUIT 1 2>/dev/null || true
) &

# --------------------------------------------------------------------------
# 4. Replace this shell with nginx — nginx becomes PID 1
# --------------------------------------------------------------------------
echo "[entrypoint] exec'ing nginx as PID 1..."
exec nginx -g 'daemon off;'
