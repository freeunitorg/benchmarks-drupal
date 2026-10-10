<?php
/**
 * drupal_boot_cron.php — real Drupal bootstrap + cron, with timing.
 *
 * Two ways to run it:
 *   CLI (cold):   php drupal_boot_cron.php            -> cold opcache path, JSON on stderr
 *   In-process:   included by fork_spawn.php (warm)   -> warm opcache, JSON into the job log
 *
 * Environment:
 *   DRUPAL_ROOT  Drupal site root (required)
 *   JOBDIR       log dir for the in-process run [default <tmp>/fu-pkgs]
 */

$DRUPAL_ROOT = getenv('DRUPAL_ROOT') ?: '';
if ($DRUPAL_ROOT === '') {
    fwrite(STDERR, json_encode(['error' => 'set DRUPAL_ROOT to the Drupal site root']) . "\n");
    exit(1);
}

$TIMING = [];
function tmark(&$t, $k) { $t[$k] = microtime(true); }

$t0 = microtime(true);
$TIMING['start'] = $t0;

chdir($DRUPAL_ROOT);
$autoloader = require_once $DRUPAL_ROOT . '/autoload.php';
tmark($TIMING, 'autoload');

// Bootstrap the Drupal kernel (prod) properly, so the container is set.
$request = \Symfony\Component\HttpFoundation\Request::createFromGlobals();
$kernel = \Drupal\Core\DrupalKernel::createFromRequest($request, $autoloader, 'prod');
$kernel->boot();
$kernel->preHandle($request);
tmark($TIMING, 'kernel_new');

// Run cron.
$tCron = microtime(true);
try {
    $result = \Drupal::service('cron')->run();
    $cronOk = true;
}
catch (\Throwable $e) {
    $cronOk = false;
    $result = get_class($e) . ': ' . $e->getMessage();
}
$TIMING['cron'] = microtime(true) - $tCron;

$total = microtime(true) - $t0;

$s = @opcache_get_status(false);
$out = [
    'pid' => getmypid(),
    'opcache' => $s && $s['opcache_enabled'],
    'cached_scripts' => $s['opcache_statistics']['num_cached_scripts'] ?? 0,
    'hits' => $s['opcache_statistics']['hits'] ?? 0,
    'autoload_s' => round(($TIMING['autoload'] ?? $t0) - $t0, 4),
    'kernel_s' => round(($TIMING['kernel_new'] ?? $t0) - ($TIMING['autoload'] ?? $t0), 4),
    'cron_s' => round($TIMING['cron'] ?? 0, 4),
    'total_s' => round($total, 4),
    'cron_ok' => $cronOk,
    'cron_result' => is_scalar($result) ? $result : gettype($result),
];

if (PHP_SAPI === 'cli' && getenv('FORK_CHILD') !== '1') {
    fwrite(STDERR, json_encode($out) . "\n");
    exit(0);
}
// in-process (fork child) or web: append to the job log
$jobdir = getenv('JOBDIR') ?: rtrim(sys_get_temp_dir(), '/') . '/fu-pkgs';
file_put_contents($jobdir . '/cron_boot.out', json_encode($out) . "\n", FILE_APPEND | LOCK_EX);
return $out;
