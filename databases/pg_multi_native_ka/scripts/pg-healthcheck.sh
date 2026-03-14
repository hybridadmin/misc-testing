#!/bin/bash
# PostgreSQL health check for multi-master nodes
set -e
pg_isready -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-postgres}" -q
