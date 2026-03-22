#!/bin/bash
set -e

# Start the background launcher for Barman
/usr/local/bin/barman-launcher.sh &

# Fallback to the official PostgreSQL entrypoint
exec docker-entrypoint.sh "$@"
