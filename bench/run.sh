#!/bin/bash
# run.sh -- run one benchmark job on the perf host: claim, idle gate, cells.sh,
# perf-compare.py, summary.json + compare.txt + meta.txt in $RUNROOT/<run-id>/.
#
#   bench/run.sh bench/jobs/02-front-anon-freeunit-vs-fpm.job [--no-gate]
#
# The job file is KEY=value; see bench/jobs/*.job. This script is the only place
# that sets RUN_ID or touches the claim file.
set -euo pipefail

JOBFILE=${1:?usage: run.sh <job file> [--no-gate]}
NOGATE=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
RUNROOT=${RUNROOT:-/data/projects/benchmarks-drupal/run}
CLAIM_DIR=${CLAIM_DIR:-/data/projects}
IDLE_MAX_PCT=${IDLE_MAX_PCT:-5}
SHORT_JOB_MIN=${SHORT_JOB_MIN:-15}
PERF_WINDOW=${PERF_WINDOW:-01:00-06:00}

# defaults, overridden by the job file
JOB="" PHASES="null ab" WORKLOAD=drupal-front RUNTIME_A=freeunit RUNTIME_B=nginx-fpm
SITE=11.4 CONNS=32 DUR=8 WARM=2 REPS=2 RATE="" APP_PROCS=20 PERF=1 AE=""
SERVER_CPUS=0,1 LOAD_CPUS=2,3,6,7 DB_CPUS=4,5 BASE_PORT=8081
DB=${DB:-mysql}
NULL_LIMIT_PCT=5 PRIMARY=s_instructions EXPECT="" FALSIFY="" ISSUE=""
DECOMPOSE=${DECOMPOSE:-0}
EXTRA_COOKIE_BYTES=${EXTRA_COOKIE_BYTES:-0}
OHA=${OHA:-/data/projects/cache/cargo/bin/oha}
PERF_IMAGE=${PERF_IMAGE:-freeunit-perf-lab:1}
# shellcheck disable=SC1090
. "$JOBFILE"

RUN_ID="${JOB}-$(date -u +%Y%m%dT%H%M%SZ)"
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
if [ "$NOGATE" != "--no-gate" ]; then
    # a 2 s busy sample from /proc/stat, like the lab
    # A previous job's database can still be winding down; sample three times and
    # take the first quiet one instead of failing a job on a decaying tail.
    for try in 1 2 3; do
        s0=$(awk '/^cpu /{t=0; for (i=2;i<=NF;i++) t+=$i; print t, $5}' /proc/stat)
        sleep 3
        s1=$(awk '/^cpu /{t=0; for (i=2;i<=NF;i++) t+=$i; print t, $5}' /proc/stat)
        pct=$(awk -v a="$s0" -v b="$s1" 'BEGIN { split(a,x," "); split(b,y," "); dt=y[1]-x[1]; di=y[2]-x[2]; printf "%.1f", (dt > 0 ? 100 * (1 - di / dt) : 0) }')
        others=$(docker ps -q | wc -l)
        echo "run.sh: idle gate try=$try busy=${pct}% containers=$others (max ${IDLE_MAX_PCT}%)"
        if awk -v p="$pct" -v m="$IDLE_MAX_PCT" 'BEGIN{exit !(p <= m)}'; then
            gate_ok=1; break
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
OUT="$OUTDIR"; RESROOT="$RUNROOT"; COOKIE_FILE="$SITE_DIR/cookie.txt"
export SITE_DIR OUT RESROOT COOKIE_FILE JOB RUN_ID PHASES WORKLOAD
export RUNTIME_A RUNTIME_B SITE CONNS DUR WARM REPS RATE APP_PROCS PERF AE DECOMPOSE EXTRA_COOKIE_BYTES DB
export SERVER_CPUS LOAD_CPUS DB_CPUS BASE_PORT
bash "$HERE/cells.sh" >"$OUTDIR/cells.log" 2>&1 || { tail -n 20 "$OUTDIR/cells.log" >&2; exit 1; }

cp -f "$RUNROOT/site/$SITE/meta.txt" "$OUTDIR/site-meta.txt" 2>/dev/null || true
{
    echo "job=$JOB"
    echo "run_id=$RUN_ID"
    echo "date=$(date -u +%FT%TZ)"
    echo "workload=$WORKLOAD"
    echo "runtime_a=$RUNTIME_A"
    echo "runtime_b=$RUNTIME_B"
    echo "site=$SITE"
    echo "db=$DB"
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
esac
