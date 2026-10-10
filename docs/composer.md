# Using the benchmark as a Composer package

`freeunitorg/benchmarks-drupal` is a Composer package (`type: library`) with one
entry point, `bin/drupal-bench`, so another project -- the FreeUnit harness in
particular -- can depend on the benchmark instead of copying its scripts.

## Install

From the repository (a tag makes a stable constraint possible; `v0.1.0` is the first):

```json
{
  "repositories": [
    { "type": "vcs", "url": "https://github.com/freeunitorg/benchmarks-drupal" }
  ],
  "require-dev": {
    "freeunitorg/benchmarks-drupal": "^0.1"
  }
}
```

Or from a checkout on the same machine, without publishing:

```json
{
  "repositories": [
    { "type": "path", "url": "/path/to/benchmarks-drupal" }
  ],
  "require-dev": { "freeunitorg/benchmarks-drupal": "@dev" },
  "minimum-stability": "dev"
}
```

Then `vendor/bin/drupal-bench` works from the consumer's root. It resolves the
installed package root itself (`drupal-bench path` prints it), `chdir`s there and
dispatches, so the relative paths inside the scripts (`docker/`, `modules/`,
`bench/jobs/`) behave exactly as in a checkout. A Composer proxy or a symlink are
both handled.

## What the entry point gives the harness

```
drupal-bench path                       # where the benchmark lives
drupal-bench build                      # the three runtime images + MariaDB
drupal-bench site 11.4|11.4-standard|12.0|12.0-standard|symfony|hello [--force]
drupal-bench run <job file> [--no-gate] # one measured job, verdict included
drupal-bench tick <runtime> <A|B> [n]   # cron/queue arms (A cold CLI, B HTTP)
drupal-bench campaign <steps> [runroot] # a resumable steps file
drupal-bench watchdog [secs] [runroot]  # health loop for a running campaign
drupal-bench collect [host] [remote]    # results/ from the box, then render
drupal-bench report                     # render the page from results/
drupal-bench compare <tsv> <meta>       # perf-compare on one results file
drupal-bench cli <operation> ...        # apps/drupal_cli.php
```

Environment stays the caller's: `RUNROOT` (where runs land), `OHA`, `IMAGE_TAG`,
`LAB_ENV`. The harness can therefore keep its own claim/idle-gate policy around
the calls, or use `campaign` and `watchdog`, which already implement them.

## The Drupal module is its own package

`modules/fu_queue_test/composer.json` declares `freeunitorg/fu-queue-test`
(`type: drupal-module`), so a Drupal site can require the queue worker, the HTTP
drain route and the `dr bench` console command without the benchmark harness:

```json
{
  "repositories": [
    { "type": "vcs", "url": "https://github.com/freeunitorg/benchmarks-drupal" }
  ],
  "require": { "freeunitorg/fu-queue-test": "^0.1" }
}
```

`dr bench` needs Drupal 11.4 or 12 (both ship `vendor/bin/dr` and auto-discover
`#[AsCommand]` classes); see [dr-bench.md](dr-bench.md).

## Versioning

`extra.branch-alias` maps `dev-main` to `0.1.x-dev`. Tags are plain
`vMAJOR.MINOR.PATCH`; the benchmark's own results pin the harness revision that
produced them in each run's `meta.txt`, not the package version.
