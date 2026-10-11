# Current state (resume here)

Last updated 2026-10-11 ~18:50Z. Written so a fresh session needs three files:
this one, `run/campaign.done` on each box, and the run directories under
`results/`. Details live in `docs/progress.md`; the reusable lessons are in the
harness findings (`freeunit-harness/run/agent-findings/strace-20261010-*.md`).

## Published

Page: https://freeunit.org/benchmarks-drupal/ (Pages renders `results/*/summary.json`
plus the cron/queue TSVs; `report/render.py`). **22 measured runs**, plus 4 tick runs.
Only real measurements are published now: `collect.sh` skips a run whose headline is
`INVALID` or `NO DATA`, and the summary table shows `n/a` instead of dividing by a
zero mean.

| comparison (c32 server instructions, lower is better) | verdict |
|---|---|
| 11.4 umami front-anon, 1.37.0 and master vs nginx+FPM | CLAIM, FPM 7.7% more |
| 11.4 umami front-anon, FPM vs Apache | CLAIM, Apache 54.7% more |
| 11.4 umami front-anon, master vs Apache | CLAIM, Apache 66.8% more |
| 11.4 umami front-auth, 1.37.0 vs FPM | CLAIM, FPM 0.6% fewer |
| 11.4 umami front-auth, master vs FPM | NO CLAIM |
| 11.4-standard front-anon / front-auth | CLAIM FPM 6.8% more / NO CLAIM |
| 12.0 front-anon / front-auth | CLAIM FPM 10.3% more / CLAIM FPM 0.3% fewer |
| `hello`, `php-headers`, `php-body` (no framework) | CLAIM, FPM 97-197% more |
| Symfony front, 1.37.0 and master vs FPM | CLAIM, FPM 5.8% more |
| master vs 1.37.0, share probe | NO CLAIM |

Cron/queue arms: cold CLI 5.90 s mean vs HTTP 0.70-0.73 s on all three runtimes, no
process growth over 20 ticks.

**Drupal 12's `standard` profile is dropped** (arm removed, two INVALID runs deleted):
it installs no content model at all - zero `node.type.*`, zero
`core.entity_view_display.node.*`, no frontpage view - so there is no page to
benchmark. Evidence and the recipe path: the harness finding
`strace-20261010-drupal12-standard-front-page.md`. `12.0` (umami) covers Drupal 12.

## Working state

* **pro4s-2** ran the queue to completion 2026-10-11T02:08Z: 41 steps OK. Sites built:
  `11.4`, `11.4-mysqli`, `11.4-pgsql`, `11.4-sqlite`, `11.4-standard`, `12.0`, `hello`,
  `symfony`.
* **pro4s-4** is stopped: the WordPress job produced 49 result rows in 9 h (~1.5 h per
  cell) and was going nowhere; its containers were cleared by hand.
* Both waiters are ready but `DEADLINE_UTC=06:00Z` has passed, so a campaign will not
  start until the grant is extended.

## What is left

Harness bugs that are fixed but not yet re-run:

1. **Cookie cells 29/30** - `COOKIE_HDR` was built before the cookie jars existed
   (fixed: start from `COOKIE_HDR_A`, and do not overwrite it later).
2. **Decomposition 27/28** - asks for `worker_us`, but the null phase never emits it, so
   the run is `NO DATA`. The sampler must emit `front_us`/`worker_us` in the null blocks.
3. **DB axis 35-41** - `cells.sh: cannot start postgres` / `cannot start mariadb` /
   `start failed: freeunit` (sqlite). The sites exist; the cell helper's start path for
   the alternate backends was never validated.

Never validated:

4. **WordPress 42-47** - the cell loop stalls after a few cells; diagnose the
   perf-sampler/container restart between cells.
5. **Perf variants** `12.0-nopt` / `12.0-preload`, jobs 48/49 - not in the campaign.

Waiting on others:

6. **Drupal 11.5** - `11.5.x-dev` is not on Packagist yet (support is coded; PHP 8.5).
7. **Master pin** - 13 commits behind `origin/master` (libunit memory fixes, none PHP).

Product:

8. **`freeunit` Drupal module** (freeunit4drupal/packages/freeunit) - installed nowhere
   yet; validate on the 12.0 site (path repo, enable, `APP_RUNTIME`), then a stock vs
   module job.

## Traps that cost the most (full list in the findings and docs/progress.md)

* `vendor/bin/dr install` can never install into a database (early return on any
  `$databases`, SQLite otherwise); `install_drupal()` with the driver spec is the path.
  `dr install` in 12 does accept a **recipe** but still requires `pdo_sqlite`.
* `composer dump-autoload --classmap-authoritative` breaks Drupal 12: core registers
  module namespaces at runtime and the driver class then cannot be found. `--optimize`
  alone is safe.
* `docker run | grep -q` under `set -o pipefail` fails with 141 when grep stops early;
  read the output into a variable (this bit the image check and both MariaDB waits).
* Never `pkill -f` a pattern that matches the command you are running in.
## Validated against built

Built and cookie-verified: `site/11.4`, `site/11.4-standard` (drush path), `site/12.0`
(drush-free path), `site/symfony`. Code-complete but **not yet built or measured**:
`12.0-standard`, `11.4` on `mysqli`/`pgsql`/`sqlite`, `wp`, `wp-persistent`, `hello`;
also unmeasured: decomposition and cookie cells, DB backends, mysqli pair, WP.

## Traps that cost the most (full list in the findings and docs/progress.md)

* `vendor/bin/dr install` can never install into a database: it early-returns on any
  `$databases` in settings.php and hardcodes SQLite otherwise. Use `install_drupal()`
  with the driver spec (`apps/drupal_cli.php install`).
* The tool-container command is one host double-quoted string: no backticks, no bare `"`,
  no unescaped `$` inside it, comments included.
* Never `CREATE USER` outside the MariaDB entrypoint (1396 kills the container and shows
  up later as a DNS failure); wait for the init markers and retry a stuck first run.
* The MariaDB image runs a temporary init server, so a client can answer *before*
  initialization finishes; wait for the init markers, not just a successful `SELECT 1`.
* `LC_ALL=C` in measurement scripts (awk printed `37,6`).

## Other live threads

* **freeunit-exp** (bot workbench fork): issue #6 is the agent's task list. T1 (Unit
  config is string-only, unknown keys abort) and T2 (Drupal core install owns SQLite)
  are verified and merged as PRs #7/#8; T3 (one test case for the string rule) has a
  go-ahead. My comment on #6 corrects the Drupal 12 recipe (never `dr install`). Open:
  PR #9 (bot README) and #5 (review of PR 645). The App still needs this fork in its
  repository access list.
* **freeunit4drupal**: issue #1 carries the three findings that bear on its plan
  (D6 PHP provisioning, D7 support matrix, D8 databases, D11 config generation).
* The harness perf-suite patch (DB_CPUS + `db_*` descriptions) is still uncommitted in
  the harness working tree; the finding has the mutation evidence.

## Next steps

1. Let the queues run, then `bin/drupal-bench collect pro4s-2` (and `pro4s-4`) and push;
   the page picks up new runs automatically. Collect only run ids from the job list:
   another session shares `/data/projects/benchmarks-drupal/run` on pro4s-4.
2. Fix whatever fails first (site builds are the fragile part; each failure is retried).
3. Then: Drupal 12 cron arms, the mysqli worker-mode question (issue 596), Alpine/musl
   image, `benchmarks-drupal` naming now that WordPress lives there.
