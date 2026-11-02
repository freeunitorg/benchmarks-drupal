# Coverage audit and plan, 2026-11-01

Audit of the 218 published comparisons (`results/*/summary.json` after the master archive),
against the matrix the suite is supposed to cover: site × workload × runtime, plus the
database axis, the release axis (1.37.0 vs 1.37.1) and the pinning the cells were taken
with. "Present" means the runtime appears as either arm of a run on that site+workload.

## What is complete

| | |
|---|---|
| release axis on the Drupal lines | 11.4.8, 11.5.0-beta1, 12.0.0-beta2: anonymous **and** authenticated, 1.37.0 vs 1.37.1 |
| release axis off Drupal | symfony-front, wp-front, php-hello (12-thread cell) |
| runtime matrix on Drupal 12.0-beta1 front | FreeUnit vs nginx+FPM, Apache, Angie, FreeNginx, nginx-from-source |
| database axis on Drupal 12.0-beta1 | mysql, mysqli, pgsql |
| slow-client and work-loop legs | php-body / php-body-64k / php-work-200k (musl and glibc) |

## Gaps, by kind

### 1. The confound that changes published numbers (highest value)

Every application cell except `php-hello`-tuned runs **20 worker processes on 2-3 pinned
threads** (6.6x oversubscription). The framework-free cell measured both ways shows what
that does: 241k instructions and 192 us per request at 3 threads, 139k and 108 us at 12
threads, and the runtime ordering itself moves (nginx+FPM +57 % instructions at 3 threads,
+155 % at 12; Apache -29 % then +15 %). So the runtime ratios on the Drupal, Symfony and
WordPress pages are measured under a configuration no one deploys.

Missing: any application cell at balanced pinning (`settings.listen_threads` = `processes`
= the CPU count).

### 2. Runtimes missing as an arm (per site + workload)

```
site            workload        missing runtime
11.4            drupal-front    angie-fpm, freenginx-fpm
11.4            drupal-auth     apache
11.4-standard   drupal-front    apache, angie-fpm, freenginx-fpm
11.4-standard   drupal-auth     apache
11.5-beta1      drupal-front    apache, angie-fpm, freenginx-fpm
11.5-beta1      drupal-auth     apache, nginx-fpm
12.0-beta1      drupal-auth     apache
12.0-beta2      drupal-front    angie-fpm, freenginx-fpm
12.0-beta2      drupal-auth     apache, nginx-fpm
symfony         symfony-front   apache
hello           php-hello       apache
wp              wp-cron         apache
wp              wp-front        nginx-fpm (only on the second WordPress site)
```

### 3. Release axis missing on older sites

`12.0` (beta1, 45 runs), `11.4-standard`, `py-hello` and the arm64 page have no
1.37.0-vs-1.37.1 run. The 12.0 *page* does show 1.37.1 (through the beta2 site), so this is
history completeness, not a hole in the published answer.

### 4. Database axis

| site | dbs |
|---|---|
| 12.0-beta1 | mysql, mysqli, pgsql |
| 11.4 | mysql, sqlite |
| 11.5-beta1 | sqlite only |
| 12.0-beta2 | sqlite |
| symfony, wp | mysql only |

### 5. Data hygiene

- 26 runs carry `meta.site` = `http://127.0.0.1:8081` or `:8091` instead of `wp`. They land
  on the WordPress page (through the workload fallback) under a nonsense site title, and
  they are most of that page. The `site` field took the control-API URL, not the site key.
- `freeunit-symbolic` has no `RUNTIME_TITLE`, so it renders as a raw slug on the 11.4 page.
- `drupal-auth` preflight keys on `X-Drupal-Dynamic-Cache`, which an **anonymous** request
  also carries. Two cookie jars in this tree were empty and the cells still looked valid.
  Fixed by hand for the three sites; nothing in the harness prevents it.

## Plan

Cost model: one job is 16 minutes at `DUR=10 REPS=4` (64 timed cells) or 8-9 minutes at
`REPS=2`. Site builds are 5-12 minutes each. Windows are 4 hours.

### P0 - measure the applications the way they are deployed (80 min, 5 jobs)

Balanced pinning: `freeunit-tuned` vs `nginx-fpm-p12` / `apache-p12` (both images exist),
12 CPUs, `processes`/`listen_threads` = 12.

1. Drupal 12.0-beta2 front-anon: FreeUnit vs nginx+FPM
2. Drupal 12.0-beta2 front-anon: FreeUnit vs Apache
3. Drupal 12.0-beta2 front-auth: FreeUnit vs nginx+FPM
4. Drupal 12.0-beta2 front-auth: FreeUnit vs Apache
5. Drupal 11.4 front-anon: FreeUnit vs nginx+FPM

Acceptance: the three published runtime claims on the Drupal pages get a balanced-pinning
row beside them; if the delta changes by more than the two null bands, the old rows are
re-labelled "20 workers / 3 threads" in `docs/state.md` and the ranking table is regenerated
with the balanced runs as the primary ones.

### P1 - close the release axis (80 min, 4 jobs + 2 site builds)

6. build `12.0-sqlite` (beta1), run front-anon 1.37.0 vs 1.37.1
7. build `11.4-standard`, run front-anon 1.37.0 vs 1.37.1
8. `11.4-standard` front-auth 1.37.0 vs 1.37.1
9. `hello` at the historical 3-thread/20-worker pinning, 1.37.0 vs 1.37.1 (keeps the old
   hello series comparable; the tuned cell stays the headline)
10. `wp-cron` 1.37.0 vs 1.37.1 (one run, MySQL already on the node)

Not in this window: arm64 (needs the ARM box) and the Python leg.

### P2 - complete the runtime matrix (3 h, 11 jobs)

11.5 front-anon: Apache, Angie, FreeNginx · 11.5 front-auth: Apache · 12.0-beta2 front-anon:
Angie, FreeNginx · 11.4 front-anon: Angie, FreeNginx · 11.4 front-auth: Apache ·
symfony-front: Apache · php-hello: Apache (replaces the row lost with the master archive).

Images needed: `drupal-bench-angie:8.5`, `drupal-bench-freenginx:8.5` on the shared node
(they exist on the perf box; copy or rebuild from `Dockerfile.php --target angie-fpm`).

### P3 - database axis (1 h, 2 builds + 4 jobs)

11.5 on mysql (front-anon, front-auth) · 12.0-beta1 on sqlite (front-anon) · 11.4 on pgsql
(front-anon). MySQL and PostgreSQL containers already pulled on the node.

### P4 - hygiene (45 min, no measurement)

- `git mv` the 26 URL-keyed runs into a `site=wp` key: rewrite `meta.site` in `meta.txt` and
  `summary.json`, no re-run. Verify the WordPress page still renders the same 25 runs.
- `RUNTIME_TITLE["freeunit-symbolic"] = "FreeUnit 1.37.0 (symbolic routes)"`.
- `cells.sh`: `drupal-auth` requires a non-empty cookie jar **and**
  `X-Drupal-Cache: UNCACHEABLE` in preflight, else INVALID.
- `collect.sh` (or `perf-compare.py`): refuse a `meta.site` that is not a known key, so the
  URL-keyed class cannot come back.

## Order and rationale

P0 first: it is the only gap that can change a published conclusion. P1 second: it makes the
release story complete without new runtimes. P2 and P3 are breadth, valuable but they add
rows, not answers. P4 is cheap and stops the two data-quality problems from recurring.

Total: 5 h 45 m of measurement plus 1 h of builds, in two 4-hour windows (P0+P1, then
P2+P3), with P4 anywhere.
