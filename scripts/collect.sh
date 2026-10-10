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
# Numeric output must not follow the caller locale (awk/printf would use ",").
export LC_ALL=C
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
# Normalize the meta keys the renderer needs. run.sh wrote them on one line until
# 2026-10-10 and the Symfony builder's descriptive line shadowed them, so a
# collected run is normalized from its own job name when the keys are missing.
python3 - "$DEST" <<'PY'
import glob, json, os, re, sys
dest = sys.argv[1]
for f in sorted(glob.glob(os.path.join(dest, "*", "summary.json"))):
    run = os.path.basename(os.path.dirname(f))
    try:
        d = json.load(open(f))
    except (OSError, ValueError):
        continue
    m = d.get("meta") or {}
    wl = str(m.get("workload", ""))
    if "=" in wl:
        parts = dict(kv.split("=", 1) for kv in wl.split() if "=" in kv)
        m["workload"] = wl.split()[0]
        for k in ("runtime_a", "runtime_b", "site"):
            if parts.get(k):
                m[k] = parts[k]
    if "symfony" in run and not str(m.get("workload", "")).startswith("symfony"):
        m["workload"] = "symfony-front"
        m["site"] = "symfony"
        m.setdefault("runtime_a", "freeunit")
        if run.startswith(("14-", "20-")):
            m["runtime_b"] = "apache" if run.startswith("20-") else "nginx-fpm"
        elif run.startswith("19-"):
            m["runtime_a"], m["runtime_b"] = "freeunit-master", "nginx-fpm"
        elif run.startswith("15-"):
            m["runtime_b"] = "freeunit-master"
        elif run.startswith("13-"):
            m["runtime_b"] = "freeunit"
    d["meta"] = m
    json.dump(d, open(f, "w"), indent=1)
    open(f, "a").write("\n")
print("collect: normalized meta for", len(glob.glob(os.path.join(dest, "*", "summary.json"))), "runs")
PY

mkdir -p "$HERE/public"
python3 "$HERE/report/render.py" "$DEST" "$HERE/public/index.html"
