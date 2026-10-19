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
# Numeric output must not follow the caller locale (awk/printf would use ",").
export LC_ALL=C
set -u
RESROOT="${RESROOT:-${RUNROOT:-/data/projects/benchmarks-drupal/run}}"
OUT="${OUT:-$RESROOT}/results.tsv"
OUTDIR=$(dirname "$OUT")
# Scratch goes beside the run, not into /tmp: on the perf boxes /tmp is on the
# 40 GB root, and a PERF_RECORD job writes its recordings here. A 27 GB leftover
# perf file filled / on pro4s-4 on 2026-10-17, which broke docker builds and made
# the idle gate refuse every run; the scratch dirs were never removed either.
TMPBASE=${BENCH_TMPDIR:-$RESROOT/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE=/tmp
R=$(mktemp -d "$TMPBASE/drupal-bench.XXXXXX")
# Keep the scratch of a failed run for diagnosis (rec.err, perf.rec.*), drop it
# when the cells completed.
scratch_cleanup() {
    rc=$?
    [ "$rc" = 0 ] && rm -rf "$R"
    return "$rc"
}
trap scratch_cleanup EXIT
OHA=${OHA:-oha}
PERF_IMAGE=${PERF_IMAGE:-freeunit-perf-lab:1}
PERF_EVENTS=${PERF_EVENTS:-cycles,instructions,context-switches,cpu-migrations}
# PERF_RECORD=1 (job-set, exported by run.sh) additionally perf-records the s and,
# with DECOMPOSE=1, sf/sw pid groups on ab cells; each side's last ab cell is
# kept in $OUTDIR as perf.rec.<side>-<group>.data. Default off.
PERF_RECORD=${PERF_RECORD:-0}
TAG=${IMAGE_TAG:-8.5}
PORT=${BASE_PORT:-8081}
# A synthetic cookie of a chosen size tests whether the per-request overhead tracks
# request bytes rather than PHP execution (job 29/30, the auth-page follow-up).
if [ "${EXTRA_COOKIE_BYTES:-0}" -gt 0 ]; then
    pad=$(head -c "$EXTRA_COOKIE_BYTES" /dev/zero | tr '\0' 'x')
    # COOKIE_HDR itself is only built below, from the per-side jars; start from the
    # side's own header when there is one so a padded auth job keeps its session.
    COOKIE_HDR="${COOKIE_HDR_A:-}bench=${pad}; "
fi
# Per-side site and database. A job that compares two backends sets SITE_DIR_A/
# SITE_DIR_B (or DB_A/DB_B); each side then has its own network, its own database
# container under the alias `db`, and its own site directory, so the two differ
# only in the backend. Without that, both sides are the one network and container.
SITE_DIR_A=${SITE_DIR_A:-${SITE_DIR:-}}
SITE_DIR_B=${SITE_DIR_B:-$SITE_DIR_A}
DB_A=${DB_A:-${DB:-mysql}}
DB_B=${DB_B:-$DB_A}
SPLIT=0
{ [ "$SITE_DIR_A" != "$SITE_DIR_B" ] || [ "$DB_A" != "$DB_B" ]; } && SPLIT=1
NET_A="dbnet-$$-a"; CNAME_A="db-bench-$$-a"
NET_B="$NET_A"; CNAME_B="$CNAME_A"
if [ "$SPLIT" = 1 ]; then NET_B="dbnet-$$-b"; CNAME_B="db-bench-$$-b"; fi
NET="$NET_A"; CNAME="$CNAME_A"
ORDER=(X Y Y X Y X X Y)
SWAP=(Y X X Y X Y Y X)

# sv SIDE SUFFIX -> the value of <SUFFIX>_<SIDE>, e.g. sv A CNAME
# sv SIDE SUFFIX -> the value of <SUFFIX>_<SIDE>, e.g. sv A CNAME.
# ${...:-} on purpose: a job without a cookie jar never sets COOKIE_HDR_A/B, and a
# bare expansion under set -u made every call in such a job fail with
# "COOKIE_HDR_A: unbound variable".
sv() { local n="$2_$1"; eval "printf '%s' \"\${$n:-}\""; }

# Cookie bytes per side: an authenticated job needs the session cookie of that
# side's site, and the two sides may be different installations.
for _side in A B; do
    _jar=${COOKIE_FILE_A:-${COOKIE_FILE:-}}
    [ "$_side" = B ] && _jar=${COOKIE_FILE_B:-${COOKIE_FILE:-}}
    [ -n "$_jar" ] && [ -f "$_jar" ] || continue
    eval "COOKIE_FILE_$_side=$_jar"
    eval "COOKIE_HDR_$_side=\"$(awk '($1 ~ /^#HttpOnly_/ || $1 !~ /^#/) && NF >= 7 { printf "%s=%s; ", $6, $7 }' "$_jar")\""
done
# Keep the padded value from the EXTRA_COOKIE_BYTES block above when present.
COOKIE_HDR="${COOKIE_HDR:-${COOKIE_HDR_A:-}}"

die() {
    echo "cells.sh: $*" >&2
    docker rm -f "$CNAME_A" "$CNAME_B" >/dev/null 2>&1
    docker network rm "$NET_A" "$NET_B" >/dev/null 2>&1
    exit 1
}
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
    freeunit-master-old) echo "drupal-bench-freeunit:master-old" ;;
    freeunit-master-mid) echo "drupal-bench-freeunit:master-mid" ;;
    # Flag-variant images of the same master commit (Dockerfile CC_OPT build-arg),
    # for the hot-path audit's within-commit optimization A/Bs.
    freeunit-master-o2) echo "drupal-bench-freeunit:master-o2" ;;
    freeunit-master-lto) echo "drupal-bench-freeunit:master-lto" ;;
    # The same 1.37.0 tree built against musl, for the C-library comparison.
    freeunit-musl) echo "drupal-bench-freeunit:musl" ;;
    # PR #742: the same tree with the mixed atomic/plain accesses finished, and its
    # base (master at ff694772), so the atomic cost can be measured on its own.
    freeunit-742-base) echo "drupal-bench-freeunit:742-base" ;;
    freeunit-742-head) echo "drupal-bench-freeunit:742-head" ;;
    # A master commit named in the tag, so a newer master can be measured without
    # moving :master: the hot-path audit compares :master with :master-o2 and
    # :master-lto images built from one commit (42, 43, 16r).
    freeunit-master-33896f7) echo "drupal-bench-freeunit:master-33896f7" ;;
    freeunit-master-10e1a9bec) echo "drupal-bench-freeunit:master-10e1a9bec" ;;
    freeunit-master-b532b9d) echo "drupal-bench-freeunit:master-b532b9d" ;;
    freeunit-master-13effad) echo "drupal-bench-freeunit:master-13effad" ;;
    # PR 705 isolation: the commit and its parent.
    freeunit-705-base) echo "drupal-bench-freeunit:705-base" ;;
    freeunit-705) echo "drupal-bench-freeunit:705" ;;
    freeunit-tip-e63168bd) echo "drupal-bench-freeunit:tip-e63168bd" ;;
    # PR #768: its base (master 10e1a9bec) and its head, so the delta is the PR.
    freeunit-768-base) echo "drupal-bench-freeunit:768-base" ;;
    freeunit-768-head) echo "drupal-bench-freeunit:768-head" ;;
    freeunit-direct) echo "drupal-bench-freeunit:${FREEUNIT_TAG:-1.37.0}" ;;
    nginx-fpm) echo "drupal-bench-fpm:${TAG}" ;;
    nginx-src) echo "drupal-bench-nginx-src:${TAG}" ;;
    angie-fpm) echo "drupal-bench-angie:${TAG}" ;;
    freenginx-fpm) echo "drupal-bench-freenginx:${TAG}" ;;
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

pids_role() {  # runtime, role, container name -> pids of the front proxy or the workers
    # The container name is a separate argument: cg_pids() inspects a *container*, and
    # passing the runtime name here meant DECOMPOSE never found a pid and reported
    # front_us/worker_us as 0.000 (NO DATA) on every cell.
    local rt=$1 role=$2 name=$3 p c
    for p in $(cg_pids "$name"); do
        c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
        case "$rt:$role" in
        freeunit*:front)  case "$c" in *"unit: router"*) echo "$p" ;; esac ;;
        freeunit*:worker) case "$c" in *application*) echo "$p" ;; esac ;;
        nginx-fpm:front)  case "$c" in *"nginx:"*) echo "$p" ;; esac ;;
        nginx-fpm:worker) case "$c" in *"php-fpm:"*) echo "$p" ;; esac ;;
        # nginx-src and FreeNginx both title the process "nginx:"; Angie uses its
        # own name, so the two cannot share a pattern.
        nginx-src:front|freenginx-fpm:front)  case "$c" in *"nginx:"*) echo "$p" ;; esac ;;
        nginx-src:worker|freenginx-fpm:worker) case "$c" in *"php-fpm:"*) echo "$p" ;; esac ;;
        angie-fpm:front)  case "$c" in *"angie:"*) echo "$p" ;; esac ;;
        angie-fpm:worker) case "$c" in *"php-fpm:"*) echo "$p" ;; esac ;;
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

# Optional sampling attribution (hot-path audit): PERF_RECORD=1 records the same
# pid groups perf stat watches, on ab cells only, into $R/perf.rec.<name> (perf
# writes the -o path verbatim). Default off; a plain job file never sets it, so
# nothing changes unless asked.
rec_start() {  # name (pids ignored: records the whole SERVER_CPUS set)
    [ "${PERF_RECORD:-0}" = 1 ] || return 0
    docker rm -f "recrec-$$-$1" >/dev/null 2>&1 || true
    # pid-targeted record fails from a sibling container ("Couldn't create
    # thread/CPU maps: No such process" - the target lives in another pid
    # namespace); the runtimes are pinned to SERVER_CPUS, so record the set.
    # No --rm: a recorder that dies at start took its only diagnostic (docker logs)
    # with it, and rec_stop removes the container after reading the exit code.
    docker run -d --name "recrec-$$-$1" --label "bench-run=${RUN_ID:-manual}" --label bench-role=perf \
        --cap-add PERFMON --pid=host \
        -v "$R:/out" "$PERF_IMAGE" \
        perf record -F 999 --call-graph dwarf,4096 -a -C "$SERVER_CPUS" \
        -o "/out/perf.rec.$1" >>"$OUTDIR/rec.err" 2>&1 || { log "perf record failed for $1 (see rec.err)"; return 0; }
}
rec_stop() {  # name
    [ "${PERF_RECORD:-0}" = 1 ] || return 0
    docker kill -s INT "recrec-$$-$1" >/dev/null 2>&1 || true
    # perf flushes its data file on SIGINT; on a loaded box that flush takes
    # seconds, and each docker ps here is itself slow. Wait up to 60 s before
    # the forced removal, and record the exit code for diagnosis: a killed
    # recorder (no perf.rec file) shows up here as exit=137.
    local i rc
    for i in $(seq 120); do docker ps -q -f "name=recrec-$$-$1" | grep -q . || break; sleep 0.5; done
    rc=$(docker inspect -f '{{.State.ExitCode}}' "recrec-$$-$1" 2>/dev/null || echo gone)
    {
        echo "rec_stop $1 exit=$rc"
        docker logs "recrec-$$-$1" 2>&1 | tail -8
    } >>"$OUTDIR/rec.err" 2>/dev/null || true
    docker rm -f "recrec-$$-$1" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- database
start_db() {  # side
    local side=${1:-A} i
    local db net cname
    db=$(sv "$side" DB); net=$(sv "$side" NET); cname=$(sv "$side" CNAME)
    # The network of the side being started, not of side A: a job that compares two
    # backends takes the two-side path, and with only "$NET" (the A global) created
    # here, side B died with "network dbnet-<pid>-b not found" before its database
    # could come up.  Idempotent, so a repeat call is harmless.
    docker network create "$net" >/dev/null 2>&1 || true
    docker rm -f "$cname" >/dev/null 2>&1 || true
    DBCVOL=$(sv "$side" DBCVOL)
    [ -n "$DBCVOL" ] || DBCVOL="drupal-bench-db-$(basename "$(sv "$side" SITE_DIR)")"
    if [ -n "${DBC_IMAGE:-}" ] && [ "${db}" != sqlite ]; then
        # one image that can be any server; the entrypoint reads DB
        docker run -d --name "$cname" --network "$net" --cpuset-cpus "${DB_CPUS:-$SERVER_CPUS}" \
            --label "bench-run=${RUN_ID:-manual}" --label bench-role=db \
            -v "$DBCVOL:/var/lib/bench-db" --network-alias db -e DB="$db" \
            "$DBC_IMAGE" >/dev/null || die "cannot start $DBC_IMAGE"
        for i in $(seq 90); do
            case "$db" in
            pgsql) docker exec "$cname" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && return 0 ;;
            *)     docker exec "$cname" mariadb-admin --protocol=tcp -h127.0.0.1 -uroot ping >/dev/null 2>&1 && return 0 ;;
            esac
            sleep 1
        done
        die "$DBC_IMAGE did not become ready for DB=$db"
    fi
    case "$db" in
    sqlite)
        # no server: the site's settings.php points at a file
        eval "NO_DB_$side=1"
        return 0
        ;;
    pgsql)
        docker run -d --name "$cname" --network "$net" --cpuset-cpus "${DB_CPUS:-$SERVER_CPUS}" \
            --label "bench-run=${RUN_ID:-manual}" --label bench-role=db \
            -v "$DBCVOL:/var/lib/postgresql" \
            --network-alias db -e POSTGRES_DB=drupal -e POSTGRES_HOST_AUTH_METHOD=trust \
            "${PG_IMAGE:-postgres:18}" >/dev/null || die "cannot start postgres"
        for i in $(seq 60); do
            docker exec "$cname" pg_isready -U postgres -d drupal >/dev/null 2>&1 && return 0
            sleep 1
        done
        die "postgres did not become ready"
        ;;
    *)
        docker run -d --name "$cname" --network "$net" --cpuset-cpus "${DB_CPUS:-$SERVER_CPUS}" \
            --label "bench-run=${RUN_ID:-manual}" --label bench-role=db \
            -v "$DBCVOL:/var/lib/mysql" \
            --network-alias db -e MARIADB_ROOT_HOST=% -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=drupal \
            mariadb:${MARIADB_TAG:-10.11} >/dev/null || die "cannot start mariadb"
        # Wait for the image's temporary initialization server to finish: touching
        # the users during it makes the entrypoint's CREATE USER fail and the
        # container exit (see site-build.sh).
        for i in $(seq 120); do
            if docker exec "$cname" mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1; then
                # one read: `docker logs | grep -q` under pipefail gives 141 on SIGPIPE
                logs=$(docker logs "$cname" 2>&1 || true)
                grep -q 'Temporary server started' <<<"$logs" || return 0
                grep -qE 'Temporary server stopped|init process done' <<<"$logs" && return 0
            fi
            sleep 1
        done
        die "mariadb did not finish initializing"
        die "mariadb did not become ready"
        ;;
    esac
}
stop_db() {  # side
    local side=${1:-A}
    [ "$(sv "$side" NO_DB)" = 1 ] || docker rm -f "$(sv "$side" CNAME)" >/dev/null 2>&1
    docker network rm "$(sv "$side" NET)" >/dev/null 2>&1
}

# ---------------------------------------------------------------- runtime
start_rt() {  # runtime side -> name
    local rt=$1 side=${2:-A} img name args="" net sitedir
    net=$(sv "$side" NET); sitedir=$(sv "$side" SITE_DIR)
    img=$(image_for "$rt")
    name="rt-$$-$rt"
    docker rm -f "$name" >/dev/null 2>&1 || true
    # a leftover container from a killed job would hold the port and silently
    # turn a whole block into zeros; free it first
    for c in $(docker ps -q -f "publish=$PORT"); do
        log "freeing port $PORT held by $(docker inspect -f '{{.Name}}' "$c" 2>/dev/null)"
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
    # A site built with PRELOAD=1 carries an ini fragment; mount it only when it is
    # there, so a site without one runs exactly as before. opcache.preload is
    # PHP_INI_SYSTEM, so it has to arrive with the process, not through the Unit
    # application options.
    local preload_vol=()
    [ -f "$sitedir/preload.ini" ] && preload_vol=(-v "$sitedir/preload.ini:/usr/local/etc/php/conf.d/zz-preload.ini:ro")
    case "$rt" in
    freeunit|freeunit-direct|freeunit-master|freeunit-master-old|freeunit-master-mid|freeunit-musl|freeunit-master-o2|freeunit-master-lto|freeunit-742-base|freeunit-742-head|freeunit-master-33896f7|freeunit-768-base|freeunit-768-head|freeunit-master-10e1a9bec|freeunit-master-b532b9d|freeunit-master-13effad|freeunit-705-base|freeunit-705|freeunit-tip-e63168bd)
        local cfg="$RESROOT/runtimes/$rt.json"
        [ -f "$cfg" ] || cfg="$RESROOT/runtimes/freeunit.json"
        docker run -d --name "$name" --network "$net" --cpuset-cpus "$SERVER_CPUS" \
            --label "bench-run=${RUN_ID:-manual}" --label bench-role=runtime \
            -p "127.0.0.1:$PORT:80" \
            -v "$sitedir:/app" \
            -v "$cfg:/docker-entrypoint.d/config.json:ro" \
            -v "$RESROOT/apps:/app/apps:ro" \
            ${preload_vol[@]+"${preload_vol[@]}"} \
            "$img" >/dev/null || die "cannot start $rt"
        ;;
    nginx-fpm|apache|nginx-src|angie-fpm|freenginx-fpm)
        docker run -d --name "$name" --network "$net" --cpuset-cpus "$SERVER_CPUS" \
            --label "bench-run=${RUN_ID:-manual}" --label bench-role=runtime \
            -p "127.0.0.1:$PORT:80" \
            -v "$sitedir:/app" \
            -v "$RESROOT/apps:/app/apps:ro" \
            ${preload_vol[@]+"${preload_vol[@]}"} \
            "$img" >/dev/null || die "cannot start $rt"
        ;;
    esac
    echo "$name"
}
stop_rt() { [ -n "${1:-}" ] && docker rm -f "$1" >/dev/null 2>&1; }

wait_http() {  # url tries
    local url=$1 n=${2:-60} i
    for i in $(seq "$n"); do
        # A timeout is not optional here: a runtime that accepts the connection and
        # never answers leaves curl polling for ever, and cells.sh waits on the
        # command substitution, so the whole job hangs instead of failing. Seen for
        # 2h25m on a php-body cell and for hours on the WordPress job.
        [ "$(curl -s --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" = 200 ] && return 0
        sleep 0.5
    done
    return 1
}

# ---------------------------------------------------------------- workload
# Workloads that need a session.  The anonymous front page must never carry a
# cookie, or the request stops being the anonymous render the cell is about.
needs_cookie() {
    case "$WORKLOAD" in
    drupal-auth|wp-edit|wp-edit-list|wp-admin|wp-front-auth) return 0 ;;
    *) return 1 ;;
    esac
}

url_for() {
    case "$WORKLOAD" in
    php-headers) echo "http://127.0.0.1:$PORT/?mode=headers" ;;
    php-body)    echo "http://127.0.0.1:$PORT/?mode=body" ;;
    php-body-1k)  echo "http://127.0.0.1:$PORT/?mode=body&size=1024" ;;
    php-work-1k)   echo "http://127.0.0.1:$PORT/?mode=work&n=1000" ;;
    php-work-20k)  echo "http://127.0.0.1:$PORT/?mode=work&n=20000" ;;
    php-work-200k) echo "http://127.0.0.1:$PORT/?mode=work&n=200000" ;;
    php-body-8k)  echo "http://127.0.0.1:$PORT/?mode=body&size=8192" ;;
    php-body-64k) echo "http://127.0.0.1:$PORT/?mode=body&size=65536" ;;
    wp-front)    echo "http://127.0.0.1:$PORT/" ;;
    wp-front-auth) echo "http://127.0.0.1:$PORT/" ;;
    wp-cron)     echo "http://127.0.0.1:$PORT/wp-cron.php?doing_wp_cron=1" ;;
    # Through the REST controller and the main query, no theme: the most PHP-bound
    # WordPress request that needs no session, so it is the cleanest of the three.
    wp-rest-posts) echo "http://127.0.0.1:$PORT/wp-json/wp/v2/posts?per_page=10" ;;
    # The block editor: full admin bootstrap, capability checks, meta queries.
    wp-edit)     echo "http://127.0.0.1:$PORT/wp-admin/post.php?post=${WP_POST_ID:-1}&action=edit" ;;
    # The admin list table: a classic admin query with pagination.
    wp-edit-list) echo "http://127.0.0.1:$PORT/wp-admin/edit.php" ;;
    wp-admin)    echo "http://127.0.0.1:$PORT/wp-admin/" ;;
    *)           echo "http://127.0.0.1:$PORT/" ;;
    esac
}
oha_args() {  # conns side -> OHA_A
    OHA_A=(-c "$1" --no-tui)
    [ -n "${RATE:-}" ] && [ "$RATE" != 0 ] && OHA_A+=(-q "$RATE")
    if [ -n "$COOKIE_HDR" ] && { needs_cookie || [ "${EXTRA_COOKIE_BYTES:-0}" -gt 0 ]; }; then
        OHA_A+=(-H "Cookie: $COOKIE_HDR")
    fi
    [ -n "${AE:-}" ] && OHA_A+=(-H "Accept-Encoding: $AE")
    return 0
}

# Front-anon must be a page-cache hit on every runtime: a MISS makes the cell INVALID
# (plan section 3.1). front-auth must bypass the page cache; its dynamic-cache header
# is recorded on the first and last request (section 3.2).
preflight() {  # runtime name side -> 0 ok
    local name=$1 side=${2:-A} hdr code bytes
    # Use GET headers, not HEAD: the guard must see what the measured requests
    # see. One retry, because the first request on a cold page cache legitimately
    # misses and the cache is then warm for the measured window.
    local try
    code=000
    # The cookie belongs to the authenticated workload only: sending it on the
    # anonymous page turns the request into an authenticated render and the
    # page-cache guard can never pass.
    local with_cookie="" sidehdr
    sidehdr=$(sv "$side" COOKIE_HDR)
    { needs_cookie || [ "${EXTRA_COOKIE_BYTES:-0}" -gt 0 ]; } && [ -n "$sidehdr" ] && with_cookie="yes"
    for try in 1 2; do
        if [ -n "$with_cookie" ]; then
            hdr=$(curl -s --connect-timeout 2 --max-time 10 -D - -o /dev/null -H "Cookie: $sidehdr" -w '\nHTTP %{http_code}' "$(url_for)" | tr -d '\r')
        else
            hdr=$(curl -s --connect-timeout 2 --max-time 10 -D - -o /dev/null -w '\nHTTP %{http_code}' "$(url_for)" | tr -d '\r')
        fi
        code=$(printf '%s' "$hdr" | awk '/^HTTP /{c=$2} END{print c}')
        [ "$code" = 200 ] || continue
        case "$WORKLOAD" in
        drupal-front)
            printf '%s' "$hdr" | grep -qi '^x-drupal-cache: HIT' && break ;;
        drupal-auth)
            printf '%s' "$hdr" | grep -qi '^x-drupal-dynamic-cache: ' && break ;;
        wp-rest-posts)
            printf '%s' "$hdr" | grep -qi '^content-type: application/json' && break ;;
        wp-edit|wp-edit-list|wp-admin|wp-front-auth)
            # a session that stopped being valid answers 302 to wp-login.php
            break ;;
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
    wp-rest-posts)
        printf '%s' "$hdr" | grep -qi '^content-type: application/json' || { log "preflight $name: REST answer is not application/json"; return 1; } ;;
    esac
    {
        echo "runtime=$name url=$(url_for) workload=$WORKLOAD http=$code bytes=${bytes:-?}"
        printf '%s\n' "$hdr" | grep -i '^x-drupal' || true
        # exactly which processes this runtime runs, so the reader can check that
        # both sides of a comparison are counted the same way
        local p
        for p in $(cg_pids "$name"); do
            printf '  pid=%s %s\n' "$p" "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
        done
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
        $3 ~ /^(cycles|instructions|context-switches|cpu-migrations|branch-misses|L1-icache-load-misses|itlb_misses\.miss_causes_a_walk)/ && $1 ~ /^[0-9.]+$/ {
            e = $3; sub(/:.*/, "", e); sub(/^context-switches$/, "cs", e); sub(/^cpu-migrations$/, "migrations", e)
            sub(/^branch-misses$/, "branch_misses", e)
            sub(/^L1-icache-load-misses$/, "l1_icache_misses", e)
            sub(/^itlb_misses\.miss_causes_a_walk$/, "itlb_miss_walks", e)
            printf "%s_%s %.4f\n", p, e, (n > 0 ? $1 / n : 0)
        }' "$1"
}

timed_cell() {  # phase side cell conns block slot runtime
    local ph=$1 side=$2 cell=$3 c=$4 k=$5 s=$6 rt=$7
    local name; name=$(start_rt "$rt" "$side") || die "start failed: $rt"
    local pre=0
    wait_http "$(url_for)" 60 || { log "$rt did not answer on $PORT"; }
    preflight "$name" "$side" || pre=1
    oha_args "$c" "$side"
    taskset -c "$LOAD_CPUS" "$OHA" -z "${WARM}s" "${OHA_A[@]}" "$(url_for)" >/dev/null 2>&1
    local pids rpids; pids=$(cg_pids "$name" | tr '\n' ' '); rpids=$(cg_pids "$(sv "$side" CNAME)" | tr '\n' ' ')
    rm -f "$R/perf.s" "$R/perf.db" "$R/perf.sf" "$R/perf.sw"
    perf_start s "$(echo $pids | tr ' ' ',')"
    perf_start db "$(echo $rpids | tr ' ' ',')"
    local fpids wpids
    if [ "${DECOMPOSE:-0}" = 1 ]; then
        fpids=$(pids_role "$rt" front "$name" | tr '\n' ' ')
        wpids=$(pids_role "$rt" worker "$name" | tr '\n' ' ')
        perf_start sf "$(echo $fpids | tr ' ' ',')"
        perf_start sw "$(echo $wpids | tr ' ' ',')"
    fi
    if [ "${PERF_RECORD:-0}" = 1 ] && [ "$ph" = ab ]; then
        rec_start "$side"
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
    if [ "${PERF_RECORD:-0}" = 1 ] && [ "$ph" = ab ]; then
        rec_stop "$side"
        # keep only each side's LAST ab cell: stable name, later cells overwrite
        # The recorder runs as root inside its container, so perf writes a 0600
        # root-owned file into the scratch: a plain cp as the host user fails and
        # 2>/dev/null hid it, which is why no published run ever kept a recording.
        # Copy through a root container, and fall back to cp for a user-namespaced
        # daemon where the file is already ours.
        if [ -f "$R/perf.rec.$side" ]; then
            docker run --rm -v "$R:/from:ro" -v "$OUTDIR:/to" alpine:3 \
                sh -c "cp /from/perf.rec.$side /to/perf.rec.$side && chmod 644 /to/perf.rec.$side" 2>/dev/null \
                || cp "$R/perf.rec.$side" "$OUTDIR/perf.rec.$side" 2>/dev/null
        fi
    fi
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
    local alerts=0 alog=
    [ "$pre" = 1 ] && alerts=$((alerts + 1))
    case "$rt" in
    freeunit|freeunit-master|freeunit-master-old|freeunit-master-mid|freeunit-musl|freeunit-direct|freeunit-master-o2|freeunit-master-lto|freeunit-742-base|freeunit-742-head|freeunit-master-33896f7|freeunit-768-base|freeunit-768-head|freeunit-master-10e1a9bec|freeunit-master-b532b9d|freeunit-master-13effad|freeunit-705-base|freeunit-705|freeunit-tip-e63168bd)
        alog=$(docker logs "$name" 2>&1 | grep -E '\[(alert|crit|emerg)\]' || true) ;;
    *)
        alog=$(docker logs "$name" 2>&1 | grep -E '\[(crit|emerg|alert)\]|worker process is shutting down unexpectedly' || true) ;;
    esac
    if [ -n "$alog" ]; then
        alerts=$((alerts + 1))
        # Read the text here: the container is removed a few lines down, so the
        # counter alone leaves an INVALID cell with no cause to chase, which is
        # exactly how one alert made a whole run unpublishable.
        printf '%s\n' "$alog" | sed "s|^|  $ph $side $cell block $k slot $s ($rt) alert: |" >&2
    fi
    emit "$ph" "$side" "$cell" "$k" "$s" alerts "$alerts"
    echo "  $ph $side $cell block $k slot $s ($rt): ok=$ok bad=$(awk '$1=="bad"{print $2}' "$R/oha.txt") server_us=$su db_us=$du alerts=$alerts"
    stop_rt "$name"
}

main() {
    start_db A
    [ "$SPLIT" = 1 ] && start_db B
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
    stop_db A
    [ "$SPLIT" = 1 ] && stop_db B
    echo CELLS-DONE
}
main
