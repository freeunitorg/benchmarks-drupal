#!/bin/bash
# campaign.sh -- run the phase-0 matrix unattended, one step at a time, on the perf host.
#
#   scripts/campaign.sh [STEPSFILE] [RUNROOT]
#
# The steps file is one entry per line:
#   site:11.4                       build the site (idempotent)
#   job:bench/jobs/02-....job       one bench job (bench/run.sh)
#   ticks:freeunit:B:20:11.4        cron/queue arm: runtime, arm, ticks, site
#   # comment
#
# Resumable: a finished entry is recorded in $RUNROOT/campaign.done with its exit
# code; a rerun skips it. Progress and health go to $RUNROOT/campaign.log and
# $RUNROOT/campaign-health.log. Nothing here is parallel: the box is claimed by
# one step at a time, and bench/run.sh refuses a busy box.
set -u

STEPS=${1:-$(cd "$(dirname "$0")/.." && pwd)/scripts/campaign.steps}
RUNROOT=${2:-/data/projects/benchmarks-drupal/run}
REPO=$(cd "$(dirname "$0")/.." && pwd)
DONE="$RUNROOT/campaign.done"
mkdir -p "$RUNROOT"
touch "$DONE"

say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$RUNROOT/campaign.log"; }

# Hard stop: the box is granted until DEADLINE_UTC (default 13:00Z = 15:00 CEST).
# A step that would start after it is recorded as skipped, so a rerun resumes.
DEADLINE_UTC=${DEADLINE_UTC:-2026-10-10T13:00:00Z}
past_deadline() {
    case "${DEADLINE_UTC}" in ""|none) return 1 ;; esac
    [ "$(date -u +%s)" -ge "$(date -u -d "$DEADLINE_UTC" +%s 2>/dev/null || echo 0)" ]
}

# The runtime configs cells.sh mounts live in $RUNROOT/runtimes; refresh them from
# the repository every run so a config fix (e.g. the opcache string bug) cannot be
# shadowed by a stale copy.
mkdir -p "$RUNROOT/runtimes"
cp -f "$REPO"/docker/runtimes/*.json "$RUNROOT/runtimes/"
cp -f "$REPO"/apps/* "$RUNROOT/apps/" 2>/dev/null || { mkdir -p "$RUNROOT/apps"; cp -f "$REPO"/apps/* "$RUNROOT/apps/"; }

done_already() { grep -qF " $1 " "$DONE" 2>/dev/null; }
mark() { printf '%s %s exit=%s %s\n' "$(date -u +%FT%TZ)" "$1" "$2" "${3:-}" >> "$DONE"; }

n=0
while IFS= read -r line; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$line" ] || continue
    n=$((n + 1))
    if past_deadline; then
        say "deadline $DEADLINE_UTC reached before $line; stopping"
        break
    fi
    if done_already "$line"; then
        say "skip $line (already done)"
        continue
    fi
    log="$RUNROOT/campaign-logs/$(printf '%s' "$line" | tr '/:' '__').log"
    mkdir -p "$(dirname "$log")"
    say "START $line -> $log"
    rc=0
    case "$line" in
    site:*)  SITE=${line#site:}
             if [ "$SITE" = symfony ]; then
                 bash "$REPO/scripts/site-build-symfony.sh" "$RUNROOT" >>"$log" 2>&1 || rc=$?
             else
                 bash "$REPO/scripts/site-build.sh" "$SITE" "$RUNROOT" >>"$log" 2>&1 || rc=$?
             fi ;;
    job:*)   job=${line#job:}
             RUNROOT="$RUNROOT" bash "$REPO/bench/run.sh" "$REPO/$job" >>"$log" 2>&1 || rc=$? ;;
    ticks:*) rest=${line#ticks:}
             IFS=: read -r rt arm ticks site <<<"$rest"
             RUNROOT="$RUNROOT" SITE="$site" bash "$REPO/bench/tick.sh" "$rt" "$arm" "$ticks" "$RUNROOT/ticks-$rt-$arm-$site-$(date -u +%Y%m%dT%H%M%SZ)" >>"$log" 2>&1 || rc=$?
             ;;
    *)       say "unknown step $line"; rc=99 ;;
    esac
    mark "$line" "$rc"
    if [ "$rc" = 0 ]; then say "OK    $line"; else say "FAIL  $line rc=$rc (see $log)"; fi
done < "$STEPS"
say "campaign: steps file exhausted ($n entries)"

# a compact matrix status for the reader
if ls "$RUNROOT"/results-* >/dev/null 2>&1; then :; fi
find "$RUNROOT" -maxdepth 2 -name summary.json 2>/dev/null | sort | while read -r s; do
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("VERDICT", d.get("run_id","?"), "::", d.get("headline",""))' "$s"
done | tee -a "$RUNROOT/campaign.log"
say "campaign: done"
