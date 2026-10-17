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
# Numeric output must not follow the caller locale (awk/printf would use ",").
#
# Order the steps file with the cell you most want answered first. The idle gate
# needs N consecutive quiet samples, so on a box shared with another session's
# containers it may not open for hours, and two gate-waiting campaigns on one box
# starve each other. A step that never starts is a step with no result.
export LC_ALL=C
set -u

STEPS=${1:-$(cd "$(dirname "$0")/.." && pwd)/scripts/campaign.steps}
RUNROOT=${2:-/data/projects/benchmarks-drupal/run}
REPO=$(cd "$(dirname "$0")/.." && pwd)
DONE="$RUNROOT/campaign.done"
mkdir -p "$RUNROOT"
touch "$DONE"

say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$RUNROOT/campaign.log"; }

# Hard stop: the box is granted until DEADLINE_UTC.  The default is six hours from now,
# not a fixed date: a fixed date becomes a past date, and a past deadline skips every
# step (the check below makes that a fatal error instead).  DEADLINE_UTC=none runs
# without a bound, and a step that would start after it is recorded as skipped, so a
# rerun resumes.
DEADLINE_UTC=${DEADLINE_UTC:-$(date -u -d '+6 hours' +%FT%TZ)}
past_deadline() {
    case "${DEADLINE_UTC}" in ""|none) return 1 ;; esac
    [ "$(date -u +%s)" -ge "$(date -u -d "$DEADLINE_UTC" +%s 2>/dev/null || echo 0)" ]
}

# A deadline that has already passed stops the loop at the very first step, and
# the log then reads like a steps file that ran out -- which is how a relaunch
# after a night's work measures nothing at all and reports nothing wrong. The
# default above is a fixed date, so this is the normal case, not a rare one. Say
# so loudly, and name the fix. DEADLINE_UTC=none means no deadline.
if past_deadline; then
    say "FATAL DEADLINE_UTC=$DEADLINE_UTC is already past: every step would be skipped"
    say "  relaunch with DEADLINE_UTC=$(date -u -d '+6 hours' +%FT%TZ), or DEADLINE_UTC=none"
    exit 2
fi

# The runtime configs cells.sh mounts live in $RUNROOT/runtimes; refresh them from
# the repository every run so a config fix (e.g. the opcache string bug) cannot be
# shadowed by a stale copy.
mkdir -p "$RUNROOT/runtimes"
cp -f "$REPO"/docker/runtimes/*.json "$RUNROOT/runtimes/"
cp -f "$REPO"/apps/* "$RUNROOT/apps/" 2>/dev/null || { mkdir -p "$RUNROOT/apps"; cp -f "$REPO"/apps/* "$RUNROOT/apps/"; }

# only a successful step counts as done, so a failure is retried on the next run
done_already() { grep -qF " $1 exit=0 " "$DONE" 2>/dev/null; }
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
    site:*)  SITE_DB=${line#site:}
             IFS=: read -r SITE SITEDB <<<"$SITE_DB"
             export DB="$SITEDB"
             if [ "$SITE" = symfony ]; then
                 bash "$REPO/scripts/site-build-symfony.sh" "$RUNROOT" >>"$log" 2>&1 || rc=$?
             elif [ "$SITE" = hello ]; then
                 bash "$REPO/scripts/site-build-hello.sh" "$RUNROOT" >>"$log" 2>&1 || rc=$?
             elif [ "$SITE" = wp ]; then
                 bash "$REPO/scripts/site-build-wp.sh" "$RUNROOT" >>"$log" 2>&1 || rc=$?
             elif [ "$SITE" = wp-persistent ]; then
                 WP_PERSISTENT=1 bash "$REPO/scripts/site-build-wp.sh" "$RUNROOT" >>"$log" 2>&1 || rc=$?
             else
                 bash "$REPO/scripts/site-build.sh" "$SITE" "$RUNROOT" >>"$log" 2>&1 || rc=$?
             fi ;;
    job:*)   job=${line#job:}
             # a job file names its own database; never inherit the previous step's
             unset DB
             RUNROOT="$RUNROOT" bash "$REPO/bench/run.sh" "$REPO/$job" >>"$log" 2>&1 || rc=$? ;;
    ticks:*) rest=${line#ticks:}
             IFS=: read -r rt arm ticks site db <<<"$rest"
             tickdir="$RUNROOT/ticks-$rt-$arm-$site${db:+-$db}-$(date -u +%Y%m%dT%H%M%SZ)"
             SITE="$site" DB="${db:-}" bash "$REPO/bench/tick.sh" "$rt" "$arm" "$ticks" "$tickdir" >>"$log" 2>&1 || rc=$?
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
