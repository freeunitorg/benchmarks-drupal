#!/bin/bash
# site-build.sh -- build and install one application for the benchmark, on the perf host.
#
#   scripts/site-build.sh 11.4    [RUNROOT] [--force]
#   scripts/site-build.sh 12.0    [RUNROOT] [--force]
#
# 11.4 / 12.0: drupal/recommended-project at the pinned tag, demo_umami profile,
# fu_queue_test enabled, big_pipe uninstalled, cron+queue keys set, project-local
# drush (recommended-project does not ship one), authenticated benchmark user and
# its session cookie for the drupal-auth workload.
#
# Everything that writes into the site runs in a container as root, so host-side
# rm is refused: --force wipes through a container instead.
#
# Records $RUNROOT/site/<site>/meta.txt: tag, Drupal version, PHP, cookie check.
set -euo pipefail

SITE=${1:?usage: site-build.sh <11.4|12.0> [RUNROOT] [--force]}
RUNROOT=${2:-/data/projects/benchmarks-drupal/run}
FORCE=${3:-}
TOOL_IMAGE=${TOOL_IMAGE:-drupal-bench-freeunit:1.37.0}
DB_IMAGE=${DB_IMAGE:-mariadb:10.11}
PORT=${PORT:-8081}
NET="dbnet-sitebuild-$$"
DBC="db-sitebuild-$$"
RTC="rt-sitebuild-$$"
SITEDIR="$RUNROOT/site/$SITE"
REPO=$(cd "$(dirname "$0")/.." && pwd)
BENCH_USER=bench-user
BENCH_PASS=bench-pass

case "$SITE" in
11.4) DRUPAL_TAG=drupal/recommended-project:11.4.8 ;;
12.0) DRUPAL_TAG=drupal/recommended-project:12.0.0-beta1 ;;
*) echo "site-build: unknown site $SITE" >&2; exit 2 ;;
esac

cleanup() {
    docker rm -f "$DBC" "$RTC" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# composer create-project leaves web/index.php behind before the install runs, so
# the marker for "installed" is the completed install (meta.txt with the tag plus
# a database block in settings.php), never the presence of the webroot.
site_installed() {
    [ -f "$SITEDIR/meta.txt" ] && grep -q '^tag=' "$SITEDIR/meta.txt" 2>/dev/null \
        && [ -f "$SITEDIR/web/sites/default/settings.php" ] \
        && grep -q "databases\['default'\]\['default'\]" "$SITEDIR/web/sites/default/settings.php" 2>/dev/null
}
if site_installed && [ "$FORCE" != "--force" ]; then
    echo "site-build: $SITEDIR already installed (use --force to rebuild)"
    exit 0
fi
# An incomplete tree (create-project without a finished install) is rebuilt, not
# reused: the host user cannot delete root-owned files, so wipe through a container.
if [ "$FORCE" = "--force" ] && [ -d "$SITEDIR" ]; then
    docker run --rm -v "$RUNROOT:/run" alpine:3 sh -c "rm -rf /run/site/$SITE"
elif [ -d "$SITEDIR" ] && ! site_installed; then
    echo "site-build: removing incomplete $SITEDIR"
    docker run --rm -v "$RUNROOT:/run" alpine:3 sh -c "rm -rf /run/site/$SITE"
fi
mkdir -p "$SITEDIR" "$RUNROOT/cache/composer"

docker network create "$NET" >/dev/null
DBCVOL=${DBCVOL:-drupal-bench-db-$SITE}
docker run -d --name "$DBC" --network "$NET" --network-alias db \
    -v "$DBCVOL:/var/lib/mysql" \
    -e MARIADB_ROOT_HOST=% -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=drupal \
    "$DB_IMAGE" >/dev/null
for _ in $(seq 60); do
    docker exec "$DBC" mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
done

# A rebuild starts from an empty database: a partial install leaves tables that
# make drush site:install refuse.
docker exec "$DBC" mariadb -uroot -e "DROP DATABASE IF EXISTS drupal; CREATE DATABASE drupal;" 2>/dev/null || true

echo "site-build: composer create-project $DRUPAL_TAG -> $SITEDIR"
docker run --rm --network "$NET" \
    -v "$RUNROOT:/run" -v "$REPO/modules:/run/modules-src:ro" -v "$RUNROOT/cache/composer:/cache" \
    -w /run -e HOME=/root -e COMPOSER_HOME=/cache \
    "$TOOL_IMAGE" sh -euc "
        if [ ! -f /run/site/$SITE/composer.json ]; then
            composer create-project $DRUPAL_TAG /run/site/$SITE --no-interaction --no-progress
        fi
        cd /run/site/$SITE
        composer require --no-interaction --no-progress drush/drush:^13
        mkdir -p web/modules/custom
        cp -r /run/modules-src/fu_queue_test web/modules/custom/
        chmod u+w web/sites/default
        ./vendor/bin/drush site:install demo_umami \
            --db-url=mysql://root@db/drupal \
            --account-name=admin --account-pass=admin \
            --site-name='FreeUnit benchmark' --yes
        ./vendor/bin/drush pm:enable fu_queue_test --yes
        ./vendor/bin/drush pm:uninstall big_pipe --yes || true
        ./vendor/bin/drush sset fu_queue_test.key benchmark
        ./vendor/bin/drush user:create $BENCH_USER --password=$BENCH_PASS --mail=$BENCH_USER@example.com || true
        ./vendor/bin/drush role:assign authenticated $BENCH_USER || true
        printf '\n\$settings[\"trusted_host_patterns\"] = [\".*\"];\n' >> web/sites/default/settings.php
        ./vendor/bin/drush cr
        drupal=\$(./vendor/bin/drush status --field=drupal-version)
        phpv=\$(php -r 'echo PHP_VERSION;')
        echo \"tag=$DRUPAL_TAG drupal=\$drupal php=\$phpv\" > /run/site/$SITE/meta.txt
    "

chown -R "$(id -u):$(id -g)" "$SITEDIR" 2>/dev/null || true
echo "site-build: login cookie for the drupal-auth workload"
docker run -d --name "$RTC" --network "$NET" -p "127.0.0.1:$PORT:80" \
    -v "$SITEDIR:/app" -v "$RUNROOT/runtimes/freeunit.json:/docker-entrypoint.d/config.json:ro" \
    "$TOOL_IMAGE" >/dev/null
for i in $(seq 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)" = 200 ] && break
    sleep 1
done
LOGIN_URL=$(docker run --rm --network "$NET" \
    -e HOME=/root -e COMPOSER_HOME=/cache -v "$RUNROOT/cache/composer:/cache" \
    -v "$SITEDIR:/app" -w /app "$TOOL_IMAGE" \
    sh -c "./vendor/bin/drush --no-ansi user:login --name=$BENCH_USER --uri=http://127.0.0.1:$PORT 2>/dev/null" \
    | tr -d '\r' | grep -o 'http://[^ ]*' | head -1)
if [ -n "$LOGIN_URL" ]; then
    curl -s -c "$SITEDIR/cookie.txt" -o /dev/null "$LOGIN_URL"
    COOKIE=$(awk 'NF >= 7 && $6 != "" {print $6"="$7}' "$SITEDIR/cookie.txt" | paste -sd'; ')
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $COOKIE" "http://127.0.0.1:$PORT/")
    echo "site-build: auth cookie code=$code" | tee -a "$SITEDIR/meta.txt"
else
    echo "site-build: WARNING no login link; drupal-auth cannot run" | tee -a "$SITEDIR/meta.txt"
fi
cat >> "$SITEDIR/meta.txt" <<EOF
site=$SITE
runroot=$RUNROOT
installed=$(date -u +%FT%TZ)
user=$BENCH_USER
EOF
echo "site-build: done -> $SITEDIR"
