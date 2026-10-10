#!/usr/bin/env bash
# wait-idle.sh -- wait for the perf host to be quiet, build the current images,
# then run a campaign steps file. One job per box: this refuses to start while
# anyone else's containers are up, and waits through a decay window so a job that
# is still winding down does not count as free.
#
#   scripts/wait-idle.sh <steps-file> [quiet-checks] [interval-seconds]
#
# Progress goes to stdout; run it under tmux with a log file.
# Numeric output must not follow the caller locale (awk/printf would use ",").
export LC_ALL=C
set -u

STEPS=${1:?usage: wait-idle.sh <steps-file> [quiet-checks] [interval]}
QUIET_NEEDED=${2:-3}
INTERVAL=${3:-60}
IDLE_MAX_PCT=${IDLE_MAX_PCT:-5}
SERVER_CPUS=${SERVER_CPUS:-0,1}
LOAD_CPUS=${LOAD_CPUS:-2,3,6,7}
DB_CPUS=${DB_CPUS:-4,5}
PORT=${BASE_PORT:-8081}
RUNROOT=${RUNROOT:-/data/projects/benchmarks-drupal/run}
H=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$RUNROOT"

# Busy percent on the CPUs a measurement actually uses, not the whole box: on a
# build host with dozens of idle containers the box-wide number is meaningless,
# and a core outside SERVER_CPUS/DB_CPUS/LOAD_CPUS cannot affect the cells.
read_cpu_stat() { awk -v c="$1" '$1 == "cpu" c { t=0; for (i=2;i<=NF;i++) t+=$i; print t, $5 }' /proc/stat; }

cpu_busy() {  # cpus -> the busiest selected cpu, in percent
    local cpus=$1 out=0 cpu a b t0 i0 t1 i1 v
    declare -A A
    for cpu in ${cpus//,/ }; do A[$cpu]=$(read_cpu_stat "$cpu"); done
    sleep 3
    for cpu in ${cpus//,/ }; do
        b=$(read_cpu_stat "$cpu")
        set -- ${A[$cpu]}; t0=$1; i0=$2
        set -- $b; t1=$1; i1=$2
        v=$(awk -v t=$((t1 - t0)) -v i=$((i1 - i0)) 'BEGIN{printf "%.1f", (t > 0 ? 100 * (1 - i / t) : 0)}')
        out=$(awk -v a="$out" -v b="$v" 'BEGIN{print (b > a ? b : a)}')
    done
    echo "$out"
}

# The cell port must be free; that is what a leftover container would break.
port_busy() { ss -ltn 2>/dev/null | awk -v p=":$PORT" '$4 ~ p "$" {found=1} END{exit !found}'; }

gate_quiet() {
    local busy
    busy=$(cpu_busy "$SERVER_CPUS,$DB_CPUS,$LOAD_CPUS")
    if port_busy; then
        echo "busy=${busy}% port=$PORT IN USE"
        return 1
    fi
    echo "busy=${busy}% port=$PORT free containers=$(docker ps -q | wc -l)"
    awk -v b="$busy" -v m="$IDLE_MAX_PCT" 'BEGIN{exit !(b <= m)}'
}

quiet=0
while :; do
    if gate_quiet; then
        quiet=$((quiet + 1))
    else
        quiet=0
    fi
    echo "$(date -u +%FT%TZ) quiet=$quiet/$QUIET_NEEDED"
    [ "$quiet" -ge "$QUIET_NEEDED" ] && break
    sleep "$INTERVAL"
done

echo "$(date -u +%FT%TZ) box idle: building the runtime images"
cd "$H"
bin/drupal-bench build > "$RUNROOT/wait-idle-build.log" 2>&1 \
    || echo "$(date -u +%FT%TZ) WARNING image build failed; running anyway (see wait-idle-build.log)"

echo "$(date -u +%FT%TZ) starting $STEPS"
exec scripts/campaign.sh "$STEPS" "$RUNROOT"
