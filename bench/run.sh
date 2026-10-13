#!/bin/bash
# run.sh -- run one benchmark job on the perf host: claim, idle gate, cells.sh,
# perf-compare.py, summary.json + compare.txt + meta.txt in $RUNROOT/<run-id>/.
#
#   bench/run.sh bench/jobs/02-front-anon-freeunit-vs-fpm.job [--no-gate]
#
# The job file is KEY=value; see bench/jobs/*.job. This script is the only place
# that sets RUN_ID or touches the claim file.
# Numeric output must not follow the caller locale (awk/printf would use ",").
export LC_ALL=C
set -euo pipefail

JOBFILE=${1:?usage: run.sh <job file> [--no-gate]}
NOGATE=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
RUNROOT=${RUNROOT:-/data/projects/benchmarks-drupal/run}
CLAIM_DIR=${CLAIM_DIR:-/data/projects}
IDLE_MAX_PCT=${IDLE_MAX_PCT:-5}
SHORT_JOB_MIN=${SHORT_JOB_MIN:-15}
PERF_WINDOW=${PERF_WINDOW:-01:00-06:00}

# A caller may pin the CPU sets (another host has a different topology); those
# values win over the job file, which carries the reference host's defaults.
ENV_SERVER_CPUS=${SERVER_CPUS:-}
ENV_LOAD_CPUS=${LOAD_CPUS:-}
ENV_DB_CPUS=${DB_CPUS:-}
ENV_BASE_PORT=${BASE_PORT:-}

# defaults, overridden by the job file
JOB="" PHASES="null ab" WORKLOAD=drupal-front RUNTIME_A=freeunit RUNTIME_B=nginx-fpm
SITE=11.4 CONNS=32 DUR=8 WARM=2 REPS=2 RATE="" APP_PROCS=20 PERF=1 AE=""
SERVER_CPUS=0,1 LOAD_CPUS=2,3,6,7 DB_CPUS=4,5 BASE_PORT=8081
DB=${DB:-mysql}
DB_A=${DB:-mysql}
NULL_LIMIT_PCT=5 PRIMARY=s_instructions EXPECT="" FALSIFY="" ISSUE=""
DECOMPOSE=${DECOMPOSE:-0}
EXTRA_COOKIE_BYTES=${EXTRA_COOKIE_BYTES:-0}
OHA=${OHA:-/data/projects/cache/cargo/bin/oha}
PERF_IMAGE=${PERF_IMAGE:-freeunit-perf-lab:1}
# shellcheck disable=SC1090
. "$JOBFILE"

[ -n "$ENV_SERVER_CPUS" ] && SERVER_CPUS=$ENV_SERVER_CPUS
[ -n "$ENV_LOAD_CPUS" ] && LOAD_CPUS=$ENV_LOAD_CPUS
[ -n "$ENV_DB_CPUS" ] && DB_CPUS=$ENV_DB_CPUS
[ -n "$ENV_BASE_PORT" ] && BASE_PORT=$ENV_BASE_PORT
# The idle gate runs before the cell port is computed, so keep the default here.
PORT=${PORT:-$BASE_PORT}

# The host is part of the identity: absolute means from two boxes must never be
# pooled, and the page groups by it.
BENCH_HOST=${BENCH_HOST:-$(hostname -s)}
HOSTSLUG=$(printf '%s' "$BENCH_HOST" | tr -c 'a-zA-Z0-9' '-')
RUN_ID="${JOB}-${HOSTSLUG}-$(date -u +%Y%m%dT%H%M%SZ)"
OUTDIR="$RUNROOT/$RUN_ID"
DBCLAIM="$CLAIM_DIR/CLAIMED-$${LAB_WHO:-$(whoami)}-drupal-$JOB"
mkdir -p "$OUTDIR"

cleanup() {
    docker rm -f $(docker ps -aq --filter "label=bench-run=$RUN_ID") >/dev/null 2>&1 || true
    rm -f "$DBCLAIM"
}
trap cleanup EXIT

# One measured job at a time on the box, and no leftovers from a killed run: a
# second MariaDB on the same data volume is a corruption risk, so sweep first.
exec 9>"$RUNROOT/.run.lock"
flock -n 9 || { echo "run.sh: another bench/run.sh holds the lock" >&2; exit 1; }
docker rm -f $(docker ps -aq --filter "label=bench-run") >/dev/null 2>&1 || true
docker rm -f $(docker ps -aq --filter "name=db-bench-" --filter "name=rt-" --filter "name=perf-") >/dev/null 2>&1 || true

echo "$(date -u +%FT%TZ) $$ $(whoami) drupal-bench $JOB $RUN_ID" > "$DBCLAIM" 2>/dev/null || true
cp "$JOBFILE" "$OUTDIR/job.txt"

# ---- idle gate: no other container is running and the box is quiet -------------

# Busy percent on the CPUs this measurement uses, plus the cell port; a build host
# with dozens of idle containers is not "busy" if none of them touches these.
read_cpu_stat() { awk -v c="$1" '$1 == "cpu" c { t=0; for (i=2;i<=NF;i++) t+=$i; print t, $5 }' /proc/stat; }
cpu_busy() {  # cpus -> busiest selected cpu, in percent
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
port_busy() { ss -ltn 2>/dev/null | awk -v p=":$PORT" '$4 ~ p "$" {found=1} END{exit !found}'; }

if [ "$NOGATE" != "--no-gate" ]; then
    # a 2 s busy sample from /proc/stat, like the lab
    for try in 1 2 3; do
        busy=$(cpu_busy "$SERVER_CPUS,$DB_CPUS,$LOAD_CPUS")
        if port_busy; then
            echo "run.sh: idle gate try=$try busy=${busy}% port=$PORT in use"
        else
            echo "run.sh: idle gate try=$try busy=${busy}% port=$PORT free containers=$(docker ps -q | wc -l) (max ${IDLE_MAX_PCT}%)"
            if awk -v p="$busy" -v m="$IDLE_MAX_PCT" 'BEGIN{exit !(p <= m)}'; then
                gate_ok=1; break
            fi
        fi
        sleep 12
    done
    [ "${gate_ok:-0}" = 1 ] || { echo "run.sh: box busy, refusing" >&2; exit 1; }
fi

mkdir -p "$OUTDIR"
# The database backend is part of the site key: mysql keeps the bare name, every
# other backend has its own directory (site-build.sh uses the same rule).
DB=${DB:-mysql}
SITEKEY=$SITE
[ "$DB" != mysql ] && SITEKEY="$SITE-$DB"
SITE_DIR="$RUNROOT/site/$SITEKEY"
# a job may name a second site/backend (SITE_B/DB_B) to compare two databases in
# one job: then B gets its own site directory and cookie
SITE_B=${SITE_B:-$SITE}; DB_B=${DB_B:-$DB}
SITEKEY_B=$SITE_B
[ "$DB_B" != mysql ] && SITEKEY_B="$SITE_B-$DB_B"
SITE_DIR_B="$RUNROOT/site/$SITEKEY_B"
OUT="$OUTDIR"; RESROOT="$RUNROOT"
COOKIE_FILE="$SITE_DIR/cookie.txt"; COOKIE_FILE_B="$SITE_DIR_B/cookie.txt"
export SITE_DIR SITE_DIR_A SITE_DIR_B OUT RESROOT COOKIE_FILE COOKIE_FILE_B JOB RUN_ID PHASES WORKLOAD
export RUNTIME_A RUNTIME_B SITE CONNS DUR WARM REPS RATE APP_PROCS PERF AE DECOMPOSE EXTRA_COOKIE_BYTES DB DB_A DB_B
# cells.sh has its own OHA default of bare "oha" on PATH; the host that has oha
# outside PATH answered "no oha (oha)" until this was exported.
export OHA
export SERVER_CPUS LOAD_CPUS DB_CPUS BASE_PORT
bash "$HERE/cells.sh" >"$OUTDIR/cells.log" 2>&1 || { tail -n 20 "$OUTDIR/cells.log" >&2; exit 1; }

cp -f "$RUNROOT/site/$SITE/meta.txt" "$OUTDIR/site-meta.txt" 2>/dev/null || true
{
    echo "job=$JOB"
    echo "run_id=$RUN_ID"
    echo "host=$BENCH_HOST"
    echo "date=$(date -u +%FT%TZ)"
    echo "workload=$WORKLOAD"
    echo "runtime_a=$RUNTIME_A"
    echo "runtime_b=$RUNTIME_B"
    echo "site=$SITE"
    echo "db=$DB"
    [ "$SITE_DIR_B" != "$SITE_DIR" ] || [ "$DB_B" != "$DB" ] && {
        echo "site_b=$SITE_B"
        echo "db_b=$DB_B"
    }
    echo "phases=$PHASES conns=$CONNS dur=$DUR warm=$WARM reps=$REPS rate=$RATE"
    echo "server_cpus=$SERVER_CPUS load_cpus=$LOAD_CPUS db_cpus=$DB_CPUS"
    echo "governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
    echo "epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -r)"
    echo "oha=$($OHA --version 2>/dev/null | head -1)"
    echo "perf_image=$(docker image inspect -f '{{.Id}}' "$PERF_IMAGE" 2>/dev/null | cut -c8-19)"
    echo "freeunit_image=$(docker image inspect -f '{{.Id}}' drupal-bench-freeunit:1.37.0 2>/dev/null | cut -c8-19)"
    echo "freeunit_master_sha=$(cat "$RUNROOT/freeunit-master-sha" 2>/dev/null || echo unknown)"
    echo "freeunit_master_image=$(docker image inspect -f '{{.Id}}' drupal-bench-freeunit:master 2>/dev/null | cut -c8-19)"
    echo "freeunit_master_old_sha=$(cat "$RUNROOT/freeunit-master-old-sha" 2>/dev/null || echo unknown)"
    echo "freeunit_master_old_image=$(docker image inspect -f '{{.Id}}' drupal-bench-freeunit:master-old 2>/dev/null | cut -c8-19)"
    echo "fpm_image=$(docker image inspect -f '{{.Id}}' drupal-bench-fpm:8.5 2>/dev/null | cut -c8-19)"
    echo "apache_image=$(docker image inspect -f '{{.Id}}' drupal-bench-apache:8.5 2>/dev/null | cut -c8-19)"
    echo "mariadb_image=$(docker image inspect -f '{{.Id}}' mariadb:10.11 2>/dev/null | cut -c8-19)"
    echo "issue=$ISSUE"
    [ -n "$EXPECT" ] && echo "expect=$EXPECT"
    [ -n "$FALSIFY" ] && echo "falsify=$FALSIFY"
    sed -n '1,200p' "$OUTDIR/site-meta.txt" 2>/dev/null || true
} > "$OUTDIR/meta.txt"

python3 "$HERE/perf-compare.py" "$OUTDIR/results.tsv" --meta "$OUTDIR/meta.txt" \
    --json "$OUTDIR/summary.json" --primary "$PRIMARY" --null-limit "$NULL_LIMIT_PCT" \
    > "$OUTDIR/compare.txt" 2>&1 || true

verdict=$(python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("headline", ""))
except Exception:
    print("")' "$OUTDIR/summary.json" 2>/dev/null || true)
echo "run.sh: done -> $OUTDIR"
sed -n '1,40p' "$OUTDIR/compare.txt"
case "$verdict" in
INVALID*) echo "run.sh: INVALID result, exiting nonzero so the campaign retries it" >&2; exit 1 ;;
NO\ DATA*) echo "run.sh: NO DATA for the primary metric, exiting nonzero so the campaign retries it" >&2; exit 1 ;;
esac
