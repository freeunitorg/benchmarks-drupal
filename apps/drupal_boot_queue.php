<?php
/**
 * drupal_boot_queue.php — real Drupal queue drain, with timing.
 *
 * Same shape as drupal_boot_cron.php, so the two ticks are comparable.
 *
 * Two ways to run it:
 *   CLI (cold):   php drupal_boot_queue.php           -> cold opcache path, JSON on stderr
 *   In-process:   included by fork_spawn.php (warm)   -> warm opcache, JSON into the job log
 *
 * Environment:
 *   DRUPAL_ROOT  Drupal site root (required)
 *   QUEUE_NAME   queue name and queue worker id  [default fu_queue_test]
 *   QUEUE_LIMIT  items per drain                 [default 50]
 *   QUEUE_FILL   >0: create that many items instead of draining
 *   JOBDIR       log dir for the in-process run  [default <tmp>/fu-pkgs]
 *
 * The queue must be a reliable queue: claimItem() and releaseItem() need it.
 */

$DRUPAL_ROOT = getenv('DRUPAL_ROOT') ?: '';
if ($DRUPAL_ROOT === '') {
    fwrite(STDERR, json_encode(['error' => 'set DRUPAL_ROOT to the Drupal site root']) . "\n");
    exit(1);
}

$QUEUE_NAME  = getenv('QUEUE_NAME') ?: 'fu_queue_test';
$QUEUE_LIMIT = (int) (getenv('QUEUE_LIMIT') ?: 50);
$QUEUE_FILL  = (int) (getenv('QUEUE_FILL') ?: 0);
$TIMING = [];

function tmark(&$t, $k) { $t[$k] = microtime(true); }

$t0 = microtime(true);
$TIMING['start'] = $t0;

chdir($DRUPAL_ROOT);
$autoloader = require_once $DRUPAL_ROOT . '/autoload.php';
tmark($TIMING, 'autoload');

$request = \Symfony\Component\HttpFoundation\Request::createFromGlobals();
$kernel = \Drupal\Core\DrupalKernel::createFromRequest($request, $autoloader, 'prod');
$kernel->boot();
$kernel->preHandle($request);
tmark($TIMING, 'kernel_new');

$queue = \Drupal::queue($QUEUE_NAME, TRUE);
$items = 0;
$ok = TRUE;
$err = NULL;

if ($QUEUE_FILL > 0) {
    for ($i = 0; $i < $QUEUE_FILL; $i++) {
        $queue->createItem(['us' => 1000]);        // 1 ms of deliberate work per item
    }
    $items = $QUEUE_FILL;
    $TIMING['queue'] = microtime(true);
}
else {
    $tQueue = microtime(true);
    try {
        $worker = \Drupal::service('plugin.manager.queue_worker')->createInstance($QUEUE_NAME);
        while ($items < $QUEUE_LIMIT) {
            $item = $queue->claimItem();
            if (!$item) {
                break;                             // drained, or nothing to do
            }
            $worker->processItem($item->data);
            $queue->deleteItem($item);
            $items++;
        }
    }
    catch (\Throwable $e) {
        $ok = FALSE;
        $err = get_class($e) . ': ' . $e->getMessage();
    }
    $TIMING['queue'] = microtime(true);
    $TIMING['queue_s'] = $TIMING['queue'] - $tQueue;
}

$total = microtime(true) - $t0;

$s = @opcache_get_status(false);
$out = [
    'pid' => getmypid(),
    'queue' => $QUEUE_NAME,
    'mode' => $QUEUE_FILL > 0 ? 'fill' : 'drain',
    'opcache' => $s && $s['opcache_enabled'],
    'cached_scripts' => $s['opcache_statistics']['num_cached_scripts'] ?? 0,
    'hits' => $s['opcache_statistics']['hits'] ?? 0,
    'autoload_s' => round(($TIMING['autoload'] ?? $t0) - $t0, 4),
    'kernel_s' => round(($TIMING['kernel_new'] ?? $t0) - ($TIMING['autoload'] ?? $t0), 4),
    'queue_s' => round($TIMING['queue_s'] ?? 0, 4),
    'items' => $items,
    'total_s' => round($total, 4),
    'queue_ok' => $ok,
    'queue_err' => $err,
];

if (PHP_SAPI === 'cli' && getenv('FORK_CHILD') !== '1') {
    fwrite(STDERR, json_encode($out) . "\n");
    exit(0);
}
$jobdir = getenv('JOBDIR') ?: rtrim(sys_get_temp_dir(), '/') . '/fu-pkgs';
file_put_contents($jobdir . '/queue_boot.out', json_encode($out) . "\n", FILE_APPEND | LOCK_EX);
return $out;
