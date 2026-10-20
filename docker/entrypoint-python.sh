#!/usr/bin/env bash
# A webserver and the Python app server in one container, like entrypoint-webserver-fpm.sh:
# one server tree per runtime is what the perf sampler sums, so nginx and gunicorn/uvicorn
# must share a cgroup. APP_SERVER is "gunicorn" or "uvicorn"; APP_MODULE is the import path.
set -eu

app_server=${APP_SERVER:-gunicorn}
app_module=${APP_MODULE:-wsgi:application}
app_port=${APP_PORT:-8000}
workers=${APP_PROCS:-20}

cd /app/py

case "$app_server" in
    gunicorn)
        gunicorn --bind "127.0.0.1:$app_port" --workers "$workers" \
            --worker-class sync --access-logfile - --error-logfile - "$app_module" &
        ;;
    uvicorn)
        uvicorn --host 127.0.0.1 --port "$app_port" --workers "$workers" \
            --log-level warning "$app_module" &
        ;;
    *)
        echo "unknown APP_SERVER: $app_server" >&2
        exit 1
        ;;
esac
app_pid=$!

nginx -g 'daemon off;' &
ws_pid=$!

trap 'kill -TERM "$app_pid" "$ws_pid" 2>/dev/null || true' INT TERM
wait -n "$app_pid" "$ws_pid"
