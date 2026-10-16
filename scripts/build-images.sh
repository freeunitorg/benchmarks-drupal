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

MASTER_REF=${FREEUNIT_MASTER_REF:-b09815f1721b439bbd7aa91160c96a40e8ff2328}
# The previous master pin, for a within-run A/B of the commits merged since it.
MASTER_OLD_REF=${FREEUNIT_MASTER_OLD_REF:-8492d5ee43a99a8f1504598ed44d046b61d85131}
# The point between the two, so a gain can be attributed to the commit that caused it.
MASTER_MID_REF=${FREEUNIT_MASTER_MID_REF:-dc30c8a7e76fe86f8063ce7eafcefc285137629a}
RUNROOT=${RUNROOT:-run}

docker build -f docker/Dockerfile.freeunit -t drupal-bench-freeunit:1.37.0 .
docker build -f docker/Dockerfile.freeunit \
    --build-arg FREEUNIT_REF="$MASTER_REF" -t drupal-bench-freeunit:master .
docker build -f docker/Dockerfile.freeunit \
    --build-arg FREEUNIT_REF="$MASTER_OLD_REF" -t drupal-bench-freeunit:master-old .
docker build -f docker/Dockerfile.freeunit \
    --build-arg FREEUNIT_REF="$MASTER_MID_REF" -t drupal-bench-freeunit:master-mid .

# The run's meta.txt reads this file, so a published master number names the
# commit it was built from instead of "unknown".
mkdir -p "$RUNROOT"
printf '%s\n' "$MASTER_REF" > "$RUNROOT/freeunit-master-sha"
printf '%s\n' "$MASTER_OLD_REF" > "$RUNROOT/freeunit-master-old-sha"
printf '%s\n' "$MASTER_MID_REF" > "$RUNROOT/freeunit-master-mid-sha"
docker build -f docker/Dockerfile.php --target php-fpm -t drupal-bench-fpm:8.5 .
docker build -f docker/Dockerfile.php --target apache -t drupal-bench-apache:8.5 .

# The same FreeUnit tree built against musl (Alpine's php85 is the same 8.5.11), for
# the C-library comparison.  Its PHP is php85, not php, which is why the extension
# check below skips it.
docker build -f docker/Dockerfile.freeunit-alpine -t drupal-bench-freeunit:musl .

# The webservers built from upstream tarballs. Versions and checksums are pinned
# in docker/Dockerfile.php next to each URL; a bump edits that one line.
docker build -f docker/Dockerfile.php --target nginx-src -t drupal-bench-nginx-src:8.5 .
docker build -f docker/Dockerfile.php --target angie-fpm -t drupal-bench-angie:8.5 .
docker build -f docker/Dockerfile.php --target freenginx-fpm -t drupal-bench-freenginx:8.5 .
docker pull mariadb:10.11
docker pull postgres:18

# The version each webserver image actually carries, so a published run can name
# it without inspecting the image later.
{
    for pair in "nginx-package:drupal-bench-fpm:8.5:/usr/sbin/nginx" \
                "nginx-src:drupal-bench-nginx-src:8.5:/usr/local/nginx/sbin/nginx" \
                "angie:drupal-bench-angie:8.5:/usr/local/angie/sbin/angie" \
                "freenginx:drupal-bench-freenginx:8.5:/usr/local/freenginx/sbin/nginx"; do
        name=${pair%%:*}; rest=${pair#*:}; image=${rest%%:*}; bin=${rest##*:}
        version=$(docker run --rm --entrypoint "$bin" "$image" -v 2>&1 | head -n 1)
        printf '%s=%s\n' "$name" "$version"
    done
} > "$RUNROOT/webserver-versions.txt" 2>/dev/null || true

# Prove the modules the database axis and WordPress need actually landed. A
# stale image is otherwise invisible until a site install fails halfway.
echo "checking the extensions the images must carry"
# Read the module list once per image: `docker run | grep -q` under `set -o
# pipefail` fails the pipeline with 141 when grep closes the pipe early, which
# reported modules that are present as missing.
for img in drupal-bench-freeunit:1.37.0 drupal-bench-freeunit:master drupal-bench-fpm:8.5 \
           drupal-bench-apache:8.5 drupal-bench-nginx-src:8.5 drupal-bench-angie:8.5 \
           drupal-bench-freenginx:8.5; do
    mods=$(docker run --rm --entrypoint php "$img" -m 2>/dev/null || true)
    for ext in mysqli pdo_pgsql pdo_sqlite pdo_mysql intl mbstring; do
        if ! grep -qix "$ext" <<<"$mods"; then
            echo "build-images: $img is missing $ext" >&2
            exit 1
        fi
    done
    echo "  $img ok"
done
