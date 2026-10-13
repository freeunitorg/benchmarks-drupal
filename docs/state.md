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

## Running now: the master regression and the master profile (pro4s-2)

The Drupal 12 regression check is **done and published**: `06-front-anon` and
`07-front-auth` (master vs the pinned 1.37.0) both came back NO CLAIM, so the
post-release work has no effect on a page-cache-hit cell.  The master image was
pinned at **`868ccc29`** until 2026-10-12, so every earlier "master" number came
from that commit; the two new runs name **`8492d5ee`** in `meta.txt`.

Master has since moved to **`2dc6596f`**, and the three commits between the two
pins are all on the response path: `dc30c8a7` compresses the body part sent with
the response headers, `2dc6596f` sends the response through the port queue again
(+531 lines in `src/nxt_unit.c`), `183c84d5` is CI only.  `scripts/campaign.steps.master-profile`
runs `freeunit-master` against `freeunit-master-old` (the same runtime
configuration at `8492d5ee`) on a bare PHP response (`50`), a large body (`51`)
and the Drupal 12 anonymous front page (`52`) — a within-run A/B, so the null
band is those commits alone rather than cross-run noise.  Waiter in tmux
`drupal-profile`, deadline 08:00Z; `build-images.sh` builds both tags and writes
`run/freeunit-master-sha` and `run/freeunit-master-old-sha`.

Traps from setting this up:

* the campaign only understands `site:`/`job:`/`ticks:` lines; a bare job name is
  `unknown step` rc=99.  A failed step is not recorded as done, so the retry is free.
* the 12.0 site and its volume were removed for a fresh install, but
  **`campaign.done` still held `site:12.0 exit=0`**, so the step was skipped and both
  jobs failed with "no installed site".  Delete the step's `exit=0` line to re-run it.
* real time jumped ~17.5 h between sessions (2026-10-13T01:47Z when the notes said
  08:15Z of the 12th); a `DEADLINE_UTC` written earlier is in the past and the waiter
  stops before the first step.
* `pro4s-4` is stopped (its WordPress job stalled at ~1.5 h/cell); nothing of ours runs there.

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
* **#22** (isolation + cgroup v2, a research task held until 1.37.1): I contributed the live
  half of its "ncpu derivation" measurement without claiming the task — on the aarch64
  cgroup-v2 host a hand-made `cpu.max=100000 100000` makes unitd log `the cgroup CPU limit
  lowers the CPU count from 2 to 1`, while a *cpuset* restriction keeps ncpu 2; a quota on
  an ancestor is honoured because the walk takes the minimum non-zero `cpu.max` up the tree.
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
2. **PR #680** needs the shape decision (pin the interpreter *and* the isolation/`sys.path`
   side together, make it opt-in, or document the limitation); **#33** is verified and only
   needs a review.
3. Watch the exp queue (the watcher logs it) and take the profiling-shaped items: the RPS/p95
   half of #22 on the perf box, then #32/#34.
4. Then: Drupal 12 cron arms, the mysqli worker-mode question (issue 596), the Alpine/musl
   image, `benchmarks-drupal` naming now that WordPress lives there, and the real-NIC A/B for
   the static-`sendfile` change (#32) and kTLS (#34).
