#!/bin/sh
# FreeUnit entrypoint: install the config on first start, then exec unitd.
# The 1.37.0 tree has no pkg/docker entrypoint, so this is the 20-line equivalent.
set -eu
CONFIG=${UNIT_CONFIG:-/docker-entrypoint.d/config.json}
RUNTIME_CONFIG=/var/lib/unit/conf.json
if [ ! -f "$RUNTIME_CONFIG" ]; then
    cp "$CONFIG" "$RUNTIME_CONFIG"
fi
exec "$@"
