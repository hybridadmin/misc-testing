#!/bin/bash
set -e

echo "Starting TurboAPI v1.0 with TurboDB..."
echo "  Host: ${UVICORN_HOST:-0.0.0.0}"
echo "  Port: ${UVICORN_PORT:-8002}"

HOST="${UVICORN_HOST:-0.0.0.0}"
PORT="${UVICORN_PORT:-8002}"

export LD_PRELOAD=/usr/local/lib/libwrite_filter.so

exec /opt/python3.14t/bin/python3 -c "
import main
main.app.run(host='${HOST}', port=${PORT})
"
