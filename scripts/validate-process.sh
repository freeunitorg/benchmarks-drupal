#!/bin/bash
# validate-process.sh -- every five minutes, check the benchmark *processes*, not
# the numbers: is each loop alive, is its manifest where the loop expects it, is a
# running job still moving, and has anything been left behind.
#
#   scripts/validate-process.sh [--quiet] [--loop]
#
# Read-only by design: it never removes a container, never edits a manifest and
# never touches a box's state.  It exists because every failure that cost this
# suite real time looked like "the process was still there and the log stopped":
# an unbounded readiness curl (2h25m), a manifest that did not exist yet (one
# wasted quiet window), a stale `campaign.done` site step, and containers left by
# a killed job that then held the port.
#
# Problems go to run/validate.log; a problem that is new since the last pass also
# goes on the harness bus, so another agent sees it without reading this repo.
export LC_ALL=C
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
QUIET=0
LOOP=0
for a in "$@"; do
    case "$a" in
    --quiet) QUIET=1 ;;
    --loop) LOOP=1 ;;
    esac
done

LOG="$HERE/run/validate.log"
STATE="$HERE/run/validate.state"
BUS=${BUS:-/home/andy/www/freeunit-harness/run/inbox/bus.log}
mkdir -p "$HERE/run"
: >"$STATE.new"

# host | root | tmux session | loop log (relative to root) | manifests | job prefixes
# A session name of "-" means the box is not ours to run right now (claimed elsewhere):
# it is probed for leftovers and disk only, and never reported as a down loop.
BOXES=(
"pro4s-2|/data/projects/benchmarks-drupal|-|run/bench-loop.log|scripts/campaign.steps.master-bisect,scripts/campaign.steps.matrix-12,scripts/campaign.steps.apache|66-,67-,68-,69-,70-,71-,72-,73-,74-,76-,77-,78-,86-,87-"
"pro4s-4|/data/projects/benchmarks-drupal|wp|wp-loop.log|scripts/campaign.steps.wp|42-,43-,44-,45-,46-,47-,75-"
"o-build|/home/alpine/bench-arm|-|run/apache-arm-loop.log|scripts/campaign.steps.apache-arm|83-,84-,85-,88-,89-"
)

probe() {  # host root session logfile manifests
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$1" bash -s -- "$2" "$3" "$4" "$5" "$6" <<'REMOTE'
set -u
root=$1; session=$2; logf=$3; manifests=$4; prefixes=$5
cd "$root" 2>/dev/null || { echo "root=missing"; exit 0; }
echo "tmux_sessions=$(tmux ls 2>/dev/null | grep -c "^$session:")"
echo "log_age=$(( $(date +%s) - $(stat -c %Y "$logf" 2>/dev/null || echo 0) ))"
missing=""
for m in ${manifests//,/ }; do [ -f "$m" ] || missing="$missing $m"; done
echo "manifests_missing=$missing"
echo "done=$(grep -c "exit=0" run/campaign.done 2>/dev/null || echo 0)"
rem=0
# a failed step is not done: the line must say exit=0, or a job that keeps failing
# the idle gate looks complete and the validator stops watching it
for pre in ${prefixes//,/ }; do grep -qE "jobs/$pre[^ ]*\.job exit=0 " run/campaign.done 2>/dev/null || rem=$((rem+1)); done
echo "remaining=$rem"
echo "running_run=$(pgrep -fc "bench/run.s[h]" 2>/dev/null || echo 0)"
echo "oha=$(pgrep -xc oha 2>/dev/null || echo 0)"
echo "ours=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -cE "^(rt|db-bench|perf)-|db-wp")"
newest=$(ls -dt run/*/ 2>/dev/null | head -n1)
echo "newest_run=$(basename "${newest:-none}")"
echo "newest_cells_age=$(( $(date +%s) - $(stat -c %Y "${newest:-/nonexistent}cells.log" 2>/dev/null || echo 0) ))"
echo "running_job=$(ls -dt run/campaign-logs/*.log 2>/dev/null | head -n1 | xargs -r stat -c %Y 2>/dev/null || echo 0)"
echo "joblog=$(ls -t run/campaign-logs/*.log 2>/dev/null | head -n1 | xargs -r basename 2>/dev/null)"
echo "joblog_age=$(( $(date +%s) - $(ls -t run/campaign-logs/*.log 2>/dev/null | head -n1 | xargs -r stat -c %Y 2>/dev/null || echo 0) ))"
echo "port=$(ss -ltn 2>/dev/null | grep -c :8081)"
echo "disk_gb=$(df -Pk / | awk 'NR==2{printf "%d", $4/1048576}')"
REMOTE
}

report=""
problems=""
for row in "${BOXES[@]}"; do
    IFS='|' read -r host root session logf manifests prefixes <<<"$row"
    out=$(probe "$host" "$root" "$session" "$logf" "$manifests" "$prefixes" 2>/dev/null)
    if [ -z "$out" ]; then
        problems="$problems $host:unreachable"
        report="$report\n$host: UNREACHABLE"
        continue
    fi
    eval "$(printf '%s\n' "$out" | sed 's/^\([a-z_]*\)=\(.*\)$/\1="\2"/')" 2>/dev/null || true
    p=""
    if [ "$session" = "-" ]; then
        :   # not ours to run: no loop expectation, only leftovers/disk/port matter
        log_age=0
    else
        [ "${tmux_sessions:-0}" = 1 ] || p="$p session-down"
    fi
    [ -n "${manifests_missing// /}" ] && p="$p manifest-missing:${manifests_missing// /,}"
    # A job that is running but whose log has not moved for 25 minutes is stuck:
    # the shape of the unbounded curl.  Gate waits print every minute, and a job
    # logs per cell, so 25 minutes of silence is never normal.
    if [ "${running_run:-0}" -gt 0 ] && [ "${joblog_age:-0}" -gt 1500 ]; then
        p="$p job-stalled:${joblog:-?}:$((joblog_age/60))m"
    fi
    # Containers with nothing running: leftovers that will hold the port.
    if [ "${running_run:-0}" -eq 0 ] && [ "${ours:-0}" -gt 0 ]; then
        p="$p leftovers:${ours}"
    fi
    [ "${port:-0}" -gt 0 ] && [ "${running_run:-0}" -eq 0 ] && p="$p port-8081-held"
    [ "${disk_gb:-99}" -lt 5 ] && p="$p disk-low:${disk_gb}G"
    # A loop we do not run in tmux has no session to check: its log is the liveness
    # signal, and the gate writes to it about once a minute.
    if [ "$session" = "-" ]; then
        [ "${log_age:-0}" -gt 900 ] && p="$p loop-log-stale:$((log_age/60))m"
    else
        [ "${log_age:-0}" -gt 1800 ] && p="$p loop-log-stale:$((log_age/60))m"
    fi

    line="$host session=$([ "$session" = "-" ] && echo n/a || { [ "${tmux_sessions:-0}" = 1 ] && echo up || echo DOWN; }) remaining=${remaining:-?} done=${done:-?} running=${running_run:-?} ours=${ours:-?} log=$((${log_age:-0}/60))m job=$([ "${running_run:-0}" -gt 0 ] && echo "${joblog:-?}($((joblog_age/60))m)" || echo idle)${p:+ PROBLEM:$p}"
    report="$report\n$line"
    [ -n "$p" ] && problems="$problems $host:$p"
    printf '%s|%s\n' "$host" "$p" >>"$STATE.new"
done

now=$(date -u +%FT%TZ)
[ "$QUIET" = 1 ] || printf "%b\n" "$report"
printf '%s%s\n' "$now" "$(printf '%b' "$report" | sed 's/^/\n  /')" >>"$LOG"

# The bus only sees a problem that is new, or a recovery, so a stuck box does not
# repeat itself every five minutes.
new_problems=$(comm -13 <(sort "$STATE" 2>/dev/null) <(sort "$STATE.new") 2>/dev/null | grep -v '|$' || true)
recovered=$(comm -23 <(sort "$STATE" 2>/dev/null) <(sort "$STATE.new") 2>/dev/null | grep -v '|$' || true)
if [ -n "$new_problems" ]; then
    printf '%s %s validate: NEW %s\n' "$now" "${INBOX_SENDER:-strace@pi}" "$new_problems" >>"$BUS" 2>/dev/null || true
    echo "validate: NEW PROBLEM $new_problems"
fi
if [ -n "$recovered" ]; then
    printf '%s %s validate: recovered %s\n' "$now" "${INBOX_SENDER:-strace@pi}" "$recovered" >>"$BUS" 2>/dev/null || true
    echo "validate: recovered $recovered"
fi
mv "$STATE.new" "$STATE"
[ -z "$problems" ] && [ "$QUIET" = 0 ] && echo "validate: all loops nominal"
[ -z "$problems" ]
