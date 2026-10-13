#!/bin/sh
# Assemble the main configuration for a webserver built from source: the shared
# head (worker/events/http directives) plus that server's server block.
#
#   install-ws-conf.sh NAME PREFIX
set -eu

name=$1
prefix=$2

{
    cat /tmp/ws-main-head.conf
    cat "/tmp/server-$name.conf"
    echo '}'
} > "$prefix/conf/nginx.conf"

"$prefix/sbin/"* -t -c "$prefix/conf/nginx.conf" 2>&1 | head -n 2 || true
