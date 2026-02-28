#!/bin/sh
set -e

UVICORN_WORKERS="${UVICORN_WORKERS:-2}"
UVICORN_LOG_LEVEL="${UVICORN_LOG_LEVEL:-info}"

echo "Starting Uvicorn (workers=${UVICORN_WORKERS}, log_level=${UVICORN_LOG_LEVEL}) on port 8000..."
uvicorn app.main:app \
  --host 0.0.0.0 \
  --port 8000 \
  --workers "${UVICORN_WORKERS}" \
  --log-level "${UVICORN_LOG_LEVEL}" &

echo "Starting Nginx..."
exec nginx -g "daemon off;"
