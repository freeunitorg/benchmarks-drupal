#!/bin/bash
# site-build-wp.sh -- a WordPress site for the benchmark.
#
#   scripts/site-build-wp.sh [RUNROOT] [--force]
#
# Pin: WordPress 7.1.3 (wordpress.org, md5 sidecar checked) and wp-cli 2.12.0 (the
# release phar, sha256 checked). WordPress talks to the database through mysqli
# only -- there is no PDO path -- so this is the stack where the mysqli driver
# question is not a choice but the only option.
#
# Env:
#   DB=mysql             WordPress needs MySQL or MariaDB; any other value is refused
#   DB_HOST=db           the database host inside the container network
#   WP_VERSION=7.1.3     the WordPress release
#   WP_CLI_VERSION=2.12.0
#   WP_PERSISTENT=0      1 adds wp-content/db.php (a persistent-connection drop-in)
#                        and builds the site as wp-persistent instead of wp
#   PORT=8081            the URL stored in home/siteurl; rebuild if the job changes it
#   FU_BENCH_US=1000     deliberate work per measured request (mu-plugin)
#
# The document root is /app/web like the other applications, so one set of runtime
# configs serves all of them.
set -euo pipefail

RUNROOT=${1:-/data/projects/benchmarks-drupal/run}
FORCE=${2:-}
TOOL_IMAGE=${TOOL_IMAGE:-drupal-bench-freeunit:1.37.0}
DB_IMAGE=${DB_IMAGE:-mariadb:10.11}
DB=${DB:-mysql}
DB_HOST=${DB_HOST:-db}
WP_VERSION=${WP_VERSION:-7.1.3}
WP_VERSION_MD5=${WP_VERSION_MD5:-cf558ee9e6768434cd574aedb15ee335}
WP_CLI_VERSION=${WP_CLI_VERSION:-2.12.0}
WP_CLI_SHA256=${WP_CLI_SHA256:-ce34ddd838f7351d6759068d09793f26755463b4a4610a5a5c0a97b68220d85c}
WP_PERSISTENT=${WP_PERSISTENT:-0}
FU_BENCH_US=${FU_BENCH_US:-1000}
PORT=${PORT:-8081}
WP_TITLE=${WP_TITLE:-FreeUnit benchmark}
DB_NAME=${DB_NAME:-wordpress}
DB_USER=${DB_USER:-root}
SITEKEY=wp
[ "$WP_PERSISTENT" = 1 ] && SITEKEY=wp-persistent
SITEDIR="$RUNROOT/site/$SITEKEY"
DBCVOL=${DBCVOL:-drupal-bench-db-$SITEKEY}
NET="dbnet-wp-$$"
DBC="db-wp-$$"
REPO=$(cd "$(dirname "$0")/.." && pwd)

# WordPress's only supported database is MySQL/MariaDB (mysqli).
case "$DB" in
mysql|mysqli) ;;
*) echo "site-build-wp: WordPress needs DB=mysql (it uses mysqli); got '$DB'" >&2; exit 2 ;;
esac

cleanup() { docker rm -f "$DBC" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT

site_installed() {
    [ -f "$SITEDIR/meta.txt" ] && grep -q '^wp=' "$SITEDIR/meta.txt" 2>/dev/null \
        && [ -f "$SITEDIR/web/wp-includes/version.php" ] \
        && [ -f "$SITEDIR/web/wp-config.php" ]
}
if site_installed && [ "$FORCE" != "--force" ]; then
    echo "site-build-wp: $SITEDIR already installed (use --force to rebuild)"
    exit 0
fi
if { [ "$FORCE" = "--force" ] || [ -d "$SITEDIR" ]; } && ! site_installed; then
    echo "site-build-wp: removing incomplete $SITEDIR"
    docker run --rm -v "$RUNROOT:/run" alpine:3 sh -c "rm -rf /run/site/$SITEKEY"
fi
mkdir -p "$SITEDIR" "$RUNROOT/cache"

docker network create "$NET" >/dev/null
docker run -d --name "$DBC" --network "$NET" --network-alias db \
    -v "$DBCVOL:/var/lib/mysql" \
    -e MARIADB_ROOT_HOST=% -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE="$DB_NAME" \
    "$DB_IMAGE" >/dev/null
for _ in $(seq 60); do
    docker exec "$DBC" mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
done
# a rebuild starts from an empty database
docker exec "$DBC" mariadb -uroot -e "DROP DATABASE IF EXISTS $DB_NAME; CREATE DATABASE $DB_NAME;" 2>/dev/null || true

echo "site-build-wp: WordPress $WP_VERSION (persistent=$WP_PERSISTENT) -> $SITEDIR"
docker run --rm --network "$NET" \
    -v "$RUNROOT:/run" -v "$REPO/wordpress:/run/wordpress-src:ro" \
    -w /run -e HOME=/root \
    -e WP_CLI_ALLOW_ROOT=1 -e DB_NAME="$DB_NAME" -e DB_USER="$DB_USER" -e DB_HOST="$DB_HOST" \
    -e WP_VERSION="$WP_VERSION" -e WP_VERSION_MD5="$WP_VERSION_MD5" \
    -e WP_CLI_VERSION="$WP_CLI_VERSION" -e WP_CLI_SHA256="$WP_CLI_SHA256" \
    -e WP_TITLE="$WP_TITLE" -e PORT="$PORT" -e WP_PERSISTENT="$WP_PERSISTENT" -e FU_BENCH_US="$FU_BENCH_US" \
    "$TOOL_IMAGE" sh -euc '
        set -eu
        WP="php /run/wp-cli.phar --allow-root --path=/run/site/'"$SITEKEY"'/web"

        if [ ! -f /run/wp-cli.phar ]; then
            curl -fsSL -o /run/wp-cli.phar "https://github.com/wp-cli/wp-cli/releases/download/v$WP_CLI_VERSION/wp-cli-$WP_CLI_VERSION.phar"
            echo "$WP_CLI_SHA256  /run/wp-cli.phar" | sha256sum -c -
            chmod +x /run/wp-cli.phar
        fi

        mkdir -p /run/site/'"$SITEKEY"'/web
        # wp-cli downloads the pinned release and verifies it against
        # the wordpress.org checksum API; the tarball md5 is recorded in meta.txt
        $WP core download --version="$WP_VERSION" --locale=en_US --force

        if [ ! -f /run/site/'"$SITEKEY"'/web/wp-config.php ]; then
            $WP config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="" \
                --dbhost="$DB_HOST" --dbprefix=wp_ --skip-check --force
        fi
        $WP config set FU_BENCH_US "$FU_BENCH_US" --raw
        $WP config set DISABLE_WP_CRON false --raw

        $WP core install --url="http://127.0.0.1:$PORT" --title="$WP_TITLE" \
            --admin_user=admin --admin_password=admin --admin_email=admin@example.com --skip-email

        mkdir -p /run/site/'"$SITEKEY"'/web/wp-content/mu-plugins
        cp /run/wordpress-src/mu-plugins/fu-bench.php /run/site/'"$SITEKEY"'/web/wp-content/mu-plugins/
        if [ "$WP_PERSISTENT" = 1 ]; then
            cp /run/wordpress-src/db-persistent.php /run/site/'"$SITEKEY"'/web/wp-content/db.php
        fi

        $WP post generate --count=200 --post_type=post >/dev/null
        $WP option update blogdescription "FreeUnit benchmark site"
        $WP rewrite structure "/%postname%/" --hard >/dev/null
        $WP rewrite flush --hard >/dev/null
        $WP cache flush >/dev/null 2>&1 || true

        wpv=$($WP core version)
        phpv=$(php -r "echo PHP_VERSION;")
        printf "wp=%s\nphp=%s\ndb=%s\ndb_host=%s\nsite=%s\npersistent=%s\nwp_cli=%s\ntarball_md5=%s\ninstalled=%s\n" \
            "$wpv" "$phpv" "$DB_NAME" "$DB_HOST" "http://127.0.0.1:$PORT" "$WP_PERSISTENT" "$WP_CLI_VERSION" "$WP_VERSION_MD5" \
            "$(date -u +%FT%TZ)" > /run/site/'"$SITEKEY"'/meta.txt
    '

chown -R "$(id -u):$(id -g)" "$SITEDIR" 2>/dev/null || true
echo "site-build-wp: done -> $SITEDIR"
cat "$SITEDIR/meta.txt"
