#!/bin/sh
# =============================================================================
# PostgreSQL Initialization Script
# =============================================================================
# Runs once when the data volume is first initialized.
# Creates recommended extensions for Forgejo.
# =============================================================================

set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Enable useful extensions
    CREATE EXTENSION IF NOT EXISTS pg_trgm;

    -- Optimize for Forgejo query patterns
    ALTER DATABASE ${POSTGRES_DB} SET default_text_search_config = 'pg_catalog.english';

    -- Ensure UTF-8
    ALTER DATABASE ${POSTGRES_DB} SET client_encoding = 'UTF8';
EOSQL

echo "[initdb] PostgreSQL extensions configured for Forgejo."
