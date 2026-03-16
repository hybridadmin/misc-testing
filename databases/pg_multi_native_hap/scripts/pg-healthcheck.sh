#!/bin/bash
# PostgreSQL health check for multi-master nodes
# Returns 0 if PG is accepting connections
set -e
pg_isready -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-postgres}" -q
