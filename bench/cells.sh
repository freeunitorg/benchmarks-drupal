#!/bin/bash
# cells.sh -- the measured part of a Drupal benchmark job. Runs ON the perf host
# (not inside the lab container): each cell starts a fresh runtime container,
# warms it, then measures a fixed window with oha.
#
# Generalised from freeunit-harness tools/perf-lab/cells.sh: same results TSV
# schema (job phase side rev cell block slot metric value), same 8-cell
# X Y Y X / Y X X Y block design, same null phase, so tools/perf-compare.py
# validates the verdict unchanged. The A/B axis is the RUNTIME, not a unitd tree.
#
# CPU: server_us is /proc/<pid>/task/*/schedstat summed over every pid in the
# runtime container's cgroup (and separately for the database container), so
# nginx+fpm is one tree as the plan section 5.3 requires.
#
# Inputs (env): JOB RUN_ID WORKLOAD RUNTIME_A RUNTIME_B SITE PHASES CONNS DUR
# WARM REPS RATE APP_PROCS PERF AE SERVER_CPUS LOAD_CPUS DB_CPUS RUNROOT
# IMAGE_TAG FREEUNIT_CONFIG COOKIE_FILE NULL_GATE
# Optional: OHA (default: oha on PATH)
# Output: $RUNROOT/results.tsv
set -u
RESROOT="${RESROOT:-${RUNROOT:-/data/projects/benchmarks-drupal/run}}"
OUT="${OUT:-$RESROOT}/results.tsv"
OUTDIR=$(dirname "$OUT")
R=$(mktemp -d /tmp/drupal-bench.XXXXXX)
OHA=${OHA:-oha}
PERF_IMAGE=${PERF_IMAGE:-freeunit-perf-lab:1}
PERF_EVENTS=${PERF_EVENTS:-cycles,instructions,context-switches,cpu-migrations}
TAG=${IMAGE_TAG:-8.5}
PORT=${BASE_PORT:-8081}
COOKIE_HDR=""
[ -f "${COOKIE_FILE:-}" ] && COOKIE_HDR=$(awk '($1 ~ /^#HttpOnly_/ || $1 !~ /^#/) && NF >= 7 { printf "%s=%s; ", $6, $7 }' "$COOKIE_FILE")
CNAME="db-bench-$$"
NET="dbnet-$$"
ORDER=(X Y Y X Y X X Y)
SWAP=(Y X X Y X Y Y X)

die() { echo "cells.sh: $*" >&2; docker rm -f "$CNAME" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; exit 1; }
log() { echo "cells.sh: $*" >&2; }
printf 'job\tphase\tside\trev\tcell\tblock\tslot\tmetric\tvalue\n' > "$OUT"

command -v "$OHA" >/dev/null || die "no oha ($OHA)"
command -v docker >/dev/null || die "no docker"
[ -n "${SITE_DIR:-}" ] && [ -f "$SITE_DIR/web/index.php" ] || die "no installed site at SITE_DIR=$SITE_DIR"
if [ "$PERF" = 1 ]; then
    # the host's perf_event_paranoid blocks counters for the calling user; the
    # harness method is a PERFMON-capable container with the host pid namespace.
    docker run --rm --cap-add PERFMON --pid=host "$PERF_IMAGE" perf stat -e cycles true >/dev/null 2>&1 \
        || die "perf stat does not work in $PERF_IMAGE (needs --cap-add PERFMON)"
fi

image_for() {  # runtime family -> image
    case "$1" in
    freeunit)  echo "drupal-bench-freeunit:${FREEUNIT_TAG:-1.37.0}" ;;
    freeunit-master) echo "drupal-bench-freeunit:master" ;;
    freeunit-direct) echo "drupal-bench-freeunit:${FREEUNIT_TAG:-1.37.0}" ;;
    nginx-fpm) echo "drupal-bench-fpm:${TAG}" ;;
    apache)    echo "drupal-bench-apache:${TAG}" ;;
    *) die "unknown runtime $1" ;;
    esac
}

# ---------------------------------------------------------------- cgroup sampling
# Every pid in a container's cgroup, the container init included.
cg_pids() {  # container name
    local pid cg
    pid=$(docker inspect -f '{{.State.Pid}}' "$1" 2>/dev/null) || return 0
    [ -n "$pid" ] && [ "$pid" != 0 ] || return 0
    cg=$(sed -n 's/^0:://p' "/proc/$pid/cgroup" 2>/dev/null)
    if [ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/cgroup.procs" ]; then
        cat "/sys/fs/cgroup$cg/cgroup.procs"
    else
        ps -eo pid=,ppid= | awk -v m="$pid" '
            { p[$1] = $2 } END {
                for (x in p) { y = x; while (y != "" && y != 0 && y != m) y = p[y]; if (y == m) print x }
            }'
    fi
}
oncpu_ns() {  # pids... -> summed on-CPU nanoseconds over all their threads
    local p t s=0 v
    for p in "$@"; do
        for t in /proc/$p/task/*/schedstat; do
            read -r v _ < "$t" 2>/dev/null && s=$((s + v))
        done
    done
    echo "$s"
}

pids_role() {  # runtime role -> pids of the front proxy or the PHP workers
    local rt=$1 role=$2 p c
    for p in $(cg_pids "$rt"); do
        c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
        case "$rt:$role" in
        freeunit*:front)  case "$c" in *"unit: router"*) echo "$p" ;; esac ;;
        freeunit*:worker) case "$c" in *application*) echo "$p" ;; esac ;;
        nginx-fpm:front)  case "$c" in *"nginx:"*) echo "$p" ;; esac ;;
        nginx-fpm:worker) case "$c" in *"php-fpm:"*) echo "$p" ;; esac ;;
        apache:*)         echo "$p" ;;
        esac
    done
}

perf_start() {  # name pids
    [ "$PERF" = 1 ] || return 0
    [ -n "$2" ] || return 0
    docker rm -f "perf-$$-$1" >/dev/null 2>&1 || true
    docker run -d --name "perf-$$-$1" --rm --label "bench-run=${RUN_ID:-manual}" --label bench-role=perf \
        --cap-add PERFMON --pid=host \
        -v "$R:/out" "$PERF_IMAGE" \
        perf stat -x, -e "$PERF_EVENTS" -o "/out/perf.$1" -p "$2" >/dev/null || return 0
    sleep 0.4
}
perf_stop() {  # name
    [ "$PERF" = 1 ] || return 0
    docker kill -s INT "perf-$$-$1" >/dev/null 2>&1 || true
    local i
    for i in $(seq 30); do docker ps -q -f "name=perf-$$-$1" | grep -q . || break; sleep 0.1; done
    docker rm -f "perf-$$-$1" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- database
start_db() {
    docker network create "$NET" >/dev/null 2>&1 || true
    docker rm -f "$CNAME" >/dev/null 2>&1 || true
    DBCVOL=${DBCVOL:-drupal-bench-db-${SITE:-default}}
    docker run -d --name "$CNAME" --network "$NET" --cpuset-cpus "${DB_CPUS:-$SERVER_CPUS}" \
        --label "bench-run=${RUN_ID:-manual}" --label bench-role=db \
        -v "$DBCVOL:/var/lib/mysql" \
        --network-alias db -e MARIADB_ROOT_HOST=% -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=drupal \
        mariadb:${MARIADB_TAG:-10.11} >/dev/null || die "cannot start mariadb"
    local i
    for i in $(seq 60); do
        docker exec "$CNAME" mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1 && return 0
        sleep 1
    done
    die "mariadb did not become ready"
}
stop_db() { docker rm -f "$CNAME" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }

# ---------------------------------------------------------------- runtime
start_rt() {  # runtime -> name
    local rt=$1 img name args=""
    img=$(image_for "$rt")
    name="rt-$$-$rt"
    docker rm -f "$name" >/dev/null 2>&1 || true
    # a leftover container from a killed job would hold the port and silently
    # turn a whole block into zeros; free it first
    for c in $(docker ps -q -f "publish=$PORT"); do
        log "freeing port $PORT held by $(docker inspect -f '{{.Name}}' "$c" 2>/dev/null)"
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
    case "$rt" in
    freeunit|freeunit-direct|freeunit-master)
        local cfg="$RESROOT/runtimes/$rt.json"
        [ -f "$cfg" ] || cfg="$RESROOT/runtimes/freeunit.json"
        docker run -d --name "$name" --network "$NET" --cpuset-cpus "$SERVER_CPUS" \
            --label "bench-run=${RUN_ID:-manual}" --label bench-role=runtime \
            -p "127.0.0.1:$PORT:80" \
            -v "$SITE_DIR:/app" \
            -v "$cfg:/docker-entrypoint.d/config.json:ro" \
            -v "$RESROOT/apps:/app/apps:ro" \
            "$img" >/dev/null || die "cannot start $rt"
        ;;
    nginx-fpm|apache)
        docker run -d --name "$name" --network "$NET" --cpuset-cpus "$SERVER_CPUS" \
            --label "bench-run=${RUN_ID:-manual}" --label bench-role=runtime \
            -p "127.0.0.1:$PORT:80" \
            -v "$SITE_DIR:/app" \
            -v "$RESROOT/apps:/app/apps:ro" \
            "$img" >/dev/null || die "cannot start $rt"
        ;;
    esac
    echo "$name"
}
stop_rt() { [ -n "${1:-}" ] && docker rm -f "$1" >/dev/null 2>&1; }

wait_http() {  # url tries
    local url=$1 n=${2:-60} i
    for i in $(seq "$n"); do
        [ "$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" = 200 ] && return 0
        sleep 0.5
    done
    return 1
}

# ---------------------------------------------------------------- workload
url_for() { echo "http://127.0.0.1:$PORT/"; }
oha_args() {  # conns -> OHA_A
    OHA_A=(-c "$1" --no-tui)
    [ -n "${RATE:-}" ] && [ "$RATE" != 0 ] && OHA_A+=(-q "$RATE")
    if [ "$WORKLOAD" = drupal-auth ] && [ -n "$COOKIE_HDR" ]; then
        OHA_A+=(-H "Cookie: $COOKIE_HDR")
    fi
    [ -n "${AE:-}" ] && OHA_A+=(-H "Accept-Encoding: $AE")
    return 0
}

# Front-anon must be a page-cache hit on every runtime: a MISS makes the cell INVALID
# (plan section 3.1). front-auth must bypass the page cache; its dynamic-cache header
# is recorded on the first and last request (section 3.2).
preflight() {  # runtime name -> 0 ok
    local name=$1 hdr code bytes
    # Use GET headers, not HEAD: the guard must see what the measured requests
    # see. One retry, because the first request on a cold page cache legitimately
    # misses and the cache is then warm for the measured window.
    local try
    code=000
    # The cookie belongs to the authenticated workload only: sending it on the
    # anonymous page turns the request into an authenticated render and the
    # page-cache guard can never pass.
    local with_cookie=""
    [ "$WORKLOAD" = drupal-auth ] && [ -n "$COOKIE_HDR" ] && with_cookie="yes"
    for try in 1 2; do
        if [ -n "$with_cookie" ]; then
            hdr=$(curl -s -D - -o /dev/null -H "Cookie: $COOKIE_HDR" -w '\nHTTP %{http_code}' "$(url_for)" | tr -d '\r')
        else
            hdr=$(curl -s -D - -o /dev/null -w '\nHTTP %{http_code}' "$(url_for)" | tr -d '\r')
        fi
        code=$(printf '%s' "$hdr" | awk '/^HTTP /{c=$2} END{print c}')
        [ "$code" = 200 ] || continue
        case "$WORKLOAD" in
        drupal-front)
            printf '%s' "$hdr" | grep -qi '^x-drupal-cache: HIT' && break ;;
        drupal-auth)
            printf '%s' "$hdr" | grep -qi '^x-drupal-dynamic-cache: ' && break ;;
        *) break ;;
        esac
    done
    [ "$code" = 200 ] || { log "preflight $name: HTTP $code"; return 1; }
    bytes=$(printf '%s' "$hdr" | awk 'tolower($1) == "content-length:" {print $2}')
    case "$WORKLOAD" in
    drupal-front)
        printf '%s' "$hdr" | grep -qi '^x-drupal-cache: HIT' || { log "preflight $name: no page-cache HIT"; return 1; } ;;
    drupal-auth)
        printf '%s' "$hdr" | grep -qi '^x-drupal-dynamic-cache: ' || log "preflight $name: no dynamic-cache header (recorded)" ;;
    esac
    {
        echo "runtime=$name url=$(url_for) workload=$WORKLOAD http=$code bytes=${bytes:-?}"
        printf '%s\n' "$hdr" | grep -i '^x-drupal' || true
    } >> "$OUTDIR/preflight.txt"
    return 0
}

emit() {  # phase side cell block slot metric value
    local rev=$RUNTIME_A
    [ "$1" = ab ] && [ "$2" = B ] && rev=$RUNTIME_B
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$JOB" "$1" "$2" "$rev" "$3" "$4" "$5" "$6" "$7" >> "$OUT"
}

perf_parse() {  # file prefix ok
    awk -F, -v p="$2" -v n="$3" '
        $3 ~ /^(cycles|instructions|context-switches|cpu-migrations)/ && $1 ~ /^[0-9.]+$/ {
            e = $3; sub(/:.*/, "", e); sub(/^context-switches$/, "cs", e); sub(/^cpu-migrations$/, "migrations", e)
            printf "%s_%s %.4f\n", p, e, (n > 0 ? $1 / n : 0)
        }' "$1"
}

timed_cell() {  # phase side cell conns block slot runtime
    local ph=$1 side=$2 cell=$3 c=$4 k=$5 s=$6 rt=$7
    local name; name=$(start_rt "$rt") || die "start failed: $rt"
    local pre=0
    wait_http "$(url_for)" 60 || { log "$rt did not answer on $PORT"; }
    preflight "$name" || pre=1
    oha_args "$c"
    taskset -c "$LOAD_CPUS" "$OHA" -z "${WARM}s" "${OHA_A[@]}" "$(url_for)" >/dev/null 2>&1
    local pids rpids; pids=$(cg_pids "$name" | tr '\n' ' '); rpids=$(cg_pids "$CNAME" | tr '\n' ' ')
    rm -f "$R/perf.s" "$R/perf.db" "$R/perf.sf" "$R/perf.sw"
    perf_start s "$(echo $pids | tr ' ' ',')"
    perf_start db "$(echo $rpids | tr ' ' ',')"
    local fpids wpids
    if [ "${DECOMPOSE:-0}" = 1 ]; then
        fpids=$(pids_role "$rt" front | tr '\n' ' ')
        wpids=$(pids_role "$rt" worker | tr '\n' ' ')
        perf_start sf "$(echo $fpids | tr ' ' ',')"
        perf_start sw "$(echo $wpids | tr ' ' ',')"
    fi
    sleep 0.2
    local a0 a1 d0 d1 f0 f1 w0 w1
    a0=$(oncpu_ns $pids); d0=$(oncpu_ns $rpids); f0=0; w0=0
    [ "${DECOMPOSE:-0}" = 1 ] && { f0=$(oncpu_ns $fpids); w0=$(oncpu_ns $wpids); }
    taskset -c "$LOAD_CPUS" "$OHA" -z "${DUR}s" -w "${OHA_A[@]}" --output-format json "$(url_for)" > "$R/oha.json" 2>/dev/null
    a1=$(oncpu_ns $pids); d1=$(oncpu_ns $rpids); f1=0; w1=0
    [ "${DECOMPOSE:-0}" = 1 ] && { f1=$(oncpu_ns $fpids); w1=$(oncpu_ns $wpids); }
    perf_stop s
    perf_stop db
    perf_stop sf
    perf_stop sw
    python3 - "$R/oha.json" > "$R/oha.txt" <<'PY' || die "cannot read oha json"
import json, sys
d = json.load(open(sys.argv[1]))
codes = d.get("statusCodeDistribution", {})
ok = int(codes.get("200", 0))
bad = sum(int(v) for k, v in codes.items() if k != "200") + sum(int(v) for v in d.get("errorDistribution", {}).values())
lp = d.get("latencyPercentiles", {})
print("ok", ok); print("bad", bad)
print("rps", round(d["summary"]["requestsPerSec"], 2))
print("p50_ms", round((lp.get("p50") or 0) * 1000, 4)); print("p99_ms", round((lp.get("p99") or 0) * 1000, 4))
PY
    local ok
    ok=$(awk '$1 == "ok" {print $2}' "$R/oha.txt")
    while read -r m v; do emit "$ph" "$side" "$cell" "$k" "$s" "$m" "$v"; done < "$R/oha.txt"
    local su du
    su=$(awk -v d=$((a1 - a0)) -v n="$ok" 'BEGIN{printf "%.3f", (n > 0 ? d / 1000 / n : 0)}')
    du=$(awk -v d=$((d1 - d0)) -v n="$ok" 'BEGIN{printf "%.3f", (n > 0 ? d / 1000 / n : 0)}')
    emit "$ph" "$side" "$cell" "$k" "$s" server_us "$su"
    emit "$ph" "$side" "$cell" "$k" "$s" db_us "$du"
    if [ "${DECOMPOSE:-0}" = 1 ]; then
        local fu wu
        fu=$(awk -v d=$((f1 - f0)) -v n="$ok" 'BEGIN{printf "%.3f", (n > 0 ? d / 1000 / n : 0)}')
        wu=$(awk -v d=$((w1 - w0)) -v n="$ok" 'BEGIN{printf "%.3f", (n > 0 ? d / 1000 / n : 0)}')
        emit "$ph" "$side" "$cell" "$k" "$s" front_us "$fu"
        emit "$ph" "$side" "$cell" "$k" "$s" worker_us "$wu"
        [ -s "$R/perf.sf" ] && perf_parse "$R/perf.sf" front "$ok" | while read -r m v; do emit "$ph" "$side" "$cell" "$k" "$s" "$m" "$v"; done
        [ -s "$R/perf.sw" ] && perf_parse "$R/perf.sw" worker "$ok" | while read -r m v; do emit "$ph" "$side" "$cell" "$k" "$s" "$m" "$v"; done
    fi
    if [ "$PERF" = 1 ]; then
        perf_parse "$R/perf.s" s "$ok" | while read -r m v; do emit "$ph" "$side" "$cell" "$k" "$s" "$m" "$v"; done
        [ -s "$R/perf.db" ] && perf_parse "$R/perf.db" db "$ok" | while read -r m v; do emit "$ph" "$side" "$cell" "$k" "$s" "$m" "$v"; done
    fi
    local alerts=0
    [ "$pre" = 1 ] && alerts=$((alerts + 1))
    case "$rt" in
    freeunit|freeunit-master|freeunit-direct) docker logs "$name" 2>&1 | grep -qE '\[(alert|crit|emerg)\]' && alerts=$((alerts + 1)) ;;
    *) docker logs "$name" 2>&1 | grep -qE '\[(crit|emerg|alert)\]|worker process is shutting down unexpectedly' && alerts=$((alerts + 1)) ;;
    esac
    emit "$ph" "$side" "$cell" "$k" "$s" alerts "$alerts"
    echo "  $ph $side $cell block $k slot $s ($rt): ok=$ok bad=$(awk '$1=="bad"{print $2}' "$R/oha.txt") server_us=$su db_us=$du alerts=$alerts"
    stop_rt "$name"
}

main() {
    start_db
    for k in $(seq 0 $((REPS - 1))); do
        if [ $((k % 2)) = 0 ]; then ord=("${ORDER[@]}"); else ord=("${SWAP[@]}"); fi
        for c in $CONNS; do
            cell="$WORKLOAD-c$c"
            for ph in $PHASES; do
                s=0
                for x in "${ord[@]}"; do
                    if [ "$x" = X ]; then timed_cell "$ph" A "$cell" "$c" "$k" "$s" "$RUNTIME_A"
                    elif [ "$ph" = null ]; then timed_cell "$ph" B "$cell" "$c" "$k" "$s" "$RUNTIME_A"
                    else timed_cell "$ph" B "$cell" "$c" "$k" "$s" "$RUNTIME_B"; fi
                    s=$((s + 1))
                done
            done
        done
    done
    stop_db
    echo CELLS-DONE
}
main
