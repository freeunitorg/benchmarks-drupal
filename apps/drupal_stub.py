"""
drupal_stub.py — Drupal cron/queue as a Unit app (app-level scheduler pattern).

Drupal differs from Laravel: `drush core:cron` and `drush queue:run <q>` are
ONE-SHOT commands — they process available work then EXIT. So the right Unit
primitive is NOT a long-lived supervisor (artisan `queue:work`) but a
**scheduler**: a tick loop that fires one-shot jobs on their intervals,
with overlap protection (never start a job while its previous run is alive).

This is the "scheduled-tasks-app" pattern applied to Drupal — maps 1:1 to a
`crontab` of drush lines, but lives in the Unit runtime (no host cron, no
Supervisor, one config).

Env:
  TRIGGER          how a tick reaches the job  [default "drush"]
                     "drush"     = spawn a cold one-shot CLI process per tick
                     "http"      = GET the fork-spawn endpoint (warm-opcache child)
                     "cron-url"  = GET the web runtime's own Drupal cron / queue
                                   routes (arm B, plan section 3.3): the request
                                   is served by a normal web worker
  SPAWN_URL        fork-spawn cron endpoint  [default http://127.0.0.1:8816/?job=cron]
  SPAWN_QUEUE_URL  fork-spawn queue endpoint [default SPAWN_URL with job=queue&name=<q>]
  WEB_URL          base URL of the runtime under test for "cron-url"  [default http://127.0.0.1]
  CRON_KEY         Drupal cron key for /cron/{key}                    [default benchmark]
  DRAIN_N          items per queue drain in "cron-url" mode            [default 50]

  DRUSH            drush binary (e.g. "drush" or "/var/www/html/vendor/bin/drush")
  DRUPAL_ROOT      path passed to drush via -r (e.g. /var/www/html)
  CRON_INTERVAL    seconds between cron ticks               [default 180 = 3 min]
  QUEUES           comma list of queue names to run          [default empty]
  QUEUE_INTERVAL   seconds between queue runs                [default 60]
  QUEUE_RUN_ARGS   extra args for queue:run                  [default "--time-limit=55"]
  ONESHOT          "1" = run every job once then keep serving [default unset]

  STUB_LOG         file to mirror tick lines into  [default $JOBDIR/stub.out]
                   (a Unit python app's stdout is not forwarded to the Unit log,
                    so the tick log must go to a file to be observable)

Each tick logs one line:
  [drupal] <job>: trigger=<mode> lat=<seconds> ...
"""

import asyncio
import os
import time

DRUSH = os.environ.get("DRUSH", "drush")
DRUPAL_ROOT = os.environ.get("DRUPAL_ROOT", "")
CRON_INTERVAL = int(os.environ.get("CRON_INTERVAL", "180"))
QUEUES = [q.strip() for q in os.environ.get("QUEUES", "").split(",") if q.strip()]
QUEUE_INTERVAL = int(os.environ.get("QUEUE_INTERVAL", "60"))
QUEUE_RUN_ARGS = os.environ.get("QUEUE_RUN_ARGS", "--time-limit=55")
ONESHOT = os.environ.get("ONESHOT") == "1"

# ---------------------------------------------------------------- trigger transport
# "drush": one cold CLI process per tick — the tick pays the whole PHP start +
#          opcache cold fill + Drupal bootstrap before it can sleep again.
# "http":  one GET to the fork-spawn app; the Unit PHP worker forks a child that
#          runs the job with WARM opcache, the tick returns immediately.
TRIGGER = os.environ.get("TRIGGER", "drush")
SPAWN_URL = os.environ.get("SPAWN_URL", "http://127.0.0.1:8816/?job=cron")
SPAWN_QUEUE_URL = os.environ.get("SPAWN_QUEUE_URL", "")
WEB_URL = os.environ.get("WEB_URL", "http://127.0.0.1").rstrip("/")
CRON_KEY = os.environ.get("CRON_KEY", "benchmark")
DRAIN_N = os.environ.get("DRAIN_N", "50")

STUB_LOG = os.environ.get("STUB_LOG") or (
    f"{os.environ['JOBDIR']}/stub.out" if os.environ.get("JOBDIR") else "")

_tasks: list = []


def _log(msg: str):
    """Tick log: stdout (may be swallowed by Unit) + a file we can read."""
    line = f"{time.strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    if STUB_LOG:
        try:
            with open(STUB_LOG, "a") as f:
                f.write(line + "\n")
        except Exception:
            pass


def _drush(args: str) -> str:
    root = f" -r {DRUPAL_ROOT}" if DRUPAL_ROOT else ""
    return f"{DRUSH}{root} {args}"


def _queue_url(name: str) -> str:
    if SPAWN_QUEUE_URL:
        return SPAWN_QUEUE_URL.replace("<q>", name)
    return f"{SPAWN_URL.split('?')[0]}?job=queue&name={name}"


def _cron_url() -> str:
    """Arm B: the runtime's own Drupal cron route, served by a web worker."""
    return f"{WEB_URL}/cron/{CRON_KEY}"


def _drain_url() -> str:
    """Arm B queue: the fu_queue_test drain route, one request for N items."""
    return f"{WEB_URL}/fu-queue-drain/{CRON_KEY}/{DRAIN_N}"


async def _http_get(url: str) -> tuple[int, str]:
    """Minimal asyncio HTTP GET — no subprocess, no third-party deps.

    Returns (status, body tail). Raises on connect/parse failure.
    """
    rest = url.split("://", 1)[1]
    hostport, _, path = rest.partition("/")
    path = "/" + path if path else "/"
    host, _, port = hostport.partition(":")
    port = int(port or 80)
    reader, writer = await asyncio.open_connection(host, port)
    try:
        req = (f"GET {path} HTTP/1.1\r\nHost: {hostport}\r\n"
               f"Connection: close\r\n\r\n").encode()
        writer.write(req)
        await writer.drain()
        raw = await reader.read(-1)
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass
    head, _, body = raw.partition(b"\r\n\r\n")
    status = int(head.split(b" ")[1]) if b" " in head else 0
    return status, body.decode(errors="replace").strip()


async def _run_once(name: str, target: str):
    """Fire one tick, log its latency (never raises into the loop)."""
    t0 = time.perf_counter()
    try:
        if TRIGGER in ("http", "cron-url"):
            status, body = await _http_get(target)
            _log(f"[drupal] {name}: trigger={TRIGGER} lat={time.perf_counter() - t0:.4f}s "
                 f"status={status} {body!r}")
        else:
            proc = await asyncio.create_subprocess_shell(
                target, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT)
            out, _ = await proc.communicate()
            lat = time.perf_counter() - t0
            tail = (out or b"")[-120:].decode(errors="replace").replace("\n", " ")
            _log(f"[drupal] {name}: trigger=drush lat={lat:.4f}s "
                 f"exit={proc.returncode} {tail}")
    except Exception as e:
        _log(f"[drupal] {name}: error {e!r}")


async def _ticker(name: str, target: str, interval: int):
    """Fire `target` every `interval` seconds; overlap-protected by awaiting it."""
    while True:
        await _run_once(name, target)
        if ONESHOT:
            return
        await asyncio.sleep(interval)


async def _scheduler():
    # cron tick
    if TRIGGER == "http":
        cron_target = SPAWN_URL
    elif TRIGGER == "cron-url":
        cron_target = _cron_url()
    else:
        cron_target = _drush("core:cron")
    _tasks.append(asyncio.create_task(
        _ticker("core:cron", cron_target, CRON_INTERVAL)))
    # one ticker per queue (Drupal queues are independent)
    for q in QUEUES:
        if TRIGGER == "http":
            tgt = _queue_url(q)
        elif TRIGGER == "cron-url":
            tgt = _drain_url()
        else:
            tgt = _drush(f"queue:run {q} {QUEUE_RUN_ARGS}")
        _tasks.append(asyncio.create_task(
            _ticker(f"queue:{q}", tgt, QUEUE_INTERVAL)))
    await asyncio.gather(*_tasks)


# ---------------------------------------------------------------- ASGI app
async def application(scope, receive, send):
    global _tasks
    if scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                _log(f"[drupal] scheduler up: trigger={TRIGGER} "
                     f"cron every {CRON_INTERVAL}s, "
                     f"queues={QUEUES or '[]'} every {QUEUE_INTERVAL}s")
                _tasks = [asyncio.create_task(_scheduler())]
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                for t in _tasks:
                    t.cancel()
                await send({"type": "lifespan.shutdown.complete"})
                return
    if scope["type"] == "http":
        body = (f'{{"cron_interval":{CRON_INTERVAL},"queues":{QUEUES!r},'
                f'"queue_interval":{QUEUE_INTERVAL},"trigger":"{TRIGGER}"}}\n').encode()
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"application/json"),
                                (b"content-length", str(len(body)).encode())]})
        await send({"type": "http.response.body", "body": body})
