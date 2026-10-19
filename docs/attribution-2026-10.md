# Are the measured differences caused by the merged PRs?

Measured 2026-10-18/19. Method: every runtime image is built from a **named commit**, and
every comparison is a paired null+A/B cell (null band, 95 % CI, 3-of-4 slot agreement).
A merge can only show in a cell if it touches code that cell executes, so the question
splits into "which merges touch the request path" and "does a paired cell isolate them".

## Runtime-affecting merges since 1.37.0

| PR | merge | files | request path | cells that exercise it | isolated? |
|---|---|---|---|---|---|
| 705 | `c70bdbd11` (14 Oct) | `nxt_http*`, `nxt_port.h`, `nxt_unit_field.h` | packs the request structures, pins shm layouts | **every** cell | no |
| 708 | `4d6eceeae` (15 Oct) | `nxt_app_nncq.h`, `nxt_router.c` | router queue starvation fix | **every** cell | no |
| 730 | `7c54e301e` (16 Oct) | `nxt_atomic.h`, `nxt_router.c/.h` | accounting counters atomics, skip unlink lock | **every** cell | no |
| 714 | `bcb8a1a35` (15 Oct) | `nxt_app_queue.h`, `nxt_router.c`, `nxt_unit.c` | USDT probe site (inert unless enabled) | every cell | no |
| 706/707/709/735/704/751 | `1edda3a07` … `c7aebd899` | `nxt_php_sapi.c` | PHP script open/access/stat, content type | PHP cells | 751 only (153) |
| 736/742/749 | `df8b9ccb0`, `1f7511a39`, `b3c5da388` | atomics, thread, `nxt_port_socket.c`, `nxt_mp.c` | port and thread paths | every cell | **yes** (128/129/130) |
| 752 | `10e1a9bec` | `nxt_app_queue.h`, `nxt_conn*`, `nxt_router*` | engine counters, shm chunk maps | every cell | **yes** (130/131/132) |
| 768 | `76f89e222` | `nxt_socket_msg.h` | cmsg walk on every port message | every cell | **yes** (125/126, micro: +2 instr/walk) |
| 720 | `9dcddabc0` | http compression | responses with `Accept-Encoding` | **none** — the suite sends no compression | n/a |

## What the measurements say

1. **Master is flat against the release.** `1.37.0 → b532b9d` (today's tip, 7 commits):
   hello **−1.15 %** [−2.17, −0.12] (NO CLAIM, band 1.64), cached Drupal 12 front **+0.1 %**,
   front-auth **+0.1 %**, WordPress **−1.3 %**, Symfony and Drupal 11.4 the same shape.
   Seven merges changed nothing measurable on the application cells.
2. **The one real cost that ever appeared was pre-sweep**: `1.37.0 → ff694772` measured
   **+3.09 %** on hello [1.68, 4.50] (11/12, CLAIM). That range carries 705, 708 and 730,
   which are the only unmeasured-in-isolation merges that touch every request. The atomic
   sweep then measured −0.0 %, **#752 −2.45 %** [−4.33, −0.57], and the net to today is
   −1.15 % (NO CLAIM) — so whatever those three cost, the later work gave it back.
3. **The auth-vs-FPM worker deficit is not a merged PR.** `169`: the **release** itself,
   against nginx+FPM on the authenticated page, with the split — `front_us 304 vs 449 µs`
   in our favour (+47.8 %), `worker_us 28 094 vs 26 752 µs` **against us (−4.78 %, 12/12)**,
   `server_us` −4.22 %. Master at `10e1a9bec`/`b532b9d` measures the same −4.5…−5.5 %.
   The shipped 1.37.0 tarball has the gap; nothing merged since October created it.
4. **The gap is not transport and not generic PHP work.** The body sweep (154–156) shows
   Unit's worker 14→52 % *cheaper* than php-fpm's as the body grows, and the PHP-work sweep
   (157–159) shows the same per-iteration cost (14.55 vs 14.90 ns) and a cheaper fixed
   per-request cost (138 vs 147 µs). What Unit's worker does *more expensively* is specific
   to a framework render, not to PHP execution in general.

## Open

- Per-PR isolation of **705, 708, 730 and 714** was never run; a four-step hello+auth ladder
  (parent → commit) would say whether any of them carries a cost on its own. That is the
  only remaining "did a merge cost us something" question.
- The worker profile: the recordings now exist (`run/144-…/perf.rec.A|B`, 87 and 100 MB) but
  the symbols do not resolve, because perf records from a sibling container and cannot read
  another container's overlay through `/proc/<pid>/root`. Recording from inside the runtime
  image is the fix and is the last step to name the functions behind the ~1 ms per request.
