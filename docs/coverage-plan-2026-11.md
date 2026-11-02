
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

## What this changes in the plan

P0 was priced as "the only gap that can change a published conclusion" and it did not. The
remaining phases keep their values but change in kind:

- **P2 (runtime matrix)** is now the highest-value work: it adds rows nobody has, including
  the one category P0 found missing (Apache and the nginx forks on the **authenticated**
  page, where Apache's CPU cost is measurable but its latency is much lower).
- **P1 and P3** stay as written: release history and the database axis.
- **P4** shrinks by one item: the `drupal-auth` guard is done.
