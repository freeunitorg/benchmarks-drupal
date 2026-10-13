#!/bin/sh
# Assemble the main configuration for a webserver built from source: the shared
# head (worker/events/http directives) plus that server's server block.
#
#   install-ws-conf.sh NAME PREFIX BIN
set -eu

name=$1
prefix=$2
bin=$3

{
    cat /tmp/ws-main-head.conf
    cat "/tmp/server-$name.conf"
    echo '}'
} > "$prefix/conf/nginx.conf"

# Fail the image build on a broken config instead of on the first request.
"$prefix/sbin/$bin" -t -c "$prefix/conf/nginx.conf" 2>&1 | tail -n 2
