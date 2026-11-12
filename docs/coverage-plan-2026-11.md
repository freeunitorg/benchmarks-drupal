# Coverage audit and plan, 2026-11-01

> Updated 2026-11-12. The audit below is kept as written; the changes since it are in
> "What happened since" at the end, so a reader can follow the reasoning and then see
> which of these gaps the later work closed.

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

## P0 outcome, 2026-11-02: the hypothesis was wrong for Drupal, and that is the result

Five cells at balanced pinning (12 listener threads, 12 workers, 12 FPM/prefork children,
12 pinned CPUs, no docker-proxy), 64 timed cells each, `bad=0` throughout:

| run | cell | pinned 12 threads | the published cell (20 workers / 2-3 threads) |
|---|---|---|---|
| `p0-01` | Drupal 12.0-beta2 front-anon, FreeUnit vs nginx+FPM | **+2.07 %** instr, band 0.09 | +2.29 %, band 0.05 |
| `p0-02` | Drupal 12.0-beta2 front-anon, FreeUnit vs Apache | **+18.05 %** instr, band 0.13 | +18.12 %, band 0.04 |
| `p0-03` | Drupal 12.0-beta2 front-auth, FreeUnit vs nginx+FPM | **+0.06 %** NO CLAIM, band 0.08 | tie on 12.0, +0.5 % on 11.4 |
| `p0-04` | Drupal 12.0-beta2 front-auth, FreeUnit vs Apache | **+5.94 %**, band 0.07 (new row) | not measured before |
| `p0-05` | Drupal 11.4 front-anon, FreeUnit vs nginx+FPM | **+1.74 %**, band 0.11 | +7.7 % (mysql) |

Read it honestly: **the oversubscription did not move the Drupal ratios.** 2.29 -> 2.07 and
18.12 -> 18.05 are inside one rounded point; the authenticated tie stays a tie. The
confound that the framework-free page exposed (241k -> 139k instructions per request, and
an order flip between Apache and FreeUnit) is a fixed per-request overhead that a 18 M
instruction Drupal page dilutes to nothing. So the runtime rows on the Drupal pages stand
as published, and no page needs re-labelling.

What the +7.7 % versus +1.74 % on 11.4 does show is the **database**, not the pinning: the
published 11.4 row is mysql, this one is sqlite, and the ranking table already separates
them by the `db` column. The absolute FPM overhead is ~1.1 M instructions per request with
a network database and ~0.4 M with the database inside the PHP process.

Two things P0 did produce:

1. a new row that was missing: **Apache on the authenticated page** costs +5.94 % CPU and
   6.7 % fewer requests, while answering each request much faster (p50 86 -> 33 ms) - the
   in-process mod_php shape, now visible on the render path instead of only on the cached
   one.
2. a guard that would have caught the two silent-authentication bugs: `drupal-auth`
   preflight now requires `X-Drupal-Cache: UNCACHEABLE`, which an anonymous request never
   carries. The second of those bugs is worth recording because it was new: sending the
   session cookie to the **container address** instead of `127.0.0.1` makes Drupal treat the
   request as a different host and answer anonymously, while the dynamic-cache header still
   looks right. Authenticated cells must therefore never use `DIRECT_NET`.

## What happened since this audit (2026-11-12)

1. **The set was cut to releases** (#6): 223 -> 59 comparisons. Arms that name a commit
   (`freeunit-tip-e63168bd` and the other experiment builds) moved to `results-archive/`;
   what stays is 1.37.0, 1.37.1, their `-tuned`/route variants and the server baselines.
   The Python page disappeared with the sweep because no `py-hello` run is tag-anchored;
   it returns with one `git mv` when the leg is re-measured against a release.
2. **1.37.2 is tagged** (`b36f4629`) and its column is measured against 1.37.1 on the same
   host as the 1.37.1 rows: Drupal 12.0.0-beta2 front-anon and front-auth, 11.5.0-beta1,
   11.4.8, Symfony 7.4, WordPress 7.1.3 and the 12-thread framework-free cell. Every
   application cell is NO CLAIM at bands of 0.03-0.2 %.
3. **The index answers the release question first** (#7): a ladder of release pairs and a
   baseline table, each cell carrying its host and database, so two columns of one row can
   never be compared without knowing where they came from.
4. **P0 is answered** (see the section above): the oversubscription did not move the Drupal
   ratios, so that gap was a plan error, not a data error. The framework-free page keeps
   its caveat, and P2 - the missing runtime arms, now including the authenticated page for
   Apache and the nginx forks - is the highest-value work left.

### What remains, in the order it is now worth doing

| | work | why now |
|---|---|---|
| P2 | Apache, Angie and FreeNginx on `drupal-auth` (12.0-beta2, 11.4); Apache on Symfony | the authenticated render is where the runtimes separate (P0 measured Apache at +5.94 % CPU and -6.7 % rps there) and no fork is measured on it |
| P1 | 1.37.2 on the sites the column does not have: 11.4-standard, `py-hello` (any arm), arm64 hello and Drupal 11.4 | release history stays complete per host |
| P3 | 11.5 on mysql, 12.0-beta1 on sqlite | the DB axis is still one-sided on the newest lines |
| P4 | the 26 WordPress runs whose `meta.site` is a control-API URL; upstreaming the `drupal-auth` cookie guard that lives only in the shared node's copy of `cells.sh` | data hygiene, and a guard that already caught two silent mis-measurements |
