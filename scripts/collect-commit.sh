#!/bin/bash
# collect-commit.sh -- pull finished runs from a perf host and commit each one.
#
#   scripts/collect-commit.sh [HOST] [--dry-run]
#
# One commit per completed benchmark, pushed as it lands, so a run is never left
# uncommitted in the working tree. collect.sh does the copying and the render;
# this only decides what is new and writes the commit message from the run's own
# summary.json (job name plus the headline verdict), so the history is readable.
#
# COLLECT_ONLY is passed through to collect.sh: on a host shared with another
# session, name the job prefixes that are ours.
export LC_ALL=C
set -euo pipefail

HOST=${1:-pro4s-2}
DRY=${2:-}
HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

scripts/collect.sh "$HOST" >/tmp/collect-commit-collect.log 2>&1 || {
    tail -n 5 /tmp/collect-commit-collect.log >&2; exit 1; }
tail -n 2 /tmp/collect-commit-collect.log

# Runs are new when their directory is untracked in results/. A run that was
# collected before but got more artefacts shows up as modified; that is a fix to
# a published number, so it is committed too, in its own commit.
mapfile -t changed < <(git status --porcelain -- results | awk '{print $2}' \
    | sed 's|^results/||' | cut -d/ -f1 | sort -u)
[ ${#changed[@]} -gt 0 ] || { echo "collect-commit: nothing new on $HOST"; exit 0; }

for run in "${changed[@]}"; do
    [ -f "results/$run/summary.json" ] || continue
    msg=$(python3 - "$run" <<'PY'
import json, sys
run = sys.argv[1]
try:
    d = json.load(open(f"results/{run}/summary.json"))
except (OSError, ValueError):
    print(f"results: {run}"); raise SystemExit
job = (d.get("meta") or {}).get("job", run)
head = d.get("headline", "")
print(f"results: {job}\n\n{head}" if head else f"results: {job}")
PY
)
    if [ "$DRY" = "--dry-run" ]; then
        printf '%s\n---\n' "$msg"
        continue
    fi
    git add "results/$run"
    git -c user.name="Strace" -c user.email="strace@pi" commit -q -m "$msg"
    echo "committed $run"
    git push >/dev/null 2>&1 && echo "pushed $run" || echo "WARNING: push failed for $run"
done

# The page is derived from every collected run, so it belongs with the same batch
# but is not part of any single benchmark.
if [ "$DRY" != "--dry-run" ] && ! git diff --quiet -- public/index.html 2>/dev/null; then
    git add public/index.html
    git -c user.name="Strace" -c user.email="strace@pi" commit -q -m "report: re-render the page for the newly collected runs"
    git push >/dev/null 2>&1 && echo "pushed page update"
fi
