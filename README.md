# benchmarks-drupal

Drupal on **Apache + mod_php**, **nginx + PHP-FPM** and **FreeUnit**, measured on
one pinned box with the perf-lab method (null band, swapped blocks, `schedstat`
CPU, `perf stat` counters). The published page is rebuilt from committed raw
data; no number in it is typed by hand.

Live page: https://freeunitorg.github.io/benchmarks-drupal (once `results/` has
its first run).

Plan and decisions: the harness page
`freeunit-harness/docs/perf/drupal-benchmark-plan-2026-10.md` (sections 1 to 11),
including the four settled decisions (separate repo; `demo_umami` in phase 0;
1.37.0 tarball default plus a master column; `powersave` governor recorded and
instructions per request as the headline metric).

## What it measures

| workload | request | what it is |
|---|---|---|
| `drupal-front` | `GET /` anonymous | page-cache hit: server + cache-bin read + response copy |
| `drupal-auth` | `GET /` with a session cookie | full render through `dynamic_page_cache` |
| `wp-front` | `GET /` anonymous | WordPress render: bootstrap, queries, template, no page cache |
| `wp-cron` | `GET /wp-cron.php?doing_wp_cron=1` | the WordPress HTTP cron path |
| cron arm A | `drush core:cron` | cold one-shot CLI, the hosting-guide default |
| cron arm B | `GET /cron/{key}` | a normal web worker; how `automated_cron` runs, and the issue 321 case |
| queue arm A | `drush queue:run fu_queue_test` | 50 items, cold CLI |
| queue arm B | `GET /fu-queue-drain/{key}/50` | 50 items on a web worker |

Arms are the place FreeUnit has a story: issue 321 (a cron run stranding a
visitor's worker) was fixed in 1.37.0, and schedules follow in phase 2.

## Layout

```
docker/          Dockerfile.php (php-base/php-fpm/apache), Dockerfile.freeunit,
                 php-production.ini, entrypoint scripts, runtimes/*.json|conf
site/            built sites (not committed): site/11.4, site/12.0
modules/         fu_queue_test: one queue worker + the HTTP drain route (arm B)
apps/            the gist's drupal_boot_cron.php, drupal_boot_queue.php,
                 fork_spawn.php, drupal_stub.py (arm A/B/C ticker)
bench/           cells.sh (measured cells), run.sh (claim/gate/compare),
                 tick.sh (cron+queue arms), perf-compare.py, jobs/*.job
report/          render.py: results/*/summary.json -> index.html
results/         one directory per run: results.tsv, summary.json, meta.txt,
                 compare.txt, job.txt -- the only source of truth
scripts/         site-build.sh
```

## Using it from another project

The repository is a Composer package with one entry point, so the FreeUnit
harness (or any other project) can depend on it instead of copying scripts:

```bash
composer require --dev freeunitorg/benchmarks-drupal:^0.1   # or a path repository
vendor/bin/drupal-bench build
vendor/bin/drupal-bench site 11.4
vendor/bin/drupal-bench run bench/jobs/02-front-anon-freeunit-vs-fpm-11.4.job
vendor/bin/drupal-bench collect && vendor/bin/drupal-bench report
```

See [docs/composer.md](docs/composer.md); the Drupal module (queue worker, drain
route, `dr bench` command) is also published as `freeunitorg/fu-queue-test`
(`type: drupal-module`).

## Running it

```bash
make sync                       # copy to the perf host
make build                      # three runtime images + mariadb
make site SITE=11.4             # composer create-project, demo_umami, fu_queue_test
make bench JOB=bench/jobs/01-null-front-anon-11.4.job     # null band first
make bench JOB=bench/jobs/02-front-anon-freeunit-vs-fpm-11.4.job
make ticks RUNTIME=freeunit ARM=A TICKS=20
make pull && make report        # results back, then render locally
```

`make bench` refuses a busy box (idle gate ≤5%) and writes a claim file under
`CLAIM_DIR`. `REPS` blocks alternate `X Y Y X Y X X Y` and `Y X X Y X Y Y X`, so
slot bias cancels. `bench/perf-compare.py` is the harness tool unchanged: it
decides CLAIM / NO CLAIM / NOISY / INVALID and prints the null band under every
chart.

## How to read a result

1. Read the **null phase** first: the same runtime against itself, with the band
   it produced. Under the `powersave` governor a 2 s cell cannot resolve small
   differences; that is why cells are 8 s here and `s_instructions` is primary.
2. A **CLAIM** needs the delta outside the null band, a 95% CI excluding 0, and
   at least 3 of 4 adjacent slot pairs agreeing.
3. `NOISY` is a result, not a retry ticket. `INVALID` means a non-200 answer, an
   alert in the runtime log, or a missing page-cache `HIT` in preflight.

## WordPress

WordPress 7.1.3 (wp-cli 2.12.0, both pinned) is a third application: no page cache, so
its front page is a full render, and its `wpdb` is mysqli-only. `wordpress/db-persistent.php`
is a `wp-content/db.php` drop-in that opens a persistent mysqli handle -- WordPress core
has no persistent-connection support -- and jobs 46/47 compare it with stock wpdb in one
job. See [docs/wordpress.md](docs/wordpress.md).

## Database backends

The default is MariaDB 10.11 through Drupal's PDO `mysql` driver. Three more are
selectable per site (`DB=mysql|mysqli|pgsql|sqlite`), each with its own installed
site, volume and `meta.txt` line, because a driver cannot be swapped under an
installed site:

| DB | driver | server |
|---|---|---|
| `mysql` | `mysql` (PDO) | MariaDB 10.11 |
| `mysqli` | the experimental core `mysqli` driver | the same MariaDB, different PHP extension |
| `pgsql` | `pgsql` | PostgreSQL 17 (`trust`) |
| `sqlite` | `sqlite` | a file under `sites/default/files/` |

The images carry `pdo_mysql`, `mysqli`, `pdo_pgsql` and `pdo_sqlite`, so one PHP
build serves every backend. [docker/db-drivers.md](docker/db-drivers.md) has the namespaces and why the
`mysqli` pair is interesting for a future PHP worker target (issue 596): a
connection that survives between requests is where a persistent in-process worker
can win.

## Pins (recorded per run in `meta.txt`)

* PHP `8.5.11` for all three runtimes, `php-production.ini`, JIT off.
* FreeUnit `1.37.0` release tarball, sha256
  `8ae237d5a32d77bb8a7426d844ce75aeb18583a4e47318f55e17839d865fad8c`;
  a `master` column can be built with `--build-arg FREEUNIT_REF=master` and must
  never share a chart with the tarball.
* Drupal `drupal/recommended-project:11.4.8` and `12.0.0-beta1`, `demo_umami`,
  `big_pipe` uninstalled, `composer.lock` committed per site.
* MariaDB `10.11`, one container per run, same for every runtime.

## Status

Phase 0 (classic mode) has run: Drupal 11.4.8 and a Symfony 7.4 app, all three
runtimes, null band in every job. Headlines on `s_instructions` per request:

* nginx+PHP-FPM does **7.7% more** work than FreeUnit on the cached Drupal front
  page (12/12 cells, null band 0.1%), and **5.8% more** on the Symfony page.
* Apache+mod_php does **54.7% more** than nginx+PHP-FPM on the cached Drupal page.
* On the authenticated Drupal render the order flips by a hair: FreeUnit does
  **0.6% more** than PHP-FPM.
* No claim for FreeUnit master vs the pinned 1.37.0 on either Drupal workload or
  on Symfony, and none for the `share` probe.

Drupal 12.0.0-beta1 is blocked: drush 13 needs `guzzlehttp/guzzle ^7`, every 7.x
release is refused by the advisory policy, and the 12.0 lock pins guzzle 8, so the
site cannot be installed; see `docs/progress.md`. Phase 1 (PHP worker mode, issue
596) and phase 2 (schedules, PR 452) are planned but not started.
