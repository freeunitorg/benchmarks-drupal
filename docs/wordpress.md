# WordPress suite

WordPress 7.1.3, installed from wordpress.org with wp-cli 2.12.0 (both pinned, both
verified: wp-cli by the release's sha256, WordPress by the wordpress.org checksum API
wp-cli uses). The document root is `/app/web` like the other applications, so one set
of runtime configs serves Drupal, Symfony and WordPress.

## Why WordPress is a different measurement

* **There is no page cache.** Every anonymous request is a full bootstrap plus its
  queries, so `wp-front` is the render-bound workload, not the cache-bin one. There is
  no Drupal-style `X-Drupal-Cache: HIT` guard to check.
* **WordPress talks to the database through mysqli only.** `wp-includes/class-wpdb.php`
  has no PDO path (`private $use_mysqli = true;`, `mysqli_real_connect`), so this is the
  stack where the `mysqli` driver question is not a choice. It is also the natural place
  to test a connection that outlives a request.
* **`wpdb` has no persistent-connection support.** There is no "persistent" branch in
  class-wpdb.php, and `parse_db_host()` regex-matches `host[:port]`, so the classic
  `DB_HOST="p:host"` trick yields the host `p` and drops the port. The supported seam is
  a `wp-content/db.php` drop-in, which is what `wordpress/db-persistent.php` is: it
  overrides `db_connect()` and opens a `mysqli` handle with the `p:` prefix.

## Workloads

| key | request | what it measures |
|---|---|---|
| `wp-front` | `GET /` | the full render: bootstrap, queries, template, no cache |
| `wp-cron` | `GET /wp-cron.php?doing_wp_cron=1` | the HTTP cron path (the `automated_cron` equivalent) |

The `fu-bench` mu-plugin makes both deterministic: on a `DOING_CRON` request it runs the
same fixed CPU work Drupal's queue worker does (`FU_BENCH_US`, default 1 ms plus a
5000-step loop), so a cron cell measures the path and not whatever happened to be due. A
`fu_bench_event` is also scheduled on a one-minute interval for a real event to exist.

## The persistent-connection pair

`SITE=wp` and `SITE_B=wp-persistent` in one job is a within-job A/B: the two
installations differ by `wp-content/db.php` only, the runtime is held equal on both
sides, and the job's own null phase bounds the delta. It is the cleanest test of whether
a worker-resident connection pays off, which is exactly what a PHP worker target
(issue 596) would make bigger.

## Constraints

* WordPress needs MySQL or MariaDB; `DB=sqlite`/`pgsql` is refused (a SQLite drop-in
  exists in the ecosystem but is not core, and it would change the workload).
* `home`/`siteurl` are absolute (`http://127.0.0.1:<PORT>`). Rebuild the sites if a job
  changes `BASE_PORT`.
* No authenticated workload yet: WordPress admin requests need a session cookie, and
  core offers no headless way to mint one (application passwords cover REST, not page
  renders). The cookie jar the Drupal sites use has no WordPress equivalent here.
