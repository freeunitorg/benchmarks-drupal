#!/bin/bash
# site-build-hello.sh -- the framework-free control app (hello / headers / body).
set -euo pipefail
RUNROOT=${1:-/data/projects/benchmarks-drupal/run}
REPO=$(cd "$(dirname "$0")/.." && pwd)
SITEDIR="$RUNROOT/site/hello"
mkdir -p "$SITEDIR/web"
cp "$REPO/hello-app/web/index.php" "$SITEDIR/web/index.php"
echo "site-build-hello: done -> $SITEDIR"
