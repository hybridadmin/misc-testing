#!/bin/bash
# Entrypoint for Valkey Sentinel containers
set -e

CONF_SRC="${SENTINEL_CONF_SRC:-/etc/valkey/sentinel-template.conf}"
CONF_DST="/data/sentinel.conf"

cp "$CONF_SRC" "$CONF_DST"
sed -i "s|\${VALKEY_PASSWORD}|${VALKEY_PASSWORD}|g" "$CONF_DST"

exec valkey-sentinel "$CONF_DST"
