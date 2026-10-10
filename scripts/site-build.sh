#!/bin/bash
# site-build.sh -- build and install one Drupal site for the benchmark, on the perf host.
#
#   scripts/site-build.sh 11.4 [RUNROOT]
#   scripts/site-build.sh 12.0 [RUNROOT]
#
# Pins the Drupal tag, installs demo_umami (decision 2c), enables fu_queue_test,
# turns off big_pipe (plan section 3.1), sets the cron key and the queue key,
# creates the authenticated benchmark user, and stores its session cookie for
# the drupal-auth workload. Records everything in $RUNROOT/site/<site>/meta.txt.
#
# Idempotent: a site whose web/index.php exists is left alone unless --force.
set -euo pipefail

SITE=${1:?usage: site-build.sh <11.4|12.0> [RUNROOT] [--force]}
RUNROOT=${2:-/data/projects/benchmarks-drupal/run}
FORCE=${3:-}
TOOL_IMAGE=${TOOL_IMAGE:-drupal-bench-freeunit:1.37.0}
DB_IMAGE=${DB_IMAGE:-mariadb:10.11}
PORT=${PORT:-8081}
NET="dbnet-sitebuild-$$"
DBC="db-sitebuild-$$"
SITEDIR="$RUNROOT/site/$SITE"
APPS_DIR="$RUNROOT/apps"
BENCH_USER=bench-user
BENCH_PASS=bench-pass

case "$SITE" in
11.4) DRUPAL_TAG=drupal/recommended-project:11.4.8 ;;
12.0) DRUPAL_TAG=drupal/recommended-project:12.0.0-beta1 ;;
*) echo "site-build: unknown site $SITE" >&2; exit 2 ;;
esac

cleanup() {
    docker rm -f "$DBC" "rt-sitebuild-$$" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$RUNROOT" "$SITEDIR" "$APPS_DIR"
cp -f "$(dirname "$0")/../docker/runtimes/freeunit.json" "$RUNROOT/runtimes/freeunit.json" 2>/dev/null || {
    mkdir -p "$RUNROOT/runtimes"
    cp -f "$(dirname "$0")/../docker/runtimes/"*.json "$RUNROOT/runtimes/"
}
cp -f "$(dirname "$0")/../apps/"* "$APPS_DIR/"
cp -rf "$(dirname "$0")/../modules/fu_queue_test" "$SITEDIR/fu_queue_test-src" 2>/dev/null || true

if [ -f "$SITEDIR/web/index.php" ] && [ "$FORCE" != "--force" ]; then
    echo "site-build: $SITEDIR already installed (use --force to rebuild)"
    exit 0
fi
rm -rf "$SITEDIR"; mkdir -p "$SITEDIR"

docker network create "$NET" >/dev/null
docker run -d --name "$DBC" --network "$NET" \
    -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=drupal \
    "$DB_IMAGE" >/dev/null
for i in $(seq 60); do
    docker exec "$DBC" mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
done

echo "site-build: composer create-project $DRUPAL_TAG -> $SITEDIR"
docker run --rm --network "$NET" -v "$RUNROOT:/run" -w /run \
    -e HOME=/root -e COMPOSER_HOME=/opt/composer \
    "$TOOL_IMAGE" sh -euc "
        if [ ! -f /run/site/$SITE/composer.json ]; then
            composer create-project $DRUPAL_TAG /run/site/$SITE --no-interaction --no-progress
        fi
        cd /run/site/$SITE
        cp -n web/sites/default/default.settings.php web/sites/default/settings.php || true
        chmod u+w web/sites/default
        if ! grep -q 'benchmarks-drupal' web/sites/default/settings.php; then
            cat >> web/sites/default/settings.php <<'PHP'

/* benchmarks-drupal: added by scripts/site-build.sh */
\$databases['default']['default'] = [
  'database' => 'drupal',
  'username' => 'root',
  'password' => '',
  'host' => 'db',
  'port' => 3306,
  'driver' => 'mysql',
  'prefix' => '',
];
\$settings['trusted_host_patterns'] = ['.*'];
\$settings['file_private_path'] = NULL;
PHP
        fi
        ./vendor/bin/drush site:install demo_umami \
            --db-url=mysql://root@db/drupal \
            --account-name=admin --account-pass=admin \
            --site-name='FreeUnit benchmark' --yes
        ./vendor/bin/drush pm:enable fu_queue_test --yes
        ./vendor/bin/drush pm:uninstall big_pipe --yes || true
        ./vendor/bin/drush sset fu_queue_test.key benchmark
        ./vendor/bin/drush user:create $BENCH_USER --password=$BENCH_PASS --mail=$BENCH_USER@example.com || true
        ./vendor/bin/drush role:assign authenticated $BENCH_USER || true
        ./vendor/bin/drush cr
        drupal=\$(./vendor/bin/drush status --field=drupal-version)
        php=\$(php -r 'echo PHP_VERSION;')
        echo \"tag=$DRUPAL_TAG drupal=\$drupal php=\$php\" > /run/site/$SITE/meta.txt
    "

echo "site-build: login cookie for the drupal-auth workload"
docker run -d --name "rt-sitebuild-$$" --network "$NET" -p "127.0.0.1:$PORT:80" \
    -v "$SITEDIR:/app" -v "$RUNROOT/runtimes/freeunit.json:/docker-entrypoint.d/config.json:ro" \
    "$TOOL_IMAGE" >/dev/null
for i in $(seq 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)" = 200 ] && break
    sleep 1
done
LOGIN_URL=$(docker run --rm --network "$NET" -v "$RUNROOT:/run" \
    -e HOME=/root -e COMPOSER_HOME=/opt/composer "$TOOL_IMAGE" \
    sh -c "cd /run/site/$SITE && ./vendor/bin/drush user:login --name=$BENCH_USER --uri=http://127.0.0.1:$PORT 2>/dev/null" | grep -o 'http://[^ ]*' | head -1)
if [ -n "$LOGIN_URL" ]; then
    curl -s -c "$SITEDIR/cookie.txt" -o /dev/null "$LOGIN_URL"
    # one authenticated request to confirm the cookie renders the front page
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $(grep -v '^#' "$SITEDIR/cookie.txt" | awk '{print $6"="$7}' | paste -sd'; ')" "http://127.0.0.1:$PORT/")
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
