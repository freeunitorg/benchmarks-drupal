# Hot-path machine-code audit: FreeUnit vs nginx-fpm (2026-10)

Status: **draft — local exploratory evidence only; claim-grade numbers pending on
pro4s-2** (jobs 01/16i/16/34 queued in tmux `hotpath-audit`, then 16r with
PERF_RECORD). Nothing in section 1-3 is a published result.

Primary metric (unchanged): retired instructions per request (`s_instructions`),
headline workload `drupal-front` (Drupal 11.4 page-cache hit, c=32).

## 1. Baseline (claim-grade, reproduced on pro4s-2, 2026-10-15)

Published direction confirmed and sharpened: on drupal-front c32 (Drupal 11.4),
**FreeUnit master spends fewer server instructions per request than nginx+PHP-FPM**
— job 16 rerun on master (run
16-front-anon-master-vs-fpm-11.4-sd-91675-20261015T211042Z): A (freeunit-master)
4,708,061 vs B (nginx-fpm) 5,097,075 s_instructions per request, **B is +8.26%
[95% CI +8.14, +8.38], 12/12 cells agree, null band 0.18%** (job 01 null gate
PASS at ±0.1%). FreeUnit also leads rps (+7.4%), server_us (−7.2%),
s_cycles (−2.5%). The audit's goal is therefore not catching up but **widening
the margin**: fewer instructions per request on the same workload.

## 2. Local exploratory evidence (laptop, hello PHP, c=32 — ranks candidates only)

Build: harness `src` at origin/master 7580e820d, default flags (see 3.2).
Router pinned to 2 cores, 4 php workers, `oha -c 32`, `perf stat/record` on the
router and worker pid sets. Raw data: harness `run/phpprof/`.

1. **The router is front-end starved.** ~54.5k instructions/request (router) +
   ~66k (workers) for `<?php echo "hello";`. Router IPC 0.39, workers 0.46;
   `ic_fetch_stall.ic_stall_any` ≈ 60% of cycles on both sides;
   `l2_cache_accesses_from_ic_misses` ≈ 6.4k (router) / 7.0k (workers) per
   request. iTLB misses are small (29/93 per request).
2. **The user-space hot set is 67 KB.** 153 router functions ≥0.02% self-time
   cover 19.6% of router samples; aggregate text 67,157 B against a 32 KB L1I,
   before counting the kernel's own footprint (40.6% of router samples) — the
   per-request working set overflows L1I, matching the stall counts.
3. **Kernel share is 40.6% (router) / 33.8% (php workers)** of samples — shm/port
   messaging, event wakeups, scheduling. Local kernel symbols were unresolvable
   (kptr_restrict); syscall-level attribution is what job 16r is for.
4. **Run-to-run spread ~0.4%** for instructions between two 20 s runs.

## 3. Machine-code audit

### 3.1 Function sizes on the hot path (-O1, local build)

| function | size (B) | self % |
|---|---|---|
| nxt_router_process_http_request | 5,244 | 1.44 |
| nxt_router_response_ready_handler | 4,449 | 0.54 |
| nxt_port_queue_read_handler | 2,642 | 0.65 |
| nxt_port_read_msg_process | 2,315 | 0.27 |
| nxt_http_parse_request_line | 2,236 | 0.14 |
| nxt_port_socket_write2 | 2,161 | — |
| nxt_h1p_request_header_send | 2,118 | 0.56 |
| nxt_port_write_msgs | 1,893 | — |
| nxt_http_request_header_send | 1,362 | 0.16 |

unitd total .text: 407,550 B / 1,563 functions.

### 3.2 Build-flag reality

- unitd ships **-O1** (`src/auto/cc/test:74`; -O2 commented out over
  strict-aliasing concerns that `NXT_CFLAGS` already guards with
  `-fno-strict-aliasing -fno-strict-overflow`). Benchmark images build with
  defaults → all published numbers are -O1.
- nginx in `drupal-bench-fpm:8.5` builds **-g -O2**; total .text 344,115 B /
  750 funcs — nginx's whole server is smaller than unitd's total, and unitd's
  hot set alone (67 KB) exceeds a 32 KB L1I.
- Runtime A image (`drupal-bench-freeunit:master`, cc94deb2): default flags,
  .text 388,050 B / 1,577 funcs.

### 3.3 Flag variants, same tree (local; see 2 for method)

| variant | total .text | hot set | hot funcs |
|---|---|---|---|
| -O1 (default) | 407,550 | 67,157 | 153 |
| -O2 | 433,029 | 71,452 | 145 |
| -O3 | 521,075 | 82,614 | 139 |
| -Os | 332,892 | 52,150 | 151 |
| -O2 + fat LTO | 495,161 | 50,431 | 93 |

-Os and LTO shrink the hot set ~22-25%; -O2/-O3 grow it. A sequential laptop
smoke was thermally confounded and is discarded as evidence. The headroom must be
measured on the perf box (harness jobs 07-13 pattern extended to drupal-front).

## 4. Ranked optimization candidates (pre-attribution)

- **C1. Build unitd with -O2 (or -O2+flto).** Hot-set −25% with LTO; fewer
  executed instructions measured on workers in the (confounded) smoke. Verify:
  perf-lab hello/capp A/B, then a drupal-front job with a branch-built image.
  Risk: strict-aliasing history (guarded), binary size, build-time cost of LTO.
- **C2. Source-level cold/hot split** in nxt_router_process_http_request and
  nxt_router_response_ready_handler (move error/exception branches to noinline
  cold helpers); composes with C1. Effect small alone; measure via 16r records
  (which basic blocks the samples actually hit).
- **C3. Kernel-path work** (40% of router samples): fewer shm/port wakeups,
  message batching — must be ranked by the 16r syscall/kernel-stack attribution
  before picking a target. Candidate hooks already exist: #668/#669 follow-ups,
  k2-response-piggyback-sizing.
- **C4. -Os**: smallest hot set, but needs the nxt_http_static.c
  `range_start`/`range_end` maybe-uninitialized fix (-Werror at -Os) and may cost
  more instructions than -O2. Only if C1 shows the icache story dominates.
- **C5. nxt_http_static.c range init fix**: correctness-adjacent enabler for
  -Os; trivial.

## 5. Perf-box status and pending (phase 2 running in tmux `hotpath-p2`)

Done and pulled to harness `run/phpprof/box/`:
- 01 null gate PASS (band 0.1-0.2%) — the box resolves <1% deltas today.
- 16 master-vs-fpm: **CLAIM, FreeUnit ahead by 8.26% s_instructions** (above).
- 16i with icache PMU events: CLAIM confirmed (8.23%), but `perf_parse` dropped
  the icache/iTLB rows; the parse is fixed and 16i is re-queued.
- 34 hello-master-vs-fpm: not yet run (gate).

In flight (script `run/hotpath-p2.log` on the box): 16r (PERF_RECORD
attribution) → docker build master-o2 / master-lto images (Dockerfile `CC_OPT`
build-arg, default empty = unchanged) → jobs 40 (-O2 vs -O, within-commit A/B),
41 (-O2+fat-LTO vs -O), 34, 16i-rerun. Each bench step re-passes the idle gate.

Local code state: C5 fix (nxt_http_static.c range init, -Os-clean) sits
uncommitted in worktree `/home/andy/www/unit/.kimi-hotpath` (branch
`perf/hotpath-audit`, -Os and default builds clean, check-style OK). C1 (the
-O2/LTO decision) is deliberately **not** a source change yet: jobs 40/41 measure
the effect at drupal level first; landing a default-flag change is a maintainer
call on top of those numbers.
