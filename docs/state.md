# Current state (resume here)

Last updated 2026-10-10 ~18:35Z. Written so a fresh session needs three files:
this one, `run/campaign.done` on each box, and the run directories under
`results/`. Details live in `docs/progress.md`; the reusable lessons are in the
harness findings (`freeunit-harness/run/agent-findings/strace-20261010-*.md`).

## Published

Page: https://freeunit.org/benchmarks-drupal/ (Pages renders `results/*/summary.json`
plus the cron/queue TSVs; `report/render.py`, no typed numbers). Committed results: 14
measured runs + 4 tick runs.

| comparison (Drupal 11.4 umami / Symfony, c32, s_instructions) | verdict |
|---|---|
| front-anon FreeUnit 1.37.0 vs nginx+FPM | CLAIM, FPM 7.7% more |
| front-anon FreeUnit master vs FPM | CLAIM, FPM 7.7% more |
| front-anon FPM vs Apache+mod_php | CLAIM, Apache 54.7% more |
| front-anon master vs Apache | CLAIM, Apache 66.8% more |
| front-auth 1.37.0 vs FPM | CLAIM, FPM 0.6% fewer |
| front-auth master vs FPM | NO CLAIM (master 0.3% below FPM) |
| master vs 1.37.0 (anon, auth) | NO CLAIM |
| share probe (default vs direct routes) | NO CLAIM |
| Symfony front, 1.37.0 and master vs FPM | CLAIM, FPM 5.8% more |

Cron/queue arms: cold CLI 5.90 s mean vs HTTP 0.70-0.73 s on all three runtimes, no
process growth over 20 ticks. The authenticated-page gap is cycles and context switches,
not instructions or the database: `strace-20261010-auth-page-cycles-not-instructions.md`.

## Running right now

Both waiters ran their queues on 2026-10-10 ~18:42-18:51 and **every job failed**, on three
bugs that are now fixed (see below). The images were also stale: `bin/drupal-bench` is a PHP
script and the boxes have no PHP, so `bin/drupal-bench build` had been dying with
`/usr/bin/env: 'php': No such file or directory` and the waiter only warned. The image list now
lives in `scripts/build-images.sh` (no host PHP, builds master too, verifies the extensions) and
the waiter retries once then refuses to start. `run.sh` read `PORT` before anything set it
(`PORT: unbound variable`) and Drupal's mysqli driver needs the `mysqli` extension, which the
stale image did not have. Image rebuilds were restarted on both boxes; the queues then need
another run to pick up the new images.

The two hosts' waiters start a campaign when the CPUs a measurement uses are
quiet (≤5% over `SERVER_CPUS,DB_CPUS,LOAD_CPUS`) and the cell port is free:

* **pro4s-2**: `scripts/wait-idle.sh scripts/campaign.steps.all` (32 steps: Drupal 12 +
  12.0-standard + 11.4-standard, decomposition 27/28, cookie cells 29/30, DB backends
  35-38, pedantic mysqli 39-41, framework-free control 31-34, 12.0 cron arms).
* **pro4s-4**: `scripts/wait-idle.sh scripts/campaign.steps.wp` (WordPress 42-47).

Both are in tmux (`drupal-wait`, plus `drupal-watch` writing health lines). Check with:

```sh
ssh pro4s-2 'tail -3 /data/projects/benchmarks-drupal/wait-idle.log'
ssh pro4s-2 'grep -E "OK|FAIL" /data/projects/benchmarks-drupal/run/campaign.log | tail'
ssh pro4s-4 'tail -3 /data/projects/benchmarks-drupal/wait-idle.log'
```

A step counts as done only when it exits 0, so a failed build or job is retried by the
next run. `campaign.sh` stops at `DEADLINE_UTC` (06:00Z).

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
