#!/bin/bash
# collect.sh -- pull finished runs from the perf host into results/ and render the page.
#
#   scripts/collect.sh [HOST] [REMOTE_ROOT]
#
# Copies only the artefacts that are the source of truth for a published number:
#   results.tsv, summary.json, meta.txt, compare.txt, job.txt, preflight.txt,
#   cells.log (raw cell lines), site-meta.txt
# Smoke and non-numbered run directories are skipped. Nothing here computes a
# number; report/render.py reads the summary.json files.
set -euo pipefail

HOST=${1:-pro4s-2}
REMOTE_ROOT=${2:-/data/projects/benchmarks-drupal}
HERE=$(cd "$(dirname "$0")/.." && pwd)
DEST="$HERE/results"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "collect: listing runs on $HOST"
ssh "$HOST" "find $REMOTE_ROOT/run -maxdepth 1 -mindepth 1 -type d -printf '%f\n'" 2>/dev/null | grep -E '^[0-9]' > "$TMP/runs" || true
n=0
while read -r run; do
    [ -n "$run" ] || continue
    case "$run" in 00-*) continue ;; esac
    ssh -n "$HOST" "test -f $REMOTE_ROOT/run/$run/summary.json" || continue
    mkdir -p "$DEST/$run"
    for f in summary.json meta.txt compare.txt job.txt results.tsv preflight.txt cells.log site-meta.txt; do
        rsync -a "$HOST:$REMOTE_ROOT/run/$run/$f" "$DEST/$run/" 2>/dev/null || true
    done
    n=$((n + 1))
    echo "collected $run"
done < "$TMP/runs"
echo "collect: $n runs -> $DEST"
mkdir -p "$HERE/public"
python3 "$HERE/report/render.py" "$DEST" "$HERE/public/index.html"
