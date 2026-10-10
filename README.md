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

Phase 0 (classic mode, all three runtimes). Repository, Dockerfiles and the
measurement harness are in place; site install and the first published chart
follow. Phase 1 (FreeUnit PHP worker mode, issue 596) and phase 2 (schedules,
PR 452) are planned but not started.
