#!/bin/bash
# build-images.sh -- build every runtime image the jobs expect.
#
# Why this is a shell script and not `bin/drupal-bench build`: bin/drupal-bench is
# a PHP script, and the perf hosts have no PHP installed, so the waiter's build
# step died with `/usr/bin/env: 'php': No such file or directory` and the boxes
# kept running whatever images they already had. That is how the DB axis and
# WordPress came to run against an image without mysqli.
#
#   scripts/build-images.sh            # host side, any directory
#
# FREEUNIT_MASTER_REF pins the master image; the same value is recorded in
# docs/progress.md and is what the published master runs used.
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER_REF=${FREEUNIT_MASTER_REF:-868ccc29214b979510cee37b2084d2cf3b34e382}

docker build -f docker/Dockerfile.freeunit -t drupal-bench-freeunit:1.37.0 .
docker build -f docker/Dockerfile.freeunit \
    --build-arg FREEUNIT_REF="$MASTER_REF" -t drupal-bench-freeunit:master .
docker build -f docker/Dockerfile.php --target php-fpm -t drupal-bench-fpm:8.5 .
docker build -f docker/Dockerfile.php --target apache -t drupal-bench-apache:8.5 .
docker pull mariadb:10.11
docker pull postgres:17

# Prove the modules the database axis and WordPress need actually landed. A
# stale image is otherwise invisible until a site install fails halfway.
echo "checking the extensions the images must carry"
for img in drupal-bench-freeunit:1.37.0 drupal-bench-freeunit:master drupal-bench-fpm:8.5 drupal-bench-apache:8.5; do
    for ext in mysqli pdo_pgsql pdo_sqlite pdo_mysql intl mbstring; do
        if ! docker run --rm --entrypoint php "$img" -m 2>/dev/null | grep -qix "$ext"; then
            echo "build-images: $img is missing $ext" >&2
            exit 1
        fi
    done
    echo "  $img ok"
done
