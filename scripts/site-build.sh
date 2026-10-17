#!/bin/bash
# site-build.sh -- build and install one application for the benchmark, on the perf host.
#
#   scripts/site-build.sh <site> [RUNROOT] [--force]
#
# Sites:
#   11.4           Drupal 11.4.8, demo_umami
#   11.4-standard  Drupal 11.4.8, standard
#   11.5           Drupal 11.5.x-dev, demo_umami
#   11.5-standard  Drupal 11.5.x-dev, standard
#   12.0           Drupal 12.0.0-beta1, demo_umami
#   12.0-standard  NOT SUPPORTED (Drupal 12 standard profile ships no content model)
#
# 11.5 is not released yet and its branch is not on Packagist, so the entry uses
# 11.5.x-dev and composer needs --stability=dev; the build fails loudly until the
# branch exists. Drupal 11.5 is expected to require PHP 8.5, which is what the
# images already carry (8.5.11); older PHP lines stay a separate decision.
#
# drush is installed when the site's composer graph allows it (Drupal 11.4). Drupal
# 12 pins guzzle 8 while drush 13 needs guzzle ^7, and the advisory policy blocks
# every 7.x, so the 12.x sites are driven by apps/drupal_cli.php instead: core's own
# installer plus the Drupal APIs for enable/state/user/login/cron/queue.
#
# Everything that writes into the site runs in a container as root, so a rebuild
# wipes through a container. Records $RUNROOT/site/<site>/meta.txt.
set -euo pipefail

SITE=${1:?usage: site-build.sh <11.4|11.4-standard|11.5|11.5-standard|12.0> [RUNROOT] [--force]}
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

DRUPAL_STABILITY=""
# 0 keeps the unoptimized Composer autoloader and no preload, so a site built with
# the defaults is a valid A/B baseline for the variants below.
COMPOSER_OPT=${COMPOSER_OPT:-1}
PRELOAD=${PRELOAD:-0}
case "$SITE" in
11.4)          DRUPAL_TAG=drupal/recommended-project:11.4.8;        PROFILE=demo_umami ;;
11.4-standard) DRUPAL_TAG=drupal/recommended-project:11.4.8;        PROFILE=standard ;;
11.5)          DRUPAL_TAG=drupal/recommended-project:11.5.x-dev;    PROFILE=demo_umami; DRUPAL_STABILITY="--stability=dev" ;;
11.5-standard) DRUPAL_TAG=drupal/recommended-project:11.5.x-dev;    PROFILE=standard; DRUPAL_STABILITY="--stability=dev" ;;
12.0)          DRUPAL_TAG=drupal/recommended-project:12.0.0-beta1; PROFILE=demo_umami ;;
# 12.0-beta2 is a security release (SA-CORE-2026-014, -015, -016), so the beta1 and
# beta2 rows on the Drupal 12 page are not a like-for-like version comparison: the
# delta between them carries the security hardening, including the removal of the
# Navigation Top Bar module and of query serialization.  Keep beta1 as the
# historical baseline, and do not read its rows as a recommendation: 12.0-beta1 has
# the vulnerabilities this release fixes.
12.0-beta2)    DRUPAL_TAG=drupal/recommended-project:12.0.0-beta2; PROFILE=demo_umami ;;
# 12.0-standard is deliberately absent: Drupal 12's standard profile installs no
# content types, node view displays or frontpage view (only the demo_umami profile
# carries them), so the install has no page to serve. Use 12.0, or a recipe.
12.0-standard) echo "site-build: 12.0-standard is not a usable site on Drupal 12:" >&2
              echo "  the standard profile ships no node.type.*, no node view displays and" >&2
              echo "  no frontpage view (only demo_umami has them), so there is no page." >&2
              echo "  Use 12.0, or install a recipe with apps/drupal_cli.php install-recipe." >&2
              exit 2 ;;
# The same 12.0 install with the optimizations from docs/drupal-perf-opportunities.md:
# a classmap-authoritative autoloader and an OPcache preload file. A job that pairs
# this with 12.0 measures them inside one job, against that job's own null band.
12.0-preload)  DRUPAL_TAG=drupal/recommended-project:12.0.0-beta1; PROFILE=demo_umami; PRELOAD=1 ;;
# The pre-change baseline: the same site with the autoloader composer create-project
# leaves behind. Only useful as the other half of an A/B.
12.0-nopt)     DRUPAL_TAG=drupal/recommended-project:12.0.0-beta1; PROFILE=demo_umami; COMPOSER_OPT=0 ;;
*) echo "site-build: unknown site $SITE" >&2; exit 2 ;;
esac

cleanup() {
    [ "${SKIP_CLEANUP:-0}" = 1 ] && { echo "cleanup: kept $DBC/$RTC and $NET (SKIP_CLEANUP=1)"; return 0; }
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

# A container left behind by a killed earlier build keeps the data directory open
# (MariaDB init can then stall) or holds the runtime port; clear our own stale ones
# and anything still publishing the port this build will use.
docker rm -f $(docker ps -aq --filter "name=db-sitebuild-") >/dev/null 2>&1 || true
docker rm -f $(docker ps -aq --filter "name=rt-sitebuild-") >/dev/null 2>&1 || true
for _c in $(docker ps -q -f "publish=$PORT"); do docker rm -f "$_c" >/dev/null 2>&1 || true; done

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
    # postgres:18 keeps its cluster under /var/lib/postgresql/18/docker, so the
    # volume belongs at /var/lib/postgresql and never at .../postgresql/data: that
    # path is the pre-18 layout and is simply unused here, which reads as a slow
    # first start rather than a misconfiguration. A volume that already holds a
    # version-17 cluster makes the 18 server exit at once ("database files are
    # incompatible with server"), and the only error the next step reports is
    # "could not translate host name db" -- a DNS complaint about a container that
    # is gone. So wait for readiness, and when it never comes, print the log and
    # name the volume to remove instead of letting the install fail on DNS.
    docker run -d --name "$DBC" --network "$NET" --network-alias db \
        -v "$DBCVOL:/var/lib/postgresql" \
        -e POSTGRES_DB=drupal -e POSTGRES_HOST_AUTH_METHOD=trust \
        "${PG_IMAGE:-postgres:18}" >/dev/null
    pg_ok=0
    for _ in $(seq 60); do
        if docker exec "$DBC" pg_isready -U postgres -d drupal >/dev/null 2>&1; then
            pg_ok=1; break
        fi
        [ "$(docker inspect -f '{{.State.Running}}' "$DBC" 2>/dev/null || echo false)" = true ] || break
        sleep 1
    done
    if [ "$pg_ok" != 1 ]; then
        echo "site-build: $DBC never answered pg_isready; its log follows" >&2
        docker logs "$DBC" 2>&1 | tail -n 20 >&2 || true
        echo "  if it exited at once, $DBCVOL holds a cluster this server cannot use:" >&2
        echo "  remove it (docker volume rm $DBCVOL) and rebuild with --force." >&2
        exit 1
    fi
elif [ "${DB}" = mysql ] || [ "${DB}" = mysqli ]; then
    DB_URL="mysql://root@db/drupal"
    docker run -d --name "$DBC" --network "$NET" --network-alias db \
        -v "$DBCVOL:/var/lib/mysql" \
        -e MARIADB_ROOT_HOST=% -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=drupal \
        "$DB_IMAGE" >/dev/null
    # The image runs a TEMPORARY server while it initializes (and creates root@'%'
    # itself). A client can already answer during that phase, and touching the
    # users then makes the entrypoint's own CREATE USER fail with 1396 and the
    # container exit 1 -- which then looks like a DNS failure in the next step.
    # Wait for initialization to finish, then check the real server.
    wait_maria() {
        local logs
        docker exec "$DBC" mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1 || return 1
        # Read the log once: `docker logs | grep -q` under `set -o pipefail`
        # fails with 141 (docker gets SIGPIPE when grep stops early), so the
        # marker could be present and still be reported missing.
        logs=$(docker logs "$DBC" 2>&1 || true)
        grep -q 'Temporary server started' <<<"$logs" || return 0
        grep -qE 'Temporary server stopped|init process done' <<<"$logs"
    }
    # The image's first-run initialization occasionally stalls at "Temporary server
    # started" on a fresh volume. A second start finds the data directory already
    # initialized and goes straight to the real server, so retry before failing.
    started=0
    for attempt in 1 2 3; do
        for _ in $(seq 90); do
            wait_maria && { started=1; break; }
            sleep 1
        done
        [ "$started" = 1 ] && break
        echo "site-build: database attempt $attempt did not finish initializing; retrying" >&2
        docker logs "$DBC" 2>&1 | tail -n 5 >&2
        docker rm -f "$DBC" >/dev/null 2>&1 || true
        docker run -d --name "$DBC" --network "$NET" --network-alias db \
            -v "$DBCVOL:/var/lib/mysql" \
            -e MARIADB_ROOT_HOST=% -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=drupal \
            "$DB_IMAGE" >/dev/null
    done
    if [ "$started" != 1 ]; then
        echo "site-build: mariadb container $DBC never became ready; log follows" >&2
        docker logs "$DBC" 2>&1 | tail -n 20 >&2
        exit 1
    fi
    # Do NOT touch users here: the image creates root@'%' itself from
    # MARIADB_ROOT_HOST, and a CREATE USER that wins the race against its own
    # temporary server makes the entrypoint fail with 1396 and the container exit,
    # which then shows up as a DNS failure a step later. A volume with the wrong
    # users has to be removed, not patched (see docs/progress.md).
    # a rebuild starts from an empty database
    docker exec "$DBC" mariadb -uroot -e "DROP DATABASE IF EXISTS drupal; CREATE DATABASE drupal;" 2>/dev/null || true
else
    echo "site-build: unknown DB $DB (mysql, mysqli, pgsql, sqlite)" >&2
    exit 2
fi

echo "site-build: $SITE [$DB] -> $DRUPAL_TAG ($PROFILE)"
[ "${DEBUG_BUILD:-0}" = 1 ] && {
    echo "debug: before tool container $(date -u +%T)"
    docker ps --format '  {{.Names}} {{.Status}}' | sed 's/^/  /'
    docker network inspect "$NET" --format '  net members: {{range .Containers}}{{.Name}} {{end}}' 2>&1
    docker exec "$DBC" mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1 && echo "  db answers: yes" || echo "  db answers: NO"
}
docker run --rm --network "$NET" \
    -v "$RUNROOT:/run" -v "$REPO/modules:/run/modules-src:ro" -v "$REPO/apps:/run/apps-src:ro" \
    -v "$RUNROOT/cache/composer:/cache" -w /run -e HOME=/root -e COMPOSER_HOME=/cache \
    -e DB_URL="$DB_URL" -e DB_DRIVER="$DB" -e SITE_PASS=admin -e SITE_NAME="FreeUnit benchmark" \
    -e COMPOSER_OPT="${COMPOSER_OPT:-1}" -e PRELOAD="${PRELOAD:-0}" \
    "$TOOL_IMAGE" sh -euc "
        if [ ! -f /run/site/$SITEKEY/composer.json ]; then
            composer create-project $DRUPAL_TAG /run/site/$SITEKEY $DRUPAL_STABILITY --no-interaction --no-progress
        fi
        cd /run/site/$SITEKEY
        mkdir -p web/modules/custom
        cp -r /run/modules-src/fu_queue_test web/modules/custom/
        chmod u+w web/sites/default

        HAS_DRUSH=1
        composer require --no-interaction --no-progress drush/drush:^13 >/dev/null 2>&1 || HAS_DRUSH=0
        [ \"$DB\" != mysql ] && HAS_DRUSH=0

        if [ \"\$HAS_DRUSH\" = 1 ]; then
            ./vendor/bin/drush site:install $PROFILE \
                --db-url=mysql://root@db/drupal \
                --account-name=admin --account-pass=admin \
                --site-name='FreeUnit benchmark' --yes
        else
            # No drush. The dr install command cannot be used here: it returns early
            # reporting an installed site as soon as settings.php carries a database
            # array, and with no settings.php it installs into SQLite because the
            # command has no db-url option. install_drupal with the driver spec in
            # the settings form is what drush site:install does.
            DRUPAL_ROOT=\$PWD/web
            export DRUPAL_ROOT
            CLI=\"php /run/apps-src/drupal_cli.php\"
            \$CLI install $PROFILE

            # Drupal 12's standard site has no front page: the profile points it at
            # /admin/welcome (403 for anonymous), and /node is not a route either
            # because the frontpage view ships only with demo_umami in 12. Create a
            # page node and point the front page at it, as Drupal 11's welcome node
            # did. The drush path (11.4) installs /node, so this is drush-free only.
            if [ "$PROFILE" = standard ]; then
                \$CLI front-node
            fi
        fi

        # The autoloader composer create-project leaves behind is not optimized: every
        # class outside core's small classmap costs a PSR-4 stat() per candidate
        # directory on every request, so build the classmap. NOT
        # --classmap-authoritative: Drupal 12 registers core module namespaces (the
        # database driver lives in core/modules/mysql) at runtime, and authoritative
        # mode disables the PSR-4 fallback those registrations need, which fails the
        # boot with 'Class "Drupal\mysql\Driver\Database\mysql\Connection" not
        # found'. COMPOSER_OPT=0 restores the baseline for an A/B.
        # See docs/drupal-perf-opportunities.md.
        if [ \"\${COMPOSER_OPT:-1}\" = 1 ]; then
            composer dump-autoload --optimize --no-interaction
        fi

        # Opt-in: an OPcache preload file for this site. Drupal core has none, and the
        # cell helper mounts preload.ini only when it exists, so PRELOAD=0 is inert.
        if [ \"\${PRELOAD:-0}\" = 1 ]; then
            php /run/apps-src/drupal_preload.php /run/site/$SITEKEY
        fi

        if [ \"\$HAS_DRUSH\" = 1 ]; then
            ./vendor/bin/drush pm:enable fu_queue_test page_cache dynamic_page_cache --yes
            ./vendor/bin/drush pm:uninstall big_pipe --yes || true
            ./vendor/bin/drush sset fu_queue_test.key benchmark
            ./vendor/bin/drush user:create $BENCH_USER --password=$BENCH_PASS --mail=$BENCH_USER@example.com || true
            ./vendor/bin/drush role:assign authenticated $BENCH_USER || true
            ./vendor/bin/drush cr
            drupal=\$(./vendor/bin/drush status --field=drupal-version)
        else
            \$CLI enable fu_queue_test page_cache dynamic_page_cache
            \$CLI disable big_pipe || true
            \$CLI state-set fu_queue_test.key benchmark
            \$CLI user-create $BENCH_USER $BENCH_PASS
            if [ -x vendor/bin/dr ]; then
                php vendor/bin/dr cache:rebuild
            else
                \$CLI cache-rebuild
            fi
            # The dr bench command only exists once the module is enabled; fail here
            # rather than at the login step if it did not stick.
            \$CLI module-enabled fu_queue_test >/dev/null || { echo \"fu_queue_test did not enable\"; exit 1; }
            drupal=\$(php -r 'require \"web/core/lib/Drupal.php\"; echo \\Drupal::VERSION;' 2>/dev/null || echo unknown)
        fi

        printf '\n\$settings[\"trusted_host_patterns\"] = [\".*\"];\n' >> web/sites/default/settings.php
        phpv=\$(php -r 'echo PHP_VERSION;')
        echo \"tag=$DRUPAL_TAG drupal=\$drupal php=\$phpv profile=$PROFILE drush=\$HAS_DRUSH composer_opt=$COMPOSER_OPT preload=$PRELOAD\" > /run/site/$SITEKEY/meta.txt
    "

# the build above wrote as root; hand the tree back so the host can write the
# cookie and the meta lines. chown needs root, so do it in a container.
docker run --rm -v "$RUNROOT:/run" alpine:3 sh -c "chown -R $(id -u):$(id -g) /run/site/$SITEKEY" >/dev/null 2>&1 || true

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
            php ./vendor/bin/dr --url=http://127.0.0.1:'"$PORT"' bench login-url '"$BENCH_USER"' 2>/dev/null
        else
            DRUPAL_ROOT=/app/web php /run/apps-src/drupal_cli.php login-url '"$BENCH_USER"'
        fi' | tr -d '\r' | grep -o 'http://[^" ]*' | head -1)
if [ -n "$LOGIN_URL" ]; then
    # No -L: the one-time link answers 302 with the session cookie, and following
    # the redirect lands on the reset form, which deletes that cookie again.
    curl -s -c "$SITEDIR/cookie.txt" -o /dev/null "$LOGIN_URL" || true
    COOKIE=$(awk '($1 ~ /^#HttpOnly_/ || $1 !~ /^#/) && NF >= 7 { printf "%s=%s; ", $6, $7 }' "$SITEDIR/cookie.txt")
    hdrs=$(curl -s -D - -o /dev/null -H "Cookie: $COOKIE" "http://127.0.0.1:$PORT/")
    if [ -z "$COOKIE" ]; then
        echo "site-build: WARNING the login link set no cookie; drupal-auth will not authenticate" | tee -a "$SITEDIR/meta.txt"
    elif printf '%s' "$hdrs" | grep -qi '^x-drupal-dynamic-cache:'; then
        echo "site-build: auth cookie verified (session cookie plus dynamic cache header)" | tee -a "$SITEDIR/meta.txt"
    else
        echo "site-build: WARNING a cookie was stored but the render path did not show it" | tee -a "$SITEDIR/meta.txt"
    fi
else
    echo "site-build: WARNING no login link; drupal-auth cannot run" | tee -a "$SITEDIR/meta.txt"
fi
cat >> "$SITEDIR/meta.txt" <<EOF
site=$SITE
runroot=$RUNROOT
installed=$(date -u +%FT%TZ)
user=$BENCH_USER
EOF
# Drupal's sqlite database is a file in web/sites/default/files, and the runtime
# drops privileges (www-data in the Debian images, nobody in the Alpine one).  The
# install runs as root inside the tool container, so the directory and the .sqlite
# file are left root/host-owned and the app cannot write its own cache database:
# every request then answers 500 and the whole run goes INVALID.  A direct write test
# as the app user returned DENIED before this.  The server-backed databases never
# show it because their writes go to a container, not to this directory.
if [ "$DB" = sqlite ]; then
    docker run --rm -v "$RUNROOT:/run" alpine:3 sh -c \
        "chmod -R a+rwX /run/site/$SITEKEY/web/sites/default/files" >/dev/null
    echo "site-build: made web/sites/default/files writable (sqlite database lives there)"
fi
echo "site-build: done -> $SITEDIR"
