# 1.37.1 performance note — draft from measured cells

Every number below is a published result in this repository: the job number is the
pointer, `results/<job>/compare.txt` holds the row, and `results/<job>/job.txt` holds the
configuration it ran with. Nothing here is summed from micro-benchmarks; a per-path
measurement is only quoted where the path is named.

## Method

- **Primary metric**: `s_instructions` on the x86 hosts (PMU, whole server tree in one
  cgroup) and `server_us` on the aarch64 host (no PMU there). Neither is RPS.
- **Protocol**: a `null` phase first, which gives the cell its own band; then the A/B
  phase, which gives the delta and a 95 % confidence interval. A **claim** needs the delta
  outside the band, a CI excluding zero, and three of four adjacent slot pairs agreeing.
  Anything else is "level", and is written here as level.
- **Threshold**: every cell declares what would falsify it (`FALSIFY=` in the job file).
- Images are named by commit; a tag is never moved.

## The release comparison (shipping commit `e63168bd` against `1.37.0`)

| job | cell | 1.37.0 | `e63168bd` | Δ | 95 % CI | band | agree | verdict |
|---|---|---|---|---|---|---|---|---|
| **210** | hello (framework-free), 4 blocks | 212 990 | 205 065 | **−3.72 %** | [−4.92, −2.52] | 1.61 | **15/16** | **claim, faster** |
| 182 | hello, 3 blocks | 208 900 | 203 585 | −2.51 % | [−4.10, −0.92] | 2.33 | 10/12 | claim, faster |
| 175 | hello, at `13effad40` | 214 346 | 207 698 | **−3.10 %** | [−4.91, −1.29] | 2.33 | 11/12 | claim, faster |
| 190 | Drupal 12 cached front | 4 413 620 | 4 412 843 | −0.02 % | [−0.18, +0.14] | 0.14 | 6/12 | level |
| 176 | same, at `13effad40` | 4 415 755 | 4 412 961 | −0.06 % | [−0.19, +0.07] | 0.27 | 7/12 | level |
| **212** | Drupal 12 authenticated, 4 blocks | 72 441 149 | 72 506 104 | **+0.09 %** | [+0.07, +0.11] | 0.04 | **16/16** | claim, **up** |
| 191 | Drupal 12 authenticated, 3 blocks | 72 430 435 | 72 501 323 | +0.10 % | [+0.07, +0.12] | 0.05 | 12/12 | claim, up |
| 191 | same cell, router time | 293.95 µs | 283.17 µs | **−3.67 %** | [−6.11, −1.23] | 3.33 | 9/12 | claim, faster |
| 191 | same cell, worker time | 28 244.6 µs | 28 186.8 µs | −0.19 % | [−1.36, +0.97] | 1.68 | 7/12 | level |
| **213** | Drupal 11.4 cached front, 4 blocks | 4 727 998 | 4 720 793 | **−0.15 %** | [−0.25, −0.05] | 0.13 | 11/16 | **claim, faster** |
| 193 | Drupal 11.4 cached front, 3 blocks | 4 722 916 | 4 723 459 | +0.01 % | [−0.15, +0.17] | 0.17 | 8/12 | level |
| 192 | WordPress front | 236 068 918 | 234 065 501 | −0.85 % | [−1.97, +0.27] | 1.60 | 8/12 | level |
| **217** | WordPress front, 4 blocks | 233 503 082 | 233 296 014 | −0.09 % | [−0.87, +0.77] | 0.78 | 8/16 | level |
| 211 | Drupal 12 cached front, 4 blocks | 4 409 762 | 4 414 851 | +0.12 % | [+0.00, +0.23] | 0.14 | 9/16 | level |

**What a release note may say.** FreeUnit 1.37.1 is level with 1.37.0 on every framework
cell measured (Drupal 12 cached, Drupal 11.4, WordPress), and cheaper on the framework-free
path — 2.5 % fewer server instructions per request at the shipping commit, 3.1 % at
`13effad40`, two independent jobs agreeing.

**What it must also say.** The authenticated Drupal cell uses 0.10 % *more* instructions
(72 k on 72.4 M, twelve of twelve slots agreeing) while the router side of the same request
is 3.67 % cheaper in time. The worker is unchanged. That is a real, small instruction
increase on that path and it belongs in the note rather than in a footnote.

## Blocker to decide before shipping: the aarch64 side moves the other way

The same pair of commits measured on the aarch64 host is **4.87 % slower** on hello, not
faster: job **220**, 147.19 µs (1.37.0) against 154.34 µs (shipping commit), 95 % CI
[+3.32, +6.42], null band 1.88, **16 of 16 slots agreeing**. On x86 the same comparison is
−3.72 % (job 210, 15/16). Two tight measurements, opposite signs.

**The bisect names the change, and it is not the one the commit title suggests.** Eight measurements on the aarch64 host, all four blocks, all against the same
1.37.0 image:

| job | commit | Δ on hello | 95 % CI | band | agree | verdict |
|---|---|---|---|---|---|---|
| 233 | `#705` `c70bdbd11` | −0.67 % | — | — | — | not the cost |
| 234 | `#730` `7c54e301e` | −1.97 % | [−3.63, −0.30] | 2.63 | 12/16 | NO CLAIM (slightly faster) |
| **235** | **`#736` `df8b9ccb0`** | **+7.30 %** | [+5.43, +9.17] | 0.99 | **16/16** | **CLAIM — the cost enters here** |
| 236 | `#742` `1f7511a39` | (running) | | | | |
| **237** | **`#749` `b3c5da388`** | **+6.59 %** | [+5.09, +8.09] | 1.36 | **16/16** | CLAIM — cost present |
| 224 | `ff694772` | +6.12 % | [+4.36, +7.89] | 1.65 | 15/16 | CLAIM |
| 225 | `10e1a9bec` | +5.38 % | [+3.48, +7.28] | 2.39 | 15/16 | CLAIM |
| 226 | `b532b9d` | +7.79 % | — | — | — | CLAIM |
| 227 | `13effad40` | +4.2 % | — | — | — | CLAIM |
| 220 | `e63168bd` (tip) | **+4.87 %** | [+3.32, +6.42] | 1.88 | 16/16 | CLAIM |

The step is clean: **−1.97 % at `#730` and +7.30 % at `#736`, with 16 of 16 slots at each
end.** Everything after `#736` stays in the +4 … +8 % range, i.e. the cost was introduced
there and never reclaimed on aarch64 — while on x86 the same range cost +3.09 % and the
later work gave most of it back.

The step `7c54e301e..df8b9ccb0` holds **two** commits, not one:

```
5386fa9e8  php: open the script once, nonblocking, and answer 404 or 403 from that open
df8b9ccb0  core: make the remaining mixed atomic and plain accesses atomic     (#736)
```

Job **238** measures its parent on its own:

| job | commit | Δ on hello | 95 % CI | band | agree | verdict |
|---|---|---|---|---|---|---|
| **238** | `5386fa9e8` PHP script-open rework | **+6.79 %** | [+5.00, +8.57] | 1.67 | **16/16** | **CLAIM — the cost is here** |
| 235 | `df8b9ccb0` (+ `#736` atomics) | +7.30 % | [+5.43, +9.17] | 0.99 | 16/16 | CLAIM |

So the aarch64 cost is the **PHP worker's script-open rework**, and the atomics commit adds
nothing measurable on top of it (the two agree inside each other's intervals). The rework
replaced `access()` plus PHP's own open with a single nonblocking open followed by an
`fstat` that classifies the opened object, so a FIFO cannot park the worker and 404/403 are
answered from the open itself; that is a correctness change for a security-relevant case,
not something to revert.

**What 1.37.1 should say, and what it should do next.** The note must not claim an
across-the-board improvement: the release is 3.7 % faster on x86 hello and **6.8 % slower on
aarch64 hello**, and the cause is named. The follow-up is a 1.38 task, not a patch-release
revert: keep the correctness and remove the cost — the opened stream is already in hand, so
the open should not be repeated further down PHP's path, and opcache's `enable_file_override`
must stay effective for the main script (this is the same area as the fixed-script hand-off
measured in jobs 186-189/183-185).

## A stability fix that is not a performance number

`1.37.0` logs `get_port_handler: port N:M not found` and fails a cell loudly enough to
make it unpublishable: **13 of its 52 measured cells (25 %)** across six pinned commits,
against **0 of 92** master cells. Any 1.37.0-vs-master cell can therefore come back INVALID
for a reason that has nothing to do with the code under test.

## Where FreeUnit stands against the classic stacks (x86, shipping commit)

| job | cell | FreeUnit | comparison | relative |
|---|---|---|---|---|
| 179 | hello | 205 919 | nginx + PHP-FPM | **+114.4 %** instructions (12/12) |
| 180 | 20 headers, 2 cookies | 258 693 | nginx + PHP-FPM | **+98.2 %** (12/12) |
| 181 | 64 KiB body | 337 697 | nginx + PHP-FPM | **+143.4 %** (12/12) |
| 199 | 1 KiB body | 337 352 | nginx + PHP-FPM | **+144.6 %** (12/12) |
| 219 | Drupal 12 cached front | 4 408 146 | Apache + mod_php | **+75.7 %** (16/16) |
| 218 | WordPress front | 231 425 567 | nginx + PHP-FPM | −1.31 % (band 2.37) → **level** |
| 191 | Drupal 12 authenticated | — | nginx + PHP-FPM | FreeUnit still costs more, see `docs/attribution-2026-10.md` |

The per-byte trend is monotone: FPM costs ~2.1× at a 1 KiB body and ~2.4× at 64 KiB. The
WordPress row is the exception worth knowing: on that workload FPM is level with FreeUnit.

## Measured, and deliberately not in this release

- **PR 781 (fixed-script OPcache hand-off, draft POC)**: aarch64 hello **−4.74 %** server
  CPU (claim, band 3.65), headers **−4.15 %** (claim, band 2.27), body −1.8 % (level);
  x86 hello −2.65 % against a 3.58 % band (not claimable there). Same direction on both
  architectures, real on the host where the band is narrow. It is a draft and is not
  merged; this note records the measurement, not a promise.
- **PR 705 (request struct packing)**: hello +0.45 % (band 2.39), Drupal front +0.06 %
  (band 0.19) → free on both paths. 1 592 → 1 576 bytes buys no measurable CPU.

## Null results worth not re-litigating

- **musl vs glibc at the shipping commit** (200, 201, and 222 at four blocks: −0.23 %
  in a 1.28 % band): hello −0.98 %, Drupal front −1.85 %, all inside the noise; page faults 1.51/req (glibc) against 0.74/req (musl) and
  17 % smaller RSS. The 12–17 % musl penalty reported before #693/#712 **is not
  measurable any more** on the cell where it was reported.
- **The access log's `if` filter** (194–198): the write path +0.10 %, `/dev/null` +0.00 %,
  a one-variable condition +0.01 %, a five-variable condition with a full format +0.31 %
  (CI includes zero). A cheap `if` is affordable by default; a long condition over a long
  format is up to ~0.3 % of an authenticated Drupal request.
- **Pooling the ≥1008-byte send buffer** (priced, not built): the steady-state per-response
  allocation is a mutex plus a chunk bump, ≈ 73 instructions — 0.035 % of a hello request,
  66× below that cell's null band. No prototype.
- **The Python leg** (113): Unit's Python module costs **4.7× less server CPU** than
  gunicorn on the body cells (365–380 %, flat in body size) and the gap collapses with
  application work (+140.9 % at 1 000 iterations, +13.6 % at 20 000, +6.3 % at 200 000) —
  a per-request constant, not a per-byte or per-work one. Against 1.37.0 on the same app:
  level (209).
