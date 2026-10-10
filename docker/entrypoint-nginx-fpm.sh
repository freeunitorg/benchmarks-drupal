#!/usr/bin/env bash
# nginx + php-fpm in one container (plan section 5.3: one server tree per runtime).
set -eu
php-fpm --nodaemonize --fpm-config /usr/local/etc/php-fpm.conf &
fpm_pid=$!
trap 'kill -TERM "$fpm_pid" 2>/dev/null || true' INT TERM
nginx -g 'daemon off;' &
nginx_pid=$!
wait -n "$fpm_pid" "$nginx_pid"
