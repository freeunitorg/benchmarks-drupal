# Current state (resume here)

Last updated 2026-10-13 ~02:00Z. A fresh session needs three things: this file,
`run/campaign.done` on each box, and `results/`. Details in `docs/progress.md`; the
reusable lessons are in the harness `run/agent-findings/strace-20261012-*.md` and
`opencode-2026101*` files.

## Published

https://freeunit.org/benchmarks-drupal/ — 22 measured runs + 4 tick runs, rebuilt by
Pages from `results/*/summary.json` (`report/render.py`, no typed numbers; `collect.sh`
skips INVALID/NO DATA runs).

Headline verdicts (c32 retired instructions, lower is better): cached Drupal front page
**FPM +7.7 %** vs FreeUnit 1.37.0 and vs master (11.4 umami), **+6.8 %** (11.4 standard),
**+10.3 %** (12.0), Symfony **+5.8 %**, Apache **+54.7 % / +66.8 %**; framework-free PHP
**+97 / +109 / +197 %**; authenticated Drupal a tie (1.37.0 −0.6 %, master inside noise,
12.0 FPM −0.3 %, the difference being cycles/CX not instructions/DB); master vs 1.37.0 and
the share probe NO CLAIM. Written up for humans in `docs/report-2026-10.md`.

## Running now: two boxes, two loops, both gated on someone else's work

Published: 30 comparisons on five pages (`index`, `drupal-11.4`, `drupal-12.0`,
`php`, `symfony`); the report was split per application family because the single
page had reached 103 KB and the runtime x database matrix lands on Drupal.

**pro4s-2** (`sd-91675`, tmux `ws-loop`) finishes the master bisect and then runs
the matrix: `scripts/campaign.steps.master-bisect` (56 body mid->new, 57/58 the
Drupal 12 pair) then `scripts/campaign.steps.matrix-12` (15 jobs: Drupal 12
front-anon x mysql/mysqli/pgsql/sqlite x Angie/FreeNginx/nginx/nginx-src against
FreeUnit, plus the two fork-vs-source-nginx checks).  The loop retries a pass that
loses jobs to a busy window, up to 2026-10-14T06:00Z.  It is waiting: another
session has the box at 100 % busy with three containers.

**pro4s-4** (`sd-92483`, tmux `wp`) runs `scripts/campaign.steps.wp`:
75-wp-smoke (deleted after it passes, never published), then 42-47.  Its `run/`
tree and the two WP sites were rebuilt from scratch because the old ones predated
the drop-in fix and five stalled `42-*` directories were left behind by the
nine-hour hang.  Waiting too: 49 foreign containers and 22 % busy on the measured
CPUs.

The new runtimes (Angie 1.12.3, FreeNginx 1.31.4, nginx 1.31.6 from source) are
built and smoke-tested: all three serve the hello app including `?mode=body` and
`?mode=headers`, and their process titles are `angie:` and `nginx:` as the perf
sampler expects.  `freeunit-master` is rebuilt at `2dc6596f` (was `868ccc29`
until 2026-10-12, so every earlier master number came from that commit).

Collected so far from the bisect: 53/54/55, which attribute the whole response-path
win to #638 (-10.06 % instructions, 12/12) and none to #670 (+0.23 %, inside the
band).  56 came back INVALID during the interference (alerts=1, ok-counts halved)
and is retried; the 27/28 decompose runs are deliberately unpublished NO DATA.

Traps from this stretch:

* `wait_http` ran `curl` with no timeout, so a runtime that accepted the
  connection and stopped answering hung a job for 2h25m (the same shape as the
  nine-hour WordPress stall).  Fixed with `--connect-timeout 2 --max-time 5`.
* the campaign understands only `site:`/`job:`/`ticks:` lines (a bare job name is
  `unknown step` rc=99), and a `campaign.done` line is not evidence that the
  artefact still exists: a stale `site:12.0 exit=0` skipped a site rebuild whose
  directory had been deleted.
* on a box shared with another session, name the prefixes:
  `COLLECT_ONLY="42- 43- 44- 45- 46- 47-" scripts/collect-commit.sh pro4s-4`.
* `ssh pro4s-2` and `ssh pro4s-4` work with the default config, so `make sync`,
  `collect.sh` and `collect-commit.sh` need no `-F`.

## Upstream work (freeunitorg/freeunit)

* **#679 / PR #680 — python: the embedded interpreter can load the system stdlib.**
  Branch `python/base-prefix-home`, head **`b35a3bdf`**, based on master `87c5059f`.
  The fix records `sys.executable` at configure time and sets `config.executable` when the
  application config has no `home`. Verified end to end on aarch64: a module built for
  `/tmp/altbindir` reports that prefix, that executable and its site-packages; a system
  build is unchanged. CI: **1 failed, 460 passed, 2 errors** — `test_python_application_path`
  (`No module named 'wsgi'`, about `nxt_python_set_path` for a `path`-only app, independent
  of this change) and `test_python_isolation_rootfs_no_language_deps` (the rootfs has no
  interpreter `bin`, and CPython 3.14 refuses an isolated config whose executable is
  absent). All non-Python legs green. The three options are in the PR comments; part 2
  (mount + `sys.path`) is unavoidably coupled, so it needs a decision, not another variant.
* **#33 — h1p: do not read a h1proto's connection through a foreign object** (draft PR).
  Independently verified by me: pre-change the crash call **SIGSEGV, exit 139**; the head
  passes **86 tests, exit 0**, and `.github/scripts/check-test-hooks.sh` is rc=0. Caller
  narrowed in a comment: `nxt_h1p_shutdown()` (`nxt_h1proto.c:2634`) reads `c->socket.data`
  as a h1proto, reached from `nxt_h1p_conn_close/error`, the close/error handlers of the
  three idle/keepalive states, while the peer path puts `nxt_http_peer_t` in the same slot.
  Ready for the maintainer's review.
* Earlier: kTLS numbers and the aarch64 result are on #29; the static-handler `sendfile`
  finding is #32 (the bot corrected my gate: `nxt_conn_io_sendbuf()` chooses by buffer type,
  `.old_sendbuf` has no reader); the Drupal 12 standard-profile/recipe finding is on
  freeunit4drupal#1.
* **#22** (isolation + cgroup v2, a research task held until 1.37.1): I contributed measurements
  without claiming the task.  (a) On the aarch64 cgroup-v2 host a hand-made
  `cpu.max=100000 100000` makes unitd log `the cgroup CPU limit lowers the CPU count from 2 to 1`,
  a control with no quota stays at 2, a **cpuset** restriction is invisible to it, and an
  ancestor quota is honoured because the walk takes the minimum non-zero `cpu.max` up the tree.
  (b) Throttle trace, PHP 8.5.11 `processes: 8`, `wrk -t2 -c32 -d10s`: control 48 999 req/10 s,
  p50 5.89 ms, p99 16.83 ms, `cpu.stat` clean; a half-CPU quota 12 637 req/10 s, p50 26.28 ms,
  p99 89.85 ms, `nr_throttled` 100 of 125 periods, `throttled_usec` 14.5 s in a 10 s window
  (summed per task, so it exceeds wall time).  A fractional quota is reported as one CPU.
* **#638 / #670** (the two response-path merges): the combined A/B result is posted on both,
  labelled as unattributed, with the bisect to follow.
* Open profiling-shaped items in the exp queue as of 2026-10-13: **#36** (32-bit musl leg),
  **#34** (kTLS step 2), **#32** (static sendfile), **#22** (above), **#11** (1.37.1 review
  follow-ups), **#6** (benchmark-finding verification, already answered).

## Harness

* `freeunitorg/freeunit-harness` **PR #1**: the aarch64 host recipe
  (`skills/freeunit-cross-arch/references/aarch64-host.md` + a References pointer),
  `make doctor` clean, `@codex review` requested, **no review posted yet**.
* `run/servers.md` (private) carries the Oracle aarch64 inventory; the ARM recipe is the
  public skill reference.  Note `~/fu` on that host is **not** upstream master (it carries
  the #659 callback form of `nxt_cgroup_cpu_max_read()` and `git merge-base` shows
  `87c5059f` is not an ancestor), so pin a SHA and say which tree when quoting a line.
* `tools/exp-queue-watch.sh` polls the fork's open issues over REST (the GraphQL budget is
  shared and was exhausted once), keeps `run/exp-queue-state.tsv`, logs changes to
  `run/exp-queue-watch.log` and posts them on the bus; it flags titles that look like an
  unclaimed profiling task.  It runs in a detached loop on the laptop (no tmux there).
  A transient `gh` failure must not blank the snapshot, or every issue looks new next time.
* Task ledger: `job/python-home-prefix` (issue #679 linked), `research/kernel-cheap-wins`
  (survey → #32/#34, real-NIC A/B outstanding), `tag/1.37.1` (677 recorded).


### Upstream CI and layout work (2026-10-13)

* **PR #700** (draft, ours): **CI green on the head** — `c-tests-asan (clang)`
  3m07s and `c-tests-asan (gcc)` 3m14s, both starting 17:53:52Z, plus every
  `sanitize (*)` leg — so the added gcc leg costs one runner for three minutes
  (20 is the timeout, not the runtime) and the newly applied
  `-fno-sanitize-recover=undefined` surfaced nothing.  The two sanitized CI legs are not the same compiler,
  flags or scope — `c-tests-asan` is clang-only with `-fno-sanitize-recover=undefined`
  over the unit tests, `sanitize.yml` is gcc (image default) without it over the
  runtimes — so this makes the C core a `cc: [clang, gcc]` matrix with one flag set
  and names the compiler in the runtime leg.  Measured for the PR: gcc 15.3.0 and
  16.2.0 **reject** `-fsanitize=memory` (MSan is clang-only, so a gcc/clang parity
  matrix can only be ASan+UBSan+LSan+TSan); `-fsanitize=hwaddress` builds on both
  but aborts on x86_64 for want of a tagged-address ABI (aarch64-only); TSan under
  gcc aborts on ASLR entropy inside a container; and gcc 15/16 now define
  `__has_feature`, which is why #693's `defined(__clang__) && defined(__has_feature)`
  guard matters.
* **Issue #701** (ours): `tools/perf/layout-check.sh` compares the two
  `NXT_MMAP_TINY_CHUNK` arms for the `const` macros but only one build for the 16
  `shm` structs.  #693 itself adds no layout arm.
* **#693** is the Claude session's to measure (claimed the alpine box for 120 min);
  my arm64 loop there is stopped and the validator treats that box as "not ours".


## Upstream CI work in flight (2026-10-13, evening)

* **PR #700** (`ci/sanitizer-parity`) — **squashed by the maintainer to `f871edc5`** with an
  identical tree to my `2e1f071d`; ready for review, not a draft, and green:
  `c-tests-asan (clang)` 3m07s, `c-tests-asan (gcc)` 2m16s, `sanitize (go)` pass.
  It does two things: `c-tests-asan` becomes a `cc: [clang, gcc]` matrix with one flag set,
  and `sanitize.yml` names `--cc=gcc`.  **It deliberately does not share
  `-fno-sanitize-recover=undefined` with the runtime leg** — the Codex review caught that this
  makes the leg's allowlist inert (the gate at `.github/workflows/sanitize.yml:411` reads
  reports as a post-hoc scan), and that is the same reason the file already refuses to set
  `halt_on_error`; I confirmed it and fixed it in `2e1f071d`, replying in the review thread.
  Measured while writing it: gcc 15.3.0 and 16.2.0 **reject** `-fsanitize=memory` (MSan is
  clang-only), `-fsanitize=hwaddress` builds on both but aborts on x86_64 (tagged-address ABI,
  aarch64-only), gcc TSan aborts on ASLR entropy inside a container, and gcc 15/16 now define
  `__has_feature` (so `defined(__clang__) && defined(__has_feature)` in #693 is load-bearing).
* **Issue #701** — `layout-check.sh` compares both `NXT_MMAP_TINY_CHUNK` arms for the `const`
  macros but reads the 16 `shm` structs from a single build.  Implementation is **in flight** in
  `/tmp/freeunit-exp` on branch `ci/layout-check-both-arms` (**not pushed**), two commits:
  `f8fe121d` (the real change) and `6021d2d1` (**test-only**, must be dropped).  The change:
  `build COMMIT DIR [CC_OPT]` takes an extra `--cc-opt` and the tiny arm skips the const program
  (which self-compiles both arms in one directory); four builds at the end, base/head x
  default/tiny; `layout()` loops the two arms, tags rows `## <arm> <file>` and does the
  unitd-vs-nxt_unit.o MISMATCH check per arm.  Untracked `tools/perf/layout-check-old.sh` is a
  scratch copy of the old script — delete it.  Still to do: update the "about 40 s" note in
  `.github/workflows/layout-check.yml`, finish the local proof (see below), push, open the PR.
  Local proof state: all four builds compile in a `debian:trixie` container (pahole installed),
  but **pahole 1.30 there exits non-zero when the ELF carries no BTF** — it prints
  `libbpf: failed to find '.BTF'` plus `Invalid argument` although the DWARF dump is correct —
  so the stock script dies under `set -e` and a lenient wrapper was needed; the old-vs-new
  comparison run was then cut short, so the "old passes / new fails on a tiny-arm-only struct
  change" proof is **not finished**.  A synthetic commit is ready for it: `6021d2d1` adds a
  `#ifdef NXT_MMAP_TINY_CHUNK` field to `nxt_port_queue_item_t` in `src/nxt_port_queue.h`.
* **#693** belongs to the Claude session (it claimed the alpine box for 120 min for exactly that
  benchmark); my arm64 loop there is stopped, the validator treats `o-build` as `n/a`, and I
  installed the missing `oha 1.16.0` at the path the harness expects.

## Queues as of 2026-10-13T20:00Z

`pro4s-2` tmux `matrix` (9 jobs: the mysqli/pgsql/sqlite blocks 66-74; the bisect is complete
and published — #638 is the whole win, #670 flat), `pro4s-4` tmux `wp` (3 left of the WordPress
set), `o-build` not ours.  The five-minute validator's session name for pro4s-2 changed from
`ws-loop` to `matrix`; it reports no problems.  The earlier loop exited by design after 12
passes with 9 jobs left, which is why the queue looked dead.


### The Apache arms (requested 2026-10-13), and a trap that ate two live logs

Jobs **76/77/78** (WordPress and Drupal 12 front-anon, FreeUnit and nginx+FPM against
mod_php) and **86/87** (the same with `freeunit-master`) run on pro4s-2, chained after the
matrix by `/tmp/matrix-loop.sh` in tmux `bench`; **83/84/85/88/89** are the A1 equivalents
(`PERF=0`, `PRIMARY=server_us`, one core each) in tmux `apachearm` on o-build, whose image
build is chained apache -> `freeunit-master` at `2dc6596f` and writes `run/freeunit-master-sha`.

Trap worth remembering: **`make sync` uses `rsync --delete`, so a log or script living in the
repository root on the box is deleted while its process keeps writing to the unlinked inode**.
That is why `bench-loop.log` and `apache-arm-loop.log` did not exist while their loops ran.
Loop logs now live under `run/` (excluded from rsync) and the loop scripts in `/tmp`.

Also fixed here: `bench/cells.sh` `start_db()` created the **A** network through the global
`$NET` whatever side it was starting, so every two-side (SPLIT) job died with
`network dbnet-<pid>-b not found` before its database came up.  That is why jobs 66-70 failed
and why the older database-axis jobs 35-41 were never publishable.  It now creates the
network of the side it is starting.


### WordPress workloads that do real core work (2026-10-13)

The front page is I/O-bound and similar across runtimes, so it is a weak instrument for
"is FreeUnit faster for WordPress itself".  Twelve jobs (**90-101**) add the three
suggested workloads — `wp-rest-posts` (`/wp-json/wp/v2/posts?per_page=10`), `wp-edit`
(`/wp-admin/post.php?post=<id>&action=edit`) and `wp-edit-list` (`/wp-admin/edit.php`) —
each against mod_php and nginx+PHP-FPM, with 1.37.0 and with master.  The site build now
seeds a post of known id, mints a session cookie the way a browser does (test cookie, then
the login POST) and writes an application password to the site directory for a future
authenticated REST cell — deliberately **not** in `meta.txt`, which is published with every
run.  `site_installed()` requires the cookie and the post id, so a site that predates a
workload rebuilds instead of being skipped; **and the `site:wp`/`site:wp-persistent` lines
had to be cleared from pro4s-4's `campaign.done`**, because the campaign's done-file skip
outranks the builder's own check — the same trap as the Drupal 12 site earlier.

Queues at 2026-10-13T20:55Z: pro4s-2 running the matrix then the Apache arms
(remaining 14); pro4s-4 the WordPress front set then the core-workload set (14, and it
rebuilds both WP sites on its next pass); o-build the ARM Apache set (5) once the master
image finishes.  A1's main image finished; `freeunit-master` was building.

Mistakes made and fixed in this stretch, for the record:

* an `rsync --delete` invoked from the wrong working directory (the FreeUnit tree) overwrote
  pro4s-4's benchmark tree; `run/` and `.git` were excluded so no results, sites or history
  were lost, and the tree was restored from the correct directory (16 steps files, `run/`
  intact at 52 entries).
* a remote `pkill -f wp-loop.sh` killed its own ssh session, because the session's command
  line contains that string; restarts now run from a helper script file.
* the validator's stall check watched the campaign job log, which only advances when a job
  starts, instead of the newest run's `cells.log`; that is what made a healthy 19-minute job
  look stalled.  It now uses `cells.log` with a 15-minute threshold.


### Two more traps, and two careless actions of mine (2026-10-13, late)

* A killed job leaves children that inherited the `run/.run.lock` file descriptor — an
  `oha` process was still holding it — so every retry exits "another bench/run.sh holds the
  lock" with rc=1/2 and the queue churns.  Find the holders by reading `/proc/[0-9]*/fd/9`,
  kill those, and only then let the loop retry.  `fuser` is not installed on those boxes.
* **Do not run `docker rm -f $(docker ps -q)`**: I did, to clear a stuck job, and it also
  removed containers that were not mine.  The filter used everywhere else in this suite —
  `grep -E '^(rt|db-bench|perf)-|db-wp'` — is there for exactly that reason.
* Also mine, earlier in the same stretch: an `rsync --delete` run from the wrong working
  directory (the FreeUnit tree instead of the benchmark tree) overwrote pro4s-4's checkout.
  `run/` and `.git` were excluded, so no results, sites or history were lost, and the tree was
  restored from the correct directory.  Always `cd` explicitly before a sync.

## Traps that cost the most

* `vendor/bin/dr install` cannot install into a database (early return on any `$databases`,
  SQLite otherwise); use `install_drupal()` with the driver spec.
* Drupal 12's `standard` profile installs no content model at all; the arm was dropped.
* `composer dump-autoload --classmap-authoritative` breaks Drupal 12 (runtime module
  namespaces); `--optimize` alone is safe.
* `docker run | grep -q` under `set -o pipefail` fails with 141 when grep stops early.
* Never `pkill -f` a pattern that matches the command you are running.
* A stale `unitd` on the test port answers your curl with the **old** module; kill by pid
  and use a fresh port when verifying a rebuilt module.
* **Never run several `Py_InitializeFromConfig` variants in one process**: CPython caches
  the path configuration, so every row after the first reports the first variant's prefix.
  This contaminated a whole measurement table here (see PR #680's comments).

## Next steps

1. Let the profile jobs finish, then `scripts/collect-commit.sh pro4s-2` (run it **locally** —
   it calls `collect.sh`, which rsyncs from the host; running it on the box commits in a
   copy that is not a git repository) and confirm `meta.txt` names both master shas.
2. Collect the WP runs with `COLLECT_ONLY` and the matrix runs when the loops
   finish, then confirm each `meta.txt` names the runtime versions.
3. **PR #680** needs the shape decision (pin the interpreter *and* the isolation/`sys.path`
   side together, make it opt-in, or document the limitation); **#33** is verified and only
   needs a review.
4. Watch the exp queue (the watcher logs it) and take the profiling-shaped items: the RPS/p95
   half of #22 on the perf box, then #32/#34.
5. Then: Drupal 12 cron arms, the mysqli worker-mode question (issue 596), the Alpine/musl
   image, `benchmarks-drupal` naming now that WordPress lives there, and the real-NIC A/B for
   the static-`sendfile` change (#32) and kTLS (#34).
