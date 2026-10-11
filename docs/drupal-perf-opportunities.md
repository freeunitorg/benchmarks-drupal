# Drupal 11.5/12 performance: what is on the table, and what we are not using

Status: findings, 2026-10-10. Every claim is marked with where it was read.
Versions in the benchmark at the time of writing: Drupal 11.4.8, Drupal
12.0.0-beta1, PHP 8.5.11, FreeUnit 1.37.0 and master.

## What 12.0 changes on the request path

| | 11.4.8 | 12.0.0-beta1 |
|---|---|---|
| Symfony | 7.4.x | **8.1.x** (`composer.lock` in both sites) |
| Bootstrap | `web/index.php` builds the kernel itself | `web/autoload_runtime.php` sets `APP_RUNTIME`, `web/index.php` returns `static fn () => new DrupalKernel('prod', require 'autoload.php')` |
| Runtime | none | `Drupal\Core\Runtime\DrupalRuntime extends SymfonyRuntime` |

12.0 is the first Drupal that goes through Symfony's Runtime component, and that
is what makes a server integration possible without patching core (see
`../freeunit4drupal/packages/freeunit`). Symfony 8.1 also brings native lazy
objects (`symfony/var-exporter`, present in `vendor/`), which Drupal core does not
use yet.

## Verified facts about our own setup

Read on the built 12.0 site on pro4s-2:

* **The autoloader is not optimized.** `vendor/composer/autoload_classmap.php` has
  79 entries: `composer create-project` installs without `-o`, so every class
  outside the small core classmap is resolved with a PSR-4 `stat()` per candidate
  directory. This is the single cheapest production step and we are not doing it.
* **No OPcache preload.** `docker/php-production.ini` sets
  `opcache.validate_timestamps=0`, `realpath_cache_size=4096K` and JIT off, but
  there is no `opcache.preload`, and `find web/core -iname '*preload*'` finds only
  unrelated classes (`CacheTagsChecksumPreloadInterface`, `PreloadableRouteProviderInterface`).
  Symfony's `Preloader` **is** shipped (`vendor/symfony/dependency-injection/Dumper/Preloader.php`)
  and unused.
* **No APCu.** `php -m` in the image has no `apcu`, so Composer's `--apcu` mode and
  Drupal's `ApcuBackend`/`ApcuBackendFactory` (`web/core/lib/Drupal/Core/Cache/`)
  are both unavailable.
* **JIT is off** (`opcache.jit = disable`) and lives in the image's `php.ini`.

## The levers, in the order worth trying

1. **Optimized autoloader** (`composer dump-autoload --optimize`). **Not**
   `--classmap-authoritative`: Drupal 12 registers core module namespaces at
   runtime (the database driver is `core/modules/mysql`), and authoritative mode
   disables the PSR-4 fallback those registrations need, so the boot fails with
   `Class "Drupal\mysql\Driver\Database\mysql\Connection" not found`.
   Measured on the first 12.0-standard rebuild. Removes PSR-4 lookups and `file_exists` probes for
   every class on every request. Measurable as instructions retired per request,
   which is exactly what the benchmark counts. No new dependency, no behaviour
   change, applies to all three runtimes.
2. **APCu for the autoloader and for Drupal's cache.** Needs `apcu` in the image
   first (`pecl install apcu`, or `install-php-extensions apcu`). Drupal ships
   `ApcuBackend`; the default `cache.backend.database` for bins that are read on
   every request is a database round trip per bin. A `cache.backend.chainedfast`
   or a per-bin APCu override in `services.yml` is a standard Drupal production
   tweak we have never measured here.
3. **OPcache preload.** Generate a preload file from the composer classmap plus
   the classes the container instantiates, and set `opcache.preload`. Drupal core
   has no support for it, which is why nobody has a number for it. It is the
   largest lever for classes that are loaded on every request but not yet in the
   opcode cache, and it is per-site, so it fits the FreeUnit model (one
   application per site).
4. **JIT.** `opcache.jit=function` (or `tracing`, with a larger
   `opcache.jit_buffer_size`) is worth one arm each. Drupal's front page is
   cache-bound rather than CPU-bound, so the honest expectation is "no claim", but
   the authenticated page does more PHP work and is where a difference would show.
5. **Symfony 8.1 lazy objects.** `symfony/var-exporter` can build native PHP 8.4+
   lazy objects, so a service that is only touched conditionally could be
   instantiated on first use instead of on container build. Drupal core does not
   use this yet; a module could mark a few heavy services. Speculative until the
   profiler says which services cost.
6. **Worker mode** (FreeUnit 1.38, issue 596). Boot Drupal once per process and
   serve many requests. The module's `FreeUnitWorkerRunner` is ready for it; the
   number to get is "how much of the 8-10% front-page gap survives when bootstrap
   is paid once".

## The FreeUnit-shaped constraint

`opcache.jit`, `opcache.preload` and `zend_extension` are `PHP_INI_SYSTEM`: they
must be set before `php_module_startup()`. FreeUnit applies
`applications.*.options.admin` **after** startup, so those settings have no effect
from the JSON configuration (nginx/unit issue 785; plan item 3 in
`freeunit4drupal/docs/plan.md` §7). Until that is fixed, per-application JIT and
preload have to come from a baked or mounted `php.ini` — which is what the
benchmark does today. This is a concrete reason for the fork to fix item 3: with
it, a FreeUnit site could enable preload per application instead of per image.

## What to implement, and how to keep the published numbers honest

The optimizations apply to every runtime equally (same image, same site), so they
change the **baseline**, not the FreeUnit-vs-FPM comparison. Two rules keep that
honest:

* the change lands in the site builder and the image, and the page notes the
  baseline it was measured on (`meta.txt` already records the image and tag);
* anything that is a *choice* (JIT on, APCu on, preload on) becomes its own site
  variant and its own job pair, so a reader can see the effect on one runtime
  without it leaking into the others.

Implemented with this note: the optimized autoloader in
`scripts/site-build.sh`, and a preload file generator that the cell helper mounts
when a site has one.
