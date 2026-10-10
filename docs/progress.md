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

### Unit config rejection: no `_comment` key

Unit validates the configuration strictly: a `_comment` key at the top level aborts the
whole config with `Unknown parameter "_comment"`, and the application never starts. Both
`freeunit-direct.json` and `freeunit-worker.json` carried one; the share-probe job then
produced an INVALID result (36 cells with `ok=0`, HTTP 000) before the key was removed.
Notes about a config go in this file, not in the JSON.

### Drupal 12.0.0-beta1 is blocked in phase 0 (drush vs the 12.0 lock)

`composer create-project drupal/recommended-project:12.0.0-beta1` succeeds, then
`composer require drush/drush:^13` (or `-W`) fails: drush 13 requires
`guzzlehttp/guzzle ^7.0`, the 12.0 lock pins guzzle 8.2.0, and every guzzle 7.x release is
refused by packagist's security-advisory policy (14 advisories), so composer will not
downgrade. Without drush the site cannot be installed or have `fu_queue_test` enabled.
The 12.0 jobs stay in `bench/jobs/` and are commented out in `scripts/campaign.steps` with
this reason. Follow-up: use Drupal core's own `core/scripts/drupal install` plus a
bootstrapped PHP script for `module_installer()->install()`, or wait for a drush release on
guzzle 8. The 11.4 matrix and the Symfony app are unaffected.

## 2026-10-10 10:42 CEST — phase-0 campaign finished (Drupal 11.4 + Symfony 7.4)

Ten measured runs on the perf host, all with a null phase in the same window. Primary
metric `s_instructions` per request (the governor is `powersave`); every null band printed
below came from the same job.

| job | workload | comparison | verdict | null band |
|---|---|---|---|---|
| 02 | drupal-front | FreeUnit 1.37.0 vs nginx+PHP-FPM | **CLAIM: FreeUnit 7.7% fewer** server instructions/req, 12/12 cells | 0.1% |
| 03 | drupal-front | nginx+PHP-FPM vs Apache+mod_php | **CLAIM: Apache 54.7% more** server instructions/req, 12/12 cells | 0.1% |
| 04 | drupal-auth | FreeUnit 1.37.0 vs nginx+PHP-FPM | **CLAIM: FPM 0.6% fewer** server instructions/req, 12/12 cells | 0.3% |
| 06 | drupal-front | FreeUnit master vs 1.37.0 | NO CLAIM (0.0%, band 0.2) | 0.2% |
| 07 | drupal-auth | FreeUnit master vs 1.37.0 | NO CLAIM (0.2%, band 0.3) | 0.3% |
| 05 | drupal-front | FreeUnit share+fallback vs direct pass | NO CLAIM (0.0%, band 0.2) | 0.2% |
| 01 | drupal-front | null | PASS | 0.1% |
| 14 | symfony-front | FreeUnit 1.37.0 vs nginx+PHP-FPM | **CLAIM: FreeUnit 5.8% fewer** server instructions/req, 12/12 cells | 0.2% |
| 15 | symfony-front | FreeUnit master vs 1.37.0 | NO CLAIM (0.0%, band 0.1) | 0.1% |
| 13 | symfony-front | null | PASS | 0.2% |

Cron/queue arms (20 ticks each, `results/ticks-*/ticks.tsv`): the cold CLI arm
(`freeunit-A`: `drush core:cron` / `queue:run` in a fresh process) returns in a mean 5.90 s
(median 2.73 s), while the HTTP arm (`freeunit-B`, `GET /cron/{key}` and the queue drain
route) returns in 0.73 s, nginx+FPM B in 0.70 s and Apache B in 0.73 s. Process counts are
stable across the 20 ticks (24→24 FreeUnit), so no fork child leaked; the per-tick CPU of
the CLI arm read as 0 because `docker exec`'s process was not sampled — a follow-up, the
wall times are unaffected.

Reading the two Drupal rows together: on the page-cache hit FreeUnit does 7.7% less work
than nginx+FPM, and on the authenticated render it is 0.6% more (FPM wins by a hair). The
54.7% gap between FPM and mod_php is the largest single number in the set. The FreeUnit
master column shows the `39700f29` message-queue cost does not surface on either Drupal
workload at these cells, and the share-probe row says the simple `share`+`fallback` config
costs nothing measurable, so it stays.
