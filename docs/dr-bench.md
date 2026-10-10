# `dr bench`: one command for both Drupal lines

Drupal 11.4/11.5/12 ship `vendor/bin/dr` (`drupal/core` declares `"bin": ["scripts/dr"]`,
a Symfony Console application), and core's `ConsoleCompilerPass` auto-discovers any class
carrying `#[AsCommand]` in an enabled module. So the benchmark's operations live in one
command in `fu_queue_test` instead of a bespoke bootstrap script:

```
dr bench cron
dr bench queue-fill fu_queue_test 50
dr bench queue-run fu_queue_test 50
dr bench user-create bench-user bench-pass
dr bench login-url bench-user
dr bench state-set fu_queue_test.key benchmark
dr bench module-enable fu_queue_test page_cache dynamic_page_cache
dr bench module-disable big_pipe
dr bench cache-rebuild
```

Every invocation prints one JSON object with the operation, the timings and the opcache
state (`cached_scripts`, `hits`, `rss_kb`), the shape the gist's
`drupal_boot_cron.php` used, so the cron and queue arms read the same fields on 11.4,
11.5 and 12.

Why it exists rather than `dr install` doing everything: `dr install` has no `--db-url`
and hardcodes SQLite. `install.core.inc` skips its settings form when `settings.php`
verifies (a valid connection *and* a non-empty `hash_salt`), so

Module enable has no core CLI, so the first enable uses the same standalone CLI; after
that `dr bench` is the path. drush stays the 11.x arm where it is installed, because
those cron-arm numbers are already published.

Files: `modules/fu_queue_test/src/Command/BenchCommand.php` (the command),
`apps/drupal_cli.php` (the install_drupal path and the operations `dr` does not have), `scripts/site-build.sh` and `bench/tick.sh` (the fallback order drush → dr →
standalone).
