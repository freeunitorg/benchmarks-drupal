# What master costs against 1.37.0, and what the atomic work did to it

Measured 2026-10-18 on pro4s-4 (x86, `s_instructions` per request) and o-build
(aarch64, `server_us` per request, no PMU). Every cell is a paired null+A/B run:
the null phase gives the band, the ab phase gives the delta, and a CLAIM needs the
delta outside the band, a 95 % CI excluding 0 and 3 of 4 adjacent slot pairs
agreeing. Images are built from a named commit, never from a moving tag.

## The ladder: hello, server-only

hello is the right instrument for a server-layer question: about 216 000
instructions per request, so 1 % is 2 200 instructions. Each step is its own pair.

| job | A → B | Δ `s_instructions` | 95 % CI | band | agreement | verdict |
|---|---|---|---|---|---|---|
| 128 | `1.37.0` → `ff694772` | **+3.09 %** | [+1.68, +4.50] | 2.30 | 11/12 | **CLAIM**: master was 3 % above the release before the atomic work |
| 129 | `ff694772` → `33896f7e` (sweep #736/#741/#742/#749) | −0.0 % | [−2.9, +2.9] | 2.93 | 6/12 | NO CLAIM |
| 130 | `33896f7e` → `10e1a9bec` (#752, counters and shm maps atomic) | **−2.45 %** | [−4.33, −0.57] | 4.00 | 9/12 | NO CLAIM (band), direction cheaper |
| 131 | `1.37.0` → `10e1a9bec` (the net) | **−0.2 %** | [−3.2, +2.8] | 3.04 | 5/12 | NO CLAIM |
| 124 | `1.37.0` → `33896f7e` | +1.1 % | [−0.31, +2.56] | 3.71 | 8/12 | NO CLAIM |

Reading: the post-release cost is real (**+3.1 % at `ff694772`**, 11/12, outside the
band) and it predates the atomic sweep. The sweep and #752 recover it to the point
where the release and today's master are indistinguishable (−0.2 % with a ±3 % band).
The atomics are **not** the regression; #752 alone measured cheaper on hello.

Drupal cells agree within their resolution: 118 front-anon `1.37.0 → 33896f7e`
+0.16 % (pro4s-4, NO CLAIM) and +0.22 % (pro4s-2, band edge); 121 front-auth +0.03 %
(band 0.03, NO CLAIM); 132 #752 on the front page **+0.10 %** (band 0.2, NO CLAIM).

Not concluded: the sweep's own step has a 2.9 % band and six of twelve cells
agreeing, so "−0.0 %" is not a measurement of zero, only the absence of a claim in a
±3 % window. A quieter box or more reps would tighten it.

## PR #768: what a correctness fix costs

`NXT_CMSG_NXTHDR()` on glibc now does the 2.37 bounds check itself with `nxt_span_t`
instead of calling libc. The walk runs **per received port message**, not per
request: `SO_PASSCRED` is set on both ends of every port socketpair, so each message
carries at least one control header.

Micro-benchmark compiled against each tree's own header (gcc 13.3, -O2), two
`SCM_RIGHTS` headers, `perf stat -e instructions:u`:

| iterations | base `10e1a9bec` | head `791d2d3dc` | Δ per call |
|---|---|---|---|
| 0 | 115 669 | 115 669 | — |
| 1 000 000 (2 M calls) | 13 115 863 | 17 115 865 | +2.000001 |
| 10 000 000 (20 M calls) | 130 115 912 | 170 115 909 | +2.000000 |

**+2 instructions per control-message walk**, deterministic. Per request that is
8–24 instructions, 0.004–0.011 % of hello. The paired cells agree: 125 hello
+0.17 % (band 1.18, NO CLAIM), 126 front page −0.02 % (band 0.23, NO CLAIM).

## ARM: the front page is ahead of FPM, it just had no FPM row

The arm64 page compared the front page with mod_php only, and its master row was the
stale `:master` pin `2dc6596f5` (2026-10-14). Three cells fill that in (server_us
primary, 8/8 cells agreeing, band 1.5–4.7):

| job | cell | FreeUnit | nginx + PHP-FPM | verdict |
|---|---|---|---|---|
| 134 | hello, master `10e1a9bec` | 152.5 µs | 213.5 µs | **FPM +40.1 %** (rps 6 467 vs 4 652) |
| 135 | front page, master | 2 579 µs | 2 780 µs | **FPM +7.8 %** (rps 385 vs 355) |
| 136 | front page, 1.37.0 | 2 565 µs | 2 758 µs | **FPM +7.6 %** |

ARM ranking: master 2 573–2 579 ≈ release 2 576 → nginx+FPM 2 756 (1.07x) →
Apache 3 566 (1.39x). Ratios are comparable with the x86 pages; absolute numbers
are not.

## Two harness bugs this set exposed

Both silenced whole runs and are fixed:

- **`WP_POST_ID=$(awk … site/<site>/meta.txt)`** — hello has no `meta.txt`, awk
  exits 2, and `set -e` ended the run right after the idle gate: exit 2, an empty run
  directory and nothing in the log. Fixed in the x86 tree (`e718b35`) and in the ARM
  tree.
- **ARM `RUNROOT`** defaulted to the x86 path `/data/projects/benchmarks-drupal/run`,
  so ARM runs wrote to the wrong tree. The ARM driver now exports
  `RUNROOT=/home/alpine/bench-arm/run`.

`cells.sh` in all four trees now puts its scratch under `$RESROOT/tmp` (on the data
disk) and removes it when the cells succeed. Before, every job left a
`/tmp/drupal-bench.*` directory on the 40 GB root: 255 stale ones on pro4s-2, 146 on
o-build, and a 27.5 GB perf recording in `/tmp` filled `/` on pro4s-4 and broke
docker builds and the idle gate for hours.

## Update 2026-10-19: the tip is now faster than the release

Master moved 95 commits (`b532b9d` → `13effad40`): perf(php) send-the-header-with-first-output,
perf(libunit) small-header buffer, the libunit wake-up/quit/non-blocking fixes, router queue
coalescing, h1p and the controller PUT/DELETE ordering.

| cell | A → B | Δ | 95 % CI | band | agree | verdict |
|---|---|---|---|---|---|---|
| 171 hello | `b532b9d` → `13effad40` | −1.06 % | [−2.32, +0.19] | 1.43 | 9/12 | NO CLAIM |
| 172 cached front | `b532b9d` → `13effad40` | −0.04 % | [−0.21, +0.12] | 0.19 | 5/12 | NO CLAIM |
| 173 auth, split | `b532b9d` → `13effad40` | −0.03 % instr, worker_us −2.06 % | [−6.31, +2.20] | 3.40 | 8/12 | NO CLAIM |
| **175 hello** | **`1.37.0` → `13effad40`** | **−3.10 %** | **[−4.91, −1.29]** | 2.33 | 11/12 | **CLAIM** |
| 176 cached front | `1.37.0` → `13effad40` | −0.06 % | [−0.19, +0.07] | 0.27 | 7/12 | NO CLAIM |

No regression from the 95 merges on any path measured. And the release-vs-master series on the
server-only cell has now crossed zero:

| master | Δ instructions vs 1.37.0 | verdict |
|---|---|---|
| `ff694772` (17 Oct) | **+3.09 %** | CLAIM — master slower than the release |
| `10e1a9bec` | −0.2 % | NO CLAIM |
| `b532b9d` | −1.15 % | NO CLAIM |
| **`13effad40` (19 Oct)** | **−3.10 %** | **CLAIM — master faster than the release** |

The server-only path is now measurably cheaper than the 1.37.0 tarball; the cached front page
is level (176: −0.06 %), so the gain is in the request/worker plumbing, not in the framework
path.
