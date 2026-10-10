# Progress log

Mirror of the harness plan's progress log, for this repository's own steps.
Every entry names the evidence, not just the action.

## 2026-10-10 — phase 0 scaffolded, images building on the perf host

Decisions already settled (harness plan section 10, finding
`strace-20261007-drupal-bench-decisions.md`): separate repo `freeunitorg/benchmarks-drupal`
(1a); `demo_umami` only in phase 0 (2c); FreeUnit 1.37.0 tarball default plus a master
column (3a); `powersave` + EPP `balance_power` recorded, instructions per request as the
headline metric (4b).

Built in the repository:

* `docker/Dockerfile.php` with targets `php-base` / `php-fpm` / `apache` on
  `php:8.5.11-*-trixie`, one extension set and `php-production.ini` shared by all three
  runtimes; `docker/Dockerfile.freeunit` builds the pinned 1.37.0 tarball
  (sha256 checked) and can take `--build-arg FREEUNIT_REF=master` for the second column.
* Runtime configs: `freeunit.json` (share + fallback, as app-api), `freeunit-direct.json`
  (the A/B variant that answers the plan's "does the share probe cost" row),
  `nginx.conf` (Drupal rewrite recipe, `gzip off`), `apache.conf` (prefork, 20 workers),
  `php-fpm.conf` (static, 20 children, recycle 10000).
* `bench/cells.sh` generalised from the harness perf-lab cells: same results TSV schema
  and 8-cell block design, so `bench/perf-compare.py` (copied unchanged) still decides the
  verdicts; the A/B axis is now the runtime, CPUs come from each container's cgroup
  `schedstat`, and `db_us` is sampled for the MariaDB container (plan section 5.3).
* `bench/run.sh` (claim + idle gate + cells + compare + meta) and `bench/tick.sh`
  (cron/queue arms A and B); `scripts/site-build.sh` (composer create-project, `demo_umami`,
  `fu_queue_test` enabled, `big_pipe` uninstalled, cron/queue keys set, auth cookie stored).
* `modules/fu_queue_test` gained the HTTP drain route for arm B
  (`/fu-queue-drain/{key}/{n}`); `apps/drupal_stub.py` gained `TRIGGER=cron-url`.
* `report/render.py` (summary.json -> index.html, no typed numbers) and the `pages`
  workflow.

Fixes found while building (each cost one failed image build, recorded so the next
person does not repeat them):

1. `install-php-extensions` was called without copying the installer into the stage —
   exit 127. It must be copied from `ghcr.io/mlocati/php-extension-installer:2`.
2. In `Dockerfile.freeunit` the installer stage was prepended *above* the global `ARG`
   lines, so `ARG FREEUNIT_REF` inside the build stage was empty and `set -u` failed with
   `FREEUNIT_REF: parameter not set`. Global `ARG`s must come before the first `FROM`.

First build of the FreeUnit image succeeded (the pinned tarball configure/make/install
stage completed); the extension stage of `Dockerfile.php` was still running when this
entry was written. Next: site install for 11.4, then job 01 (null band) and job 02.

Host state at the time: perf host idle (load 0.12, no containers), a stale claim file
from 2026-09-04 present and ignored; the box's `PERF_WINDOW` is 01:00-06:00, so full
16-minute matrices wait for that window while short cells and builds do not.
