# Current state (resume here)

Last updated 2026-10-12 ~08:15Z. A fresh session needs three things: this file,
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

## Running now: the master regression check (pro4s-2)

`scripts/campaign.steps.master-12`: fresh `site:12.0`, then
`06-front-anon-master-vs-1370-12.0` and `07-front-auth-master-vs-1370-12.0` — master
against the pinned 1.37.0 tarball on Drupal 12. Waiter in tmux `drupal-wait`, deadline
12:00Z.

Facts and traps from setting it up:

* the master image had been pinned at **`868ccc29`**, so every published "master" number
  was stale; it is now built at **`8492d5ee`** (`FREEUNIT_MASTER_REF`, `org.freeunit.ref`).
* `build-images.sh` now writes `run/freeunit-master-sha`; `run.sh` reads that file, so
  before this change every master run recorded `freeunit_master_sha=unknown`.
* the 12.0 site and its volume were removed for a fresh install, but the campaign's
  **`campaign.done` still held `site:12.0 exit=0`**, so the step was skipped and both jobs
  failed with "no installed site". The entries were deleted; if a step must re-run, delete
  its `exit=0` line from `run/campaign.done` or the builder's `site_installed` check skips it.
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

## Harness

* `freeunitorg/freeunit-harness` **PR #1**: the aarch64 host recipe
  (`skills/freeunit-cross-arch/references/aarch64-host.md` + a References pointer),
  `make doctor` clean, `@codex review` requested, **no review posted yet**.
* `run/servers.md` (private) carries the Oracle aarch64 inventory; the ARM recipe is the
  public skill reference.
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

1. Let the regression jobs finish, then `scripts/collect-commit.sh pro4s-2` (one commit and
   push per run) and confirm `meta.txt` shows `freeunit_master_sha=8492d5ee…`.
2. Decide the #679 shape (pin + isolation/`sys.path` together, opt-in, or docs) and finish
   PR #680; #33 only needs a review.
3. Then: Drupal 12 cron arms, the mysqli worker-mode question (issue 596), the Alpine/musl
   image, `benchmarks-drupal` naming now that WordPress lives there, and the real-NIC A/B for
   the static-`sendfile` change (#32) and kTLS (#34).
