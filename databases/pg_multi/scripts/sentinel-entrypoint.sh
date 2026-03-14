#!/bin/bash
# Entrypoint for Valkey Sentinel containers
# Copies the sentinel config template to a writable location, substitutes
# environment variables, then starts the sentinel.
set -e

CONF_SRC="${SENTINEL_CONF_SRC:-/etc/valkey/sentinel-template.conf}"
CONF_DST="/data/sentinel.conf"

# Copy template to writable location
cp "$CONF_SRC" "$CONF_DST"

# Substitute password
sed -i "s|\${VALKEY_PASSWORD}|${VALKEY_PASSWORD}|g" "$CONF_DST"

exec valkey-sentinel "$CONF_DST"
