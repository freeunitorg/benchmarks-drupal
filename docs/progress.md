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

## 2026-10-10 ~07:30 CEST — campaign launched on the perf host

The box was granted for eight hours. `scripts/campaign.sh` runs the phase-0 matrix
sequentially (site builds first, then the null bands, the runtime comparisons, the
FreeUnit 1.37.0-vs-master column, the share probe, the cron/queue arms, Drupal 12.0 and
finally the Symfony app). It is resumable through `run/campaign.done` and stops at
`DEADLINE_UTC` (13:00Z by default) so it cannot overrun the grant. `scripts/watchdog.sh`
appends a health line every two minutes and flags a stall; it kills nothing.

Bugs found and fixed before the first job (all of them would have silently produced a
page of zeros):

* **Unit config rejected.** `"opcache.enable": 1` must be a string. With integers Unit
  logged `the previous configuration is invalid: The "opcache.enable" PHP option must be
  a string` and served nothing; the symptom seen first was curl exit 56 while fetching the
  site's one-time login link.
* **Stale runtime config.** `cells.sh` mounts `$RUNROOT/runtimes/*.json`; those copies are
  now refreshed from the repository at the top of every campaign run.
* **Perf counters.** The host blocks `perf` for this user (`perf_event_paranoid=4`) and
  sudo needs a password, so the counters run in a `--cap-add PERFMON --pid=host` container
  from `freeunit-perf-lab:1`, the harness method. Verified: a probe on pid 1 printed
  cycles and instructions.
* **Empty `ok`.** The oha JSON was parsed with its stdout redirected into a file *inside*
  a command substitution, so `ok` was empty and every per-request metric (s_instructions,
  server_us, db_us) became 0. Caught by the smoke job: it printed `ok=` with no value.
* **Ephemeral database.** MariaDB data now lives on a per-site named volume
  (`drupal-bench-db-11.4`); the first design started a fresh database per job, so the
  installed site had no tables and Drupal redirected to `/core/install.php`.
* **Idle gate.** `/proc/stat` has ten fields after `cpu`; the previous `read` split them
  and arithmetic on the tail failed. Now computed in awk from two samples.
* **Job files.** `PHASES=null ab` was a shell statement (`ab(1)` ran); `EXPECT`/`FALSIFY`
  with spaces are quoted. A lint workflow now sources every job file.

Smoke result (one block, c6, 3 s, FreeUnit 1.37.0, Drupal 11.4.8): null gate PASS,
`s_instructions` +0.03 percent, band 0.35 percent; `server_us` 4.05 ms vs 3.86 ms,
`db_us` 2.08 ms, `rps` ~500. Real counters, so the pipeline is trustworthy.
