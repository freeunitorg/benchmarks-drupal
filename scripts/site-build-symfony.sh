#!/bin/bash
# site-build-symfony.sh -- build the Symfony benchmark app, on the perf host.
#
#   scripts/site-build-symfony.sh [RUNROOT] [--force]
#
# A pinned Symfony skeleton (7.4.*) plus Twig and a DB-backed front page: the
# controller opens a PDO connection from DATABASE_URL, selects 50 of 200 rows
# and renders them. That is the realistic "framework page with a database read"
# workload, the same shape as the Drupal front page but without Drupal's cache
# layers, so it tests the SAPI, not the framework.
#
# The document root is public/; a `web -> public` symlink lets one set of runtime
# configs (which use /app/web) serve both Drupal and Symfony.
set -euo pipefail

RUNROOT=${1:-/data/projects/benchmarks-drupal/run}
FORCE=${2:-}
TOOL_IMAGE=${TOOL_IMAGE:-drupal-bench-freeunit:1.37.0}
DB_IMAGE=${DB_IMAGE:-mariadb:10.11}
NET="dbnet-symfony-$$"
DBC="db-symfony-$$"
SITEDIR="$RUNROOT/site/symfony"
REPO=$(cd "$(dirname "$0")/.." && pwd)

cleanup() { docker rm -f "$DBC" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT

site_installed() {
    [ -f "$SITEDIR/meta.txt" ] && grep -q '^site=symfony' "$SITEDIR/meta.txt" 2>/dev/null \
        && [ -f "$SITEDIR/public/index.php" ]
}
if site_installed && [ "$FORCE" != "--force" ]; then
    echo "site-build-symfony: $SITEDIR already installed (use --force to rebuild)"
    exit 0
fi
# create-project leaves public/index.php before the app is configured; an
# incomplete tree is rebuilt rather than reused.
if { [ "$FORCE" = "--force" ] || [ -d "$SITEDIR" ]; } && ! site_installed; then
    docker run --rm -v "$RUNROOT:/run" alpine:3 sh -c "rm -rf /run/site/symfony"
fi
mkdir -p "$SITEDIR" "$RUNROOT/cache/composer"

docker network create "$NET" >/dev/null
DBCVOL=${DBCVOL:-drupal-bench-db-symfony}
docker run -d --name "$DBC" --network "$NET" --network-alias db \
    -v "$DBCVOL:/var/lib/mysql" \
    -e MARIADB_ROOT_HOST=% -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=drupal_symfony \
    "$DB_IMAGE" >/dev/null
for _ in $(seq 60); do docker exec "$DBC" mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 1; done

echo "site-build-symfony: composer create-project symfony/skeleton -> $SITEDIR"
docker run --rm --network "$NET" \
    -v "$RUNROOT:/run" -v "$REPO/symfony:/run/symfony-src:ro" -v "$RUNROOT/cache/composer:/cache" \
    -w /run -e HOME=/root -e COMPOSER_HOME=/cache -e COMPOSER_ALLOW_SUPERUSER=1 \
    "$TOOL_IMAGE" sh -euc '
        if [ ! -f /run/site/symfony/composer.json ]; then
            composer create-project symfony/skeleton:"7.4.*" /run/site/symfony --no-interaction --no-progress
        fi
        cd /run/site/symfony
        composer require --no-interaction --no-progress \
            symfony/framework-bundle:"7.4.*" symfony/twig-bundle:"7.4.*" \
            symfony/asset:"7.4.*" symfony/yaml:"7.4.*"
        cp /run/symfony-src/src/HomeController.php src/Controller/HomeController.php
        mkdir -p templates
        cp /run/symfony-src/templates/home.html.twig templates/home.html.twig
        secret=$(php -r "echo bin2hex(random_bytes(16));")
        cat > .env.local <<EOF
APP_ENV=prod
APP_DEBUG=0
APP_SECRET=$secret
DATABASE_URL=mysql://root@db/drupal_symfony
EOF
        php -r "
            \$pdo = new PDO(\"mysql:host=db;dbname=drupal_symfony\", \"root\", \"\");
            \$pdo->exec(\"DROP TABLE IF EXISTS symfony_items\");
            \$pdo->exec(\"CREATE TABLE symfony_items (id INT PRIMARY KEY AUTO_INCREMENT, title VARCHAR(120) NOT NULL, body TEXT NOT NULL, created INT NOT NULL)\");
            \$s = \$pdo->prepare(\"INSERT INTO symfony_items (title, body, created) VALUES (?, ?, ?)\");
            for (\$i = 1; \$i <= 200; \$i++) { \$s->execute([\"Bench item \$i\", str_repeat(\"body \$i \", 20), 1700000000 + \$i]); }
            echo \"seeded \" . \$pdo->query(\"SELECT COUNT(*) FROM symfony_items\")->fetchColumn() . \" rows\n\";
        "
        php bin/console cache:clear --env=prod --no-warmup
        php bin/console cache:warmup --env=prod
        ln -sfn public web
        fw=$(php -r "require \"vendor/autoload.php\"; echo \Symfony\Component\HttpKernel\Kernel::VERSION;")
        phpv=$(php -r "echo PHP_VERSION;")
        { echo "site=symfony"; echo "framework=$fw"; echo "php=$phpv"; echo "tag=symfony/skeleton:7.4.*"; } > /run/site/symfony/meta.txt
    '
chown -R "$(id -u):$(id -g)" "$SITEDIR" 2>/dev/null || true
chown -R "$(id -u):$(id -g)" "$SITEDIR" 2>/dev/null || true
cat >> "$SITEDIR/meta.txt" <<EOF
runroot=$RUNROOT
installed=$(date -u +%FT%TZ)
page_note=50 of 200 rows from MariaDB via PDO, Twig render
EOF
chown -R "$(id -u):$(id -g)" "$SITEDIR" 2>/dev/null || true
echo "site-build-symfony: done -> $SITEDIR"
