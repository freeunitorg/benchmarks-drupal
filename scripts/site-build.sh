#!/bin/bash
# site-build.sh -- build and install one application for the benchmark, on the perf host.
#
#   scripts/site-build.sh <site> [RUNROOT] [--force]
#
# Sites:
#   11.4           Drupal 11.4.8, demo_umami
#   11.4-standard  Drupal 11.4.8, standard
#   12.0           Drupal 12.0.0-beta1, demo_umami
#   12.0-standard  Drupal 12.0.0-beta1, standard
#
# drush is installed when the site's composer graph allows it (Drupal 11.4). Drupal
# 12 pins guzzle 8 while drush 13 needs guzzle ^7, and the advisory policy blocks
# every 7.x, so the 12.x sites are driven by apps/drupal_cli.php instead: core's own
# installer plus the Drupal APIs for enable/state/user/login/cron/queue.
#
# Everything that writes into the site runs in a container as root, so a rebuild
# wipes through a container. Records $RUNROOT/site/<site>/meta.txt.
set -euo pipefail

SITE=${1:?usage: site-build.sh <11.4|11.4-standard|12.0|12.0-standard> [RUNROOT] [--force]}
RUNROOT=${2:-/data/projects/benchmarks-drupal/run}
FORCE=${3:-}
TOOL_IMAGE=${TOOL_IMAGE:-drupal-bench-freeunit:1.37.0}
DB_IMAGE=${DB_IMAGE:-mariadb:10.11}
PORT=${PORT:-8081}
NET="dbnet-sitebuild-$$"
DBC="db-sitebuild-$$"
RTC="rt-sitebuild-$$"
# DB selects the backend: mysql (PDO, default), mysqli (the experimental core
# driver), pgsql or sqlite. mysql keeps the bare site key so existing runs and
# paths stay valid; every other backend gets its own directory and volume.
DB=${DB:-mysql}
SITEKEY=$SITE
[ "$DB" != mysql ] && SITEKEY="$SITE-$DB"
SITEDIR="$RUNROOT/site/$SITEKEY"
REPO=$(cd "$(dirname "$0")/.." && pwd)
BENCH_USER=bench-user
BENCH_PASS=bench-pass
DBCVOL=${DBCVOL:-drupal-bench-db-$SITEKEY}

case "$SITE" in
11.4)          DRUPAL_TAG=drupal/recommended-project:11.4.8;        PROFILE=demo_umami ;;
11.4-standard) DRUPAL_TAG=drupal/recommended-project:11.4.8;        PROFILE=standard ;;
12.0)          DRUPAL_TAG=drupal/recommended-project:12.0.0-beta1; PROFILE=demo_umami ;;
12.0-standard) DRUPAL_TAG=drupal/recommended-project:12.0.0-beta1; PROFILE=standard ;;
*) echo "site-build: unknown site $SITE" >&2; exit 2 ;;
esac

cleanup() {
    docker rm -f "$DBC" "$RTC" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# composer create-project leaves web/index.php before the install runs; installed
# means the completed meta.txt and a database block in settings.php.
site_installed() {
    [ -f "$SITEDIR/meta.txt" ] && grep -q '^tag=' "$SITEDIR/meta.txt" 2>/dev/null \
        && [ -f "$SITEDIR/web/sites/default/settings.php" ] \
        && grep -q "databases\['default'\]\['default'\]" "$SITEDIR/web/sites/default/settings.php" 2>/dev/null
}
if site_installed && [ "$FORCE" != "--force" ]; then
    echo "site-build: $SITEDIR already installed (use --force to rebuild)"
    exit 0
fi
if { [ "$FORCE" = "--force" ] || [ -d "$SITEDIR" ]; } && ! site_installed; then
    echo "site-build: removing incomplete $SITEDIR"
    docker run --rm -v "$RUNROOT:/run" alpine:3 sh -c "rm -rf /run/site/$SITEKEY"
fi
mkdir -p "$SITEDIR" "$RUNROOT/cache/composer"

docker network create "$NET" >/dev/null
if [ "${DB}" = sqlite ]; then
    # no server: the database is a file under the site files directory
    DB_URL="sqlite://localhost/sites/default/files/.sqlite"
elif [ -n "${DBC_IMAGE:-}" ]; then
    # one image that can be any server; the entrypoint reads DB
    case "$DB" in
    pgsql) DB_URL="pgsql://postgres@db/drupal" ;;
    mysql|mysqli) DB_URL="mysql://root@db/drupal" ;;
    *) echo "site-build: unknown DB $DB (mysql, mysqli, pgsql, sqlite)" >&2; exit 2 ;;
    esac
    docker run -d --name "$DBC" --network "$NET" --network-alias db \
        -v "$DBCVOL:/var/lib/bench-db" -e DB="$DB" "$DBC_IMAGE" >/dev/null
    for _ in $(seq 90); do
        if [ "$DB" = pgsql ]; then
            docker exec "$DBC" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && break
        else
            docker exec "$DBC" mariadb-admin --protocol=tcp -h127.0.0.1 -uroot ping >/dev/null 2>&1 && break
        fi
        sleep 1
    done
    if [ "$DB" != pgsql ]; then
        docker exec "$DBC" mariadb --protocol=tcp -h127.0.0.1 -uroot -e "DROP DATABASE IF EXISTS drupal; CREATE DATABASE drupal;" 2>/dev/null || true
    fi
elif [ "${DB}" = pgsql ]; then
    DB_URL="pgsql://postgres@db/drupal"
    docker run -d --name "$DBC" --network "$NET" --network-alias db \
        -v "$DBCVOL:/var/lib/postgresql/data" \
        -e POSTGRES_DB=drupal -e POSTGRES_HOST_AUTH_METHOD=trust \
        "${PG_IMAGE:-postgres:17}" >/dev/null
    for _ in $(seq 60); do
        docker exec "$DBC" pg_isready -U postgres -d drupal >/dev/null 2>&1 && break
        sleep 1
    done
elif [ "${DB}" = mysql ] || [ "${DB}" = mysqli ]; then
    DB_URL="mysql://root@db/drupal"
    docker run -d --name "$DBC" --network "$NET" --network-alias db \
        -v "$DBCVOL:/var/lib/mysql" \
        -e MARIADB_ROOT_HOST=% -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=drupal \
        "$DB_IMAGE" >/dev/null
    for _ in $(seq 60); do
        docker exec "$DBC" mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1 && break
        sleep 1
    done
    # a rebuild starts from an empty database
    docker exec "$DBC" mariadb -uroot -e "DROP DATABASE IF EXISTS drupal; CREATE DATABASE drupal;" 2>/dev/null || true
else
    echo "site-build: unknown DB $DB (mysql, mysqli, pgsql, sqlite)" >&2
    exit 2
fi

echo "site-build: $SITE [$DB] -> $DRUPAL_TAG ($PROFILE)"
docker run --rm --network "$NET" \
    -v "$RUNROOT:/run" -v "$REPO/modules:/run/modules-src:ro" -v "$REPO/apps:/run/apps-src:ro" \
    -v "$RUNROOT/cache/composer:/cache" -w /run -e HOME=/root -e COMPOSER_HOME=/cache \
    -e DB_URL="$DB_URL" -e DB_DRIVER="$DB" -e SITE_PASS=admin -e SITE_NAME="FreeUnit benchmark" \
    "$TOOL_IMAGE" sh -euc "
        if [ ! -f /run/site/$SITEKEY/composer.json ]; then
            composer create-project $DRUPAL_TAG /run/site/$SITEKEY --no-interaction --no-progress
        fi
        cd /run/site/$SITEKEY
        mkdir -p web/modules/custom
        cp -r /run/modules-src/fu_queue_test web/modules/custom/
        chmod u+w web/sites/default
        HAS_DRUSH=1
        composer require --no-interaction --no-progress drush/drush:^13 >/dev/null 2>&1 || HAS_DRUSH=0
        # drush cannot install the mysqli driver and its db-url handling differs per
        # backend, so anything but mysql goes through settings-init + dr/install_drupal.
        [ "$DB" != mysql ] && HAS_DRUSH=0
        if [ \"\$HAS_DRUSH\" = 1 ]; then
            ./vendor/bin/drush site:install $PROFILE \
                --db-url=mysql://root@db/drupal \
                --account-name=admin --account-pass=admin \
                --site-name='FreeUnit benchmark' --yes
            ./vendor/bin/drush pm:enable fu_queue_test page_cache dynamic_page_cache --yes
            ./vendor/bin/drush pm:uninstall big_pipe --yes || true
            ./vendor/bin/drush sset fu_queue_test.key benchmark
            ./vendor/bin/drush user:create $BENCH_USER --password=$BENCH_PASS --mail=$BENCH_USER@example.com || true
            ./vendor/bin/drush role:assign authenticated $BENCH_USER || true
            ./vendor/bin/drush cr
            drupal=\$(./vendor/bin/drush status --field=drupal-version)
            # Drupal 12 ships vendor/bin/dr (drupal/core "bin": scripts/dr). Its
            # install command hardcodes SQLite, so settings-init writes a valid
            # connection and hash salt first; the installer then skips its settings
            # form and installs into MariaDB.
            CLI="DRUPAL_ROOT=$PWD/web php /run/apps-src/drupal_cli.php"
            $CLI settings-init
            if [ -x vendor/bin/dr ]; then
                php vendor/bin/dr install $PROFILE --site-name='FreeUnit benchmark' --password=$SITE_PASS
                php vendor/bin/dr cache:rebuild
            else
                $CLI install $PROFILE
                $CLI cache-rebuild
            fi
            # The module must be enabled before dr can see its bench command.
            $CLI enable fu_queue_test page_cache dynamic_page_cache
            $CLI disable big_pipe || true
            # dr sees the module's bench command because enabling it rebuilt the
            # container; each call falls back to the standalone CLI.
            if [ -x vendor/bin/dr ]; then
                php vendor/bin/dr bench state-set fu_queue_test.key benchmark || $CLI state-set fu_queue_test.key benchmark
                php vendor/bin/dr bench user-create $BENCH_USER $BENCH_PASS || $CLI user-create $BENCH_USER $BENCH_PASS
            else
                $CLI state-set fu_queue_test.key benchmark
                $CLI user-create $BENCH_USER $BENCH_PASS
            fi
            drupal=\$(php -r 'require "core/lib/Drupal.php"; echo \\Drupal::VERSION;' 2>/dev/null || echo unknown)
        printf '\n\$settings[\"trusted_host_patterns\"] = [\".*\"];\n' >> web/sites/default/settings.php
        phpv=\$(php -r 'echo PHP_VERSION;')
        echo \"tag=$DRUPAL_TAG drupal=\$drupal php=\$phpv profile=$PROFILE drush=\$HAS_DRUSH\" > /run/site/$SITEKEY/meta.txt
    "

echo "site-build: login cookie for the drupal-auth workload"
docker run -d --name "$RTC" --network "$NET" -p "127.0.0.1:$PORT:80" \
    -v "$SITEDIR:/app" -v "$RUNROOT/runtimes/freeunit.json:/docker-entrypoint.d/config.json:ro" \
    "$TOOL_IMAGE" >/dev/null
for _ in $(seq 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)" = 200 ] && break
    sleep 1
done
LOGIN_URL=$(docker run --rm --network "$NET" \
    -e HOME=/root -e COMPOSER_HOME=/cache -v "$RUNROOT/cache/composer:/cache" \
    -v "$SITEDIR:/app" -v "$REPO/apps:/run/apps-src:ro" -w /app "$TOOL_IMAGE" sh -c '
        if [ -x ./vendor/bin/drush ]; then
            ./vendor/bin/drush --no-ansi user:login --name='"$BENCH_USER"' --uri=http://127.0.0.1:'"$PORT"' 2>/dev/null
        elif [ -x ./vendor/bin/dr ]; then
            php ./vendor/bin/dr bench login-url '"$BENCH_USER"' 2>/dev/null
        else
            DRUPAL_ROOT=/app/web php /run/apps-src/drupal_cli.php login-url '"$BENCH_USER"'
        fi' | tr -d '\r' | grep -o 'http://[^" ]*' | head -1)
if [ -n "$LOGIN_URL" ]; then
    curl -s -c "$SITEDIR/cookie.txt" -o /dev/null -L "$LOGIN_URL"
    COOKIE=$(awk '($1 ~ /^#HttpOnly_/ || $1 !~ /^#/) && NF >= 7 { printf "%s=%s; ", $6, $7 }' "$SITEDIR/cookie.txt")
    hdrs=$(curl -s -D - -o /dev/null -H "Cookie: $COOKIE" "http://127.0.0.1:$PORT/")
    if printf '%s' "$hdrs" | grep -qi '^x-drupal-dynamic-cache:'; then
        echo "site-build: auth cookie verified (dynamic cache header present)" | tee -a "$SITEDIR/meta.txt"
    else
        echo "site-build: WARNING auth cookie did not reach the render path" | tee -a "$SITEDIR/meta.txt"
    fi
else
    echo "site-build: WARNING no login link; drupal-auth cannot run" | tee -a "$SITEDIR/meta.txt"
fi
chown -R "$(id -u):$(id -g)" "$SITEDIR" 2>/dev/null || true
cat >> "$SITEDIR/meta.txt" <<EOF
site=$SITE
runroot=$RUNROOT
installed=$(date -u +%FT%TZ)
user=$BENCH_USER
EOF
echo "site-build: done -> $SITEDIR"
