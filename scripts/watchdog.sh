#!/bin/bash
# watchdog.sh -- periodic health line for a running campaign, plus a stall flag.
#
#   scripts/watchdog.sh [INTERVAL_S] [RUNROOT]
#
# Every INTERVAL_S (default 120) it appends one line to campaign-health.log:
#   ts step=<current step> log_age=<s> containers=<n> load=<l> disk=<pct> status=<ok|stall|idle>
# It never kills or restarts anything: its job is to answer "is the job hanging?"
# from outside. STALL means the newest campaign log has not been written for
# more than STALL_S (default 1800) while containers are still up.
set -u
INTERVAL=${1:-120}
RUNROOT=${2:-/data/projects/benchmarks-drupal/run}
STALL_S=${STALL_S:-1800}
HEALTH="$RUNROOT/campaign-health.log"
mkdir -p "$RUNROOT"

while true; do
    step=$(tail -n 1 "$RUNROOT/campaign.done" 2>/dev/null | awk '{print $2}')
    newest=$(ls -t "$RUNROOT"/campaign-logs/*.log 2>/dev/null | head -1)
    age="n/a"
    [ -n "$newest" ] && age=$(( $(date +%s) - $(stat -c %Y "$newest") ))
    cont=$(docker ps -q 2>/dev/null | wc -l)
    load=$(awk '{print $1}' /proc/loadavg)
    disk=$(df --output=pcent /data 2>/dev/null | tail -1 | tr -d ' %')
    status=idle
    if [ "$age" != "n/a" ] && [ "$age" -gt "$STALL_S" ] && [ "$cont" -gt 0 ]; then status=stall; fi
    if [ "$cont" -gt 0 ] && [ "$age" != "n/a" ] && [ "$age" -le "$STALL_S" ]; then status=ok; fi
    printf '%s step=%s log_age=%ss containers=%s load=%s disk=%s%% status=%s\n' \
        "$(date -u +%FT%TZ)" "${step:-none}" "$age" "$cont" "$load" "$disk" "$status" >> "$HEALTH"
    sleep "$INTERVAL"
done
