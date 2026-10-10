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
REPO=$(dirname "$HERE")
RUNROOT=${RUNROOT:-/data/projects/benchmarks-drupal/run}
CLAIM_DIR=${CLAIM_DIR:-/data/projects}
IDLE_MAX_PCT=${IDLE_MAX_PCT:-5}
SHORT_JOB_MIN=${SHORT_JOB_MIN:-15}
PERF_WINDOW=${PERF_WINDOW:-01:00-06:00}

# defaults, overridden by the job file
JOB= PHASES="null ab" WORKLOAD=drupal-front RUNTIME_A=freeunit RUNTIME_B=nginx-fpm
SITE=11.4 CONNS=32 DUR=8 WARM=2 REPS=2 RATE= APP_PROCS=20 PERF=1 AE=
SERVER_CPUS=0,1 LOAD_CPUS=2,3,6,7 DB_CPUS=4,5 BASE_PORT=8081
NULL_LIMIT_PCT=5 PRIMARY=s_instructions EXPECT= FALSIFY= ISSUE= NOTES=
# shellcheck disable=SC1090
. "$JOBFILE"

RUN_ID="${JOB}-$(date -u +%Y%m%dT%H%M%SZ)"
OUTDIR="$RUNROOT/$RUN_ID"
DBCLAIM="$CLAIM_DIR/CLAIMED-$${LAB_WHO:-$(whoami)}-drupal-$JOB"
mkdir -p "$OUTDIR"

cleanup() { rm -f "$DBCLAIM"; }
trap cleanup EXIT

echo "$(date -u +%FT%TZ) $$ $(whoami) drupal-bench $JOB $RUN_ID" > "$DBCLAIM" 2>/dev/null || true
cp "$JOBFILE" "$OUTDIR/job.txt"

# ---- idle gate: no other container is running and the box is quiet -------------
if [ "$NOGATE" != "--no-gate" ]; then
    # a 2 s busy sample from /proc/stat, like the lab
    read -r _ a b c d e f g <<<"$(awk '/^cpu /{print}' /proc/stat)"
    t0=$((a + b + c + d + e + f + g)); i0=$d
    sleep 2
    read -r _ a b c d e f g <<<"$(awk '/^cpu /{print}' /proc/stat)"
    t1=$((a + b + c + d + e + f + g)); i1=$d
    pct=$(awk -v t=$((t1 - t0)) -v i=$((i1 - i0)) 'BEGIN{printf "%.1f", 100 * (1 - i / (t > 0 ? t : 1))}')
    others=$(docker ps -q | wc -l)
    echo "run.sh: idle gate busy=${pct}% containers=$others (max ${IDLE_MAX_PCT}%)"
    awk -v p="$pct" -v m="$IDLE_MAX_PCT" 'BEGIN{exit !(p <= m)}' || { echo "run.sh: box busy, refusing" >&2; exit 1; }
fi

mkdir -p "$OUTDIR"
SITE_DIR="$RUNROOT/site/$SITE" \
OUT="$OUTDIR" RESROOT="$RUNROOT" \
JOB="$JOB" RUN_ID="$RUN_ID" PHASES="$PHASES" WORKLOAD="$WORKLOAD" \
RUNTIME_A="$RUNTIME_A" RUNTIME_B="$RUNTIME_B" SITE="$SITE" \
CONNS="$CONNS" DUR="$DUR" WARM="$WARM" REPS="$REPS" RATE="$RATE" \
APP_PROCS="$APP_PROCS" PERF="$PERF" AE="$AE" \
SERVER_CPUS="$SERVER_CPUS" LOAD_CPUS="$LOAD_CPUS" DB_CPUS="$DB_CPUS" BASE_PORT="$BASE_PORT" \
COOKIE_FILE="$RUNROOT/site/$SITE/cookie.txt" \
bash "$HERE/cells.sh" >"$OUTDIR/cells.log" 2>&1 || { tail -n 20 "$OUTDIR/cells.log" >&2; exit 1; }

cp -f "$RUNROOT/site/$SITE/meta.txt" "$OUTDIR/site-meta.txt" 2>/dev/null || true
{
    echo "job=$JOB"
    echo "run_id=$RUN_ID"
    echo "date=$(date -u +%FT%TZ)"
    echo "workload=$WORKLOAD runtime_a=$RUNTIME_A runtime_b=$RUNTIME_B site=$SITE"
    echo "phases=$PHASES conns=$CONNS dur=$DUR warm=$WARM reps=$REPS rate=$RATE"
    echo "server_cpus=$SERVER_CPUS load_cpus=$LOAD_CPUS db_cpus=$DB_CPUS"
    echo "governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
    echo "epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -r)"
    echo "oha=$(${OHA:-oha} --version 2>/dev/null | head -1)"
    echo "freeunit_image=$(docker image inspect -f '{{.Id}}' drupal-bench-freeunit:1.37.0 2>/dev/null | cut -c8-19)"
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

echo "run.sh: done -> $OUTDIR"
sed -n '1,40p' "$OUTDIR/compare.txt"
