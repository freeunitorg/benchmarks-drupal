#!/usr/bin/env bash
# A webserver and php-fpm in one container, for the runtimes built from upstream
# tarballs (nginx, Angie, FreeNginx).  One server tree per runtime is what the
# perf sampler sums (plan section 5.3), so the pair must share a cgroup.
#
# WEBSERVER_BIN  absolute path to the server binary (default: nginx on PATH)
# WEBSERVER_CONF main configuration to pass with -c (optional)
set -eu

ws_bin=${WEBSERVER_BIN:-nginx}
ws_conf=${WEBSERVER_CONF:-}

php-fpm --nodaemonize --fpm-config /usr/local/etc/php-fpm.conf &
fpm_pid=$!
trap 'kill -TERM "$fpm_pid" 2>/dev/null || true' INT TERM

# shellcheck disable=SC2086
"$ws_bin" ${ws_conf:+-c "$ws_conf"} -g 'daemon off;' &
ws_pid=$!

wait -n "$fpm_pid" "$ws_pid"
