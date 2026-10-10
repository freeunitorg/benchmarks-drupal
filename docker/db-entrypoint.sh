#!/usr/bin/env bash
# db-entrypoint.sh -- start the MariaDB, PostgreSQL or no server at all, chosen by DB.
#
# The benchmark's contract with the application: the database answers on host
# `db` (the container's network alias) with database `drupal`, user `root` with
# an empty password for MariaDB and `postgres` with trust auth for PostgreSQL.
# One data volume holds both: /var/lib/bench-db/mysql and /var/lib/bench-db/postgres.
set -euo pipefail

DB=${DB:-mysql}
DATA=${BENCH_DB_DATA:-/var/lib/bench-db}

wait_for() {  # command, seconds
    local cmd=$1 n=${2:-60} i
    for i in $(seq "$n"); do
        sh -c "$cmd" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

case "$DB" in
mysql|mysqli)
    dir="$DATA/mysql"
    mkdir -p "$dir"
    if [ ! -d "$dir/mysql" ]; then
        mariadb-install-db --user=mysql --datadir="$dir" --auth-root-authentication-method=normal >/dev/null
    fi
    # mariadbd needs its runtime directory, and the official image's entrypoint
    # does the same setup step.
    mkdir -p /run/mysqld
    chown mysql:mysql /run/mysqld "$dir"
    mariadbd --user=mysql --datadir="$dir" --bind-address=0.0.0.0 --port=3306 \
        --socket=/run/mysqld/mysqld.sock --pid-file=/run/mysqld/mysqld.pid --skip-name-resolve &
    wait_for "mariadb-admin --protocol=tcp -h127.0.0.1 -uroot ping" 60 || { echo "mariadb did not start" >&2; exit 1; }
    mariadb --protocol=tcp -h127.0.0.1 -uroot <<'SQL'
CREATE DATABASE IF NOT EXISTS drupal;
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
    echo "db-entrypoint: mariadb $(mariadbd --version | awk '{print $3}') on 3306"
    ;;
pgsql)
    # Debian keeps initdb/postgres under the versioned bindir, off PATH.
    PGBIN=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)
    [ -n "$PGBIN" ] || { echo "no PostgreSQL server binaries in the image" >&2; exit 1; }
    dir="$DATA/postgres"
    mkdir -p "$dir"
    chown postgres:postgres "$dir"
    if [ ! -d "$dir/base" ]; then
        su postgres -c "$PGBIN/initdb -D '$dir' --auth=trust" >/dev/null
    fi
    su postgres -c "$PGBIN/postgres -D '$dir' -c listen_addresses='*' -c port=5432" &
    wait_for "pg_isready -h 127.0.0.1 -p 5432 -U postgres" 60 || { echo "postgres did not start" >&2; exit 1; }
    su postgres -c "psql -h 127.0.0.1 -U postgres -tAc \"SELECT 1 FROM pg_database WHERE datname='drupal'\"" | grep -q 1 \
        || su postgres -c "createdb -h 127.0.0.1 -U postgres drupal"
    echo "db-entrypoint: $("$PGBIN/postgres" --version) on 5432"
    ;;
sqlite)
    echo "db-entrypoint: sqlite $(sqlite3 --version | awk '{print $1}'), no server to run"
    ;;
*)
    echo "db-entrypoint: unknown DB '$DB' (mysql, mysqli, pgsql, sqlite)" >&2
    exit 2
    ;;
esac

# Keep the container alive and forward signals to the server (pid 1 is this shell).
trap 'kill 0' TERM INT
while true; do sleep 3600 & wait $!; done
