#!/bin/bash
# tick.sh -- the cron and queue arms (plan section 3.3) on the perf host.
#
#   bench/tick.sh <runtime> <arm> [ticks] [outdir]
#     runtime: freeunit | nginx-fpm | apache
#     arm:     A  = drush core:cron / queue:run  (cold one-shot CLI)
#              B  = GET /cron/{key} and /fu-queue-drain/{key}/50 on the web runtime
#
# One row per tick in <outdir>/ticks.tsv:
#   tick arm runtime trigger wall_s cpu_ns procs_before procs_after status
# cpu_ns is the runtime container's cgroup schedstat delta over the tick, so the
# row carries the job's own CPU even when the tick returns before the job ends
# (arm B detaches on FreeUnit, so wall_s there is the trigger latency, not the job).
#
# Arm C (fork-warm) is FreeUnit-only and needs the fork_spawn app wired into a
# second target; not in phase 0. The gist's fork_spawn.php lives in apps/.
set -euo pipefail

RUNTIME=${1:?usage: tick.sh <runtime> <arm> [ticks] [outdir]}
ARM=${2:?usage: tick.sh <runtime> <arm> [ticks] [outdir]}
TICKS=${3:-20}
OUTDIR=${4:-/data/projects/benchmarks-drupal/run/ticks-$(date -u +%Y%m%dT%H%M%SZ)}
RUNROOT=${RUNROOT:-/data/projects/benchmarks-drupal/run}
SITE=${SITE:-11.4}
SITE_DIR="$RUNROOT/site/$SITE"
PORT=${PORT:-8081}
CRON_KEY=${CRON_KEY:-benchmark}
DRAIN_N=${DRAIN_N:-50}
DB_IMAGE=${DB_IMAGE:-mariadb:10.11}
TOOL_IMAGE=${TOOL_IMAGE:-drupal-bench-freeunit:1.37.0}
NET="dbnet-tick-$$"
DBC="db-tick-$$"
RTC="rt-tick-$$"

case "$RUNTIME" in
freeunit)  IMG=drupal-bench-freeunit:1.37.0 ;;
nginx-fpm) IMG=drupal-bench-fpm:8.5 ;;
apache)    IMG=drupal-bench-apache:8.5 ;;
*) echo "tick.sh: unknown runtime $RUNTIME" >&2; exit 2 ;;
esac
case "$ARM" in A|B) ;; *) echo "tick.sh: unknown arm $ARM" >&2; exit 2 ;; esac

mkdir -p "$OUTDIR"
printf 'tick\tarm\truntime\ttrigger\twall_s\tcpu_ns\tprocs_before\tprocs_after\tstatus\n' > "$OUTDIR/ticks.tsv"

cleanup() { docker rm -f "$RTC" "$DBC" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker network create "$NET" >/dev/null
DBCVOL=${DBCVOL:-drupal-bench-db-${SITE:-default}}
docker run -d --name "$DBC" --network "$NET" --cpuset-cpus "${DB_CPUS:-4,5}" --label bench-run=tick \
    -v "$DBCVOL:/var/lib/mysql" \
    --network-alias db -e MARIADB_ROOT_HOST=% -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=drupal "$DB_IMAGE" >/dev/null
for i in $(seq 60); do docker exec "$DBC" mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 1; done
for c in $(docker ps -q -f "publish=$PORT"); do docker rm -f "$c" >/dev/null 2>&1 || true; done
docker run -d --name "$RTC" --network "$NET" --cpuset-cpus "${SERVER_CPUS:-0,1}" --label bench-run=tick \
    -p "127.0.0.1:$PORT:80" -v "$SITE_DIR:/app" \
    -v "$RUNROOT/runtimes/freeunit.json:/docker-entrypoint.d/config.json:ro" \
    -v "$RUNROOT/apps:/app/apps:ro" "$IMG" >/dev/null
for i in $(seq 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)" = 200 ] && break
    sleep 1
done

cg_pids() {
    local pid cg
    pid=$(docker inspect -f '{{.State.Pid}}' "$1" 2>/dev/null) || return 0
    [ -n "$pid" ] && [ "$pid" != 0 ] || return 0
    cg=$(sed -n 's/^0:://p' "/proc/$pid/cgroup" 2>/dev/null)
    if [ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/cgroup.procs" ]; then
        cat "/sys/fs/cgroup$cg/cgroup.procs"
    else
        ps -eo pid=,ppid= | awk -v m="$pid" '{p[$1]=$2} END{for(x in p){y=x; while(y!=""&&y!=0&&y!=m)y=p[y]; if(y==m)print x}}'
    fi
}
oncpu_ns() {
    local p t s=0 v
    for p in $*; do for t in /proc/$p/task/*/schedstat; do read -r v _ < "$t" 2>/dev/null && s=$((s+v)); done; done
    echo "$s"
}

drush_run() {  # command string -> wall seconds on stdout
    local cmd=$1
    docker exec "$RTC" sh -c "cd /app && ./vendor/bin/drush $cmd" >/dev/null 2>&1
}
fill_queue() {
    docker exec "$RTC" sh -c "cd /app && ./vendor/bin/drush php:eval '\$q=\Drupal::queue(\"fu_queue_test\"); for(\$i=0;\$i<$DRAIN_N*3;\$i++){\$q->createItem([\"us\"=>1000]);} echo \$q->numberOfItems();'" >/dev/null 2>&1 || true
}

for t in $(seq 1 "$TICKS"); do
    before=$(cg_pids "$RTC" | wc -l)
    case "$ARM" in
    A)
        if [ $((t % 2)) = 1 ]; then trigger="drush core:cron"; cmd="core:cron -y"
        else trigger="drush queue:run fu_queue_test"; fill_queue; cmd="queue:run fu_queue_test --time-limit=55"; fi
        start=$(date +%s.%N); cpu0=$(oncpu_ns $(cg_pids "$RTC"))
        status=ok; drush_run "$cmd" || status=fail
        cpu1=$(oncpu_ns $(cg_pids "$RTC")); end=$(date +%s.%N)
        ;;
    B)
        if [ $((t % 2)) = 1 ]; then url="http://127.0.0.1:$PORT/cron/$CRON_KEY"; trigger="GET /cron/$CRON_KEY"
        else url="http://127.0.0.1:$PORT/fu-queue-drain/$CRON_KEY/$DRAIN_N"; trigger="GET /fu-queue-drain/$CRON_KEY/$DRAIN_N"; fi
        start=$(date +%s.%N); cpu0=$(oncpu_ns $(cg_pids "$RTC"))
        status=ok; curl -s -o /dev/null --max-time 120 "$url" || status=fail
        cpu1=$(oncpu_ns $(cg_pids "$RTC")); end=$(date +%s.%N)
        ;;
    esac
    after=$(cg_pids "$RTC" | wc -l)
    wall=$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.4f", b-a}')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$ARM" "$RUNTIME" "$trigger" "$wall" "$((cpu1-cpu0))" "$before" "$after" "$status" >> "$OUTDIR/ticks.tsv"
    echo "tick $t/$TICKS $RUNTIME $ARM $trigger wall=${wall}s status=$status procs=$before->$after"
done
# cron lock: Drupal locks cron for 900 s; a second tick inside that window is a
# no-op that still reports success. Note it so the reader excludes those rows.
if [ "$ARM" = A ]; then
    docker exec "$RTC" sh -c "cd /app && ./vendor/bin/drush php:eval '\Drupal::lock()->release(\"cron\");'" >/dev/null 2>&1 || true
fi
echo "tick.sh: done -> $OUTDIR/ticks.tsv"
