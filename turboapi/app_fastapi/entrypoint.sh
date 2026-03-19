#!/bin/bash
set -e

ACCESS_LOG_FLAG=""
if [ "${UVICORN_ACCESS_LOG:-false}" = "true" ]; then
    ACCESS_LOG_FLAG="--access-log"
fi

MAX_REQUESTS_FLAG=""
if [ -n "${UVICORN_LIMIT_MAX_REQUESTS}" ] && [ "${UVICORN_LIMIT_MAX_REQUESTS}" != "0" ]; then
    MAX_REQUESTS_FLAG="--limit-max-requests ${UVICORN_LIMIT_MAX_REQUESTS}"
fi

echo "Starting FastAPI with configuration:"
echo "  Workers: ${UVICORN_WORKERS:-4}"
echo "  Host: ${UVICORN_HOST:-0.0.0.0}"
echo "  Port: ${UVICORN_PORT:-8001}"
echo "  Timeout: ${UVICORN_TIMEOUT_KEEP_ALIVE:-65}s"
echo "  Concurrency: ${UVICORN_LIMIT_CONCURRENCY:-1000}"
echo "  Max Requests: ${UVICORN_LIMIT_MAX_REQUESTS:-0} (0=disabled)"
echo "  Access Log: ${UVICORN_ACCESS_LOG:-false}"

exec python -m uvicorn main:app \
    --host "${UVICORN_HOST:-0.0.0.0}" \
    --port "${UVICORN_PORT:-8001}" \
    --workers "${UVICORN_WORKERS:-4}" \
    --timeout-keep-alive "${UVICORN_TIMEOUT_KEEP_ALIVE:-65}" \
    --limit-concurrency "${UVICORN_LIMIT_CONCURRENCY:-1000}" \
    $MAX_REQUESTS_FLAG \
    $ACCESS_LOG_FLAG
