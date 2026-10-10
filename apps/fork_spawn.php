<?php
/**
 * fork_spawn.php — run a long job in a warm-opcache fork child, answer the request at once.
 *
 * A Unit PHP worker is long-lived and holds a warm opcache (it was forked from the app
 * prototype). In a request handler we pcntl_fork():
 *   * the child inherits the opcache SHM      -> no cold start for a full Drupal bootstrap
 *   * the parent answers the HTTP request     -> no request timeout on a long job
 *   * the child calls posix_setsid()          -> it survives the reap of the request
 * The middle process exits, so the worker is reparented to init: no zombie stays.
 *
 * Endpoints (?job=...):
 *   (none)                     health: pid + opcache status + cached script count
 *   ?job=cron                  boot Drupal in-process and run cron
 *   ?job=queue&name=&limit=    boot Drupal in-process and drain a queue
 *   ?job=sleep&secs=N          probe: the child sleeps N seconds (detach and timeout test)
 *
 * Environment:
 *   JOBDIR            work dir for the logs        [default <tmp>/fu-pkgs]
 *   DRUPAL_ROOT       Drupal site root             (used by the boot scripts)
 *   DRUPAL_BOOT       cron boot script             [default <JOBDIR>/apps/drupal_boot_cron.php]
 *   DRUPAL_QUEUE_BOOT queue boot script            [default <JOBDIR>/apps/drupal_boot_queue.php]
 *   QUEUE_NAME        default queue name           [default fu_queue_test]
 *
 * Logs go to <JOBDIR>/spawn.out. The response body never carries job output.
 */

$JOBDIR  = getenv('JOBDIR') ?: rtrim(sys_get_temp_dir(), '/') . '/fu-pkgs';
$LOGFILE = "$JOBDIR/spawn.out";

function slog($m) { global $LOGFILE; @file_put_contents($LOGFILE, gmdate('H:i:s') . " $m\n", FILE_APPEND); }

/**
 * Terminate a fork child for real.
 *
 * `exit()` does NOT kill a fork child of a Unit PHP worker: the SAPI hands control back to
 * Unit's event loop, so the child keeps polling and lingers as an extra "application" worker
 * (one leak per fork, per tick). SIGKILL is the only reliable termination from inside.
 */
function zap() {
    posix_kill(getmypid(), SIGKILL);
    exit(0);            // fallback if the signal is blocked
}

/** Reap the children we SIGKILLed on earlier ticks — they stay zombies until someone waits. */
function reap() {
    $s = 0;
    while (pcntl_waitpid(-1, $s, WNOHANG) > 0) { /* drain */ }
}

$job = $_GET['job'] ?? null;

if ($job === null) {
    header('Content-Type: application/json');
    $s = @opcache_get_status(false);
    echo json_encode([
        'pid' => getmypid(),
        'opcache' => $s && $s['opcache_enabled'],
        'cached_scripts' => $s['opcache_statistics']['num_cached_scripts'] ?? 0,
        'hits' => $s['opcache_statistics']['hits'] ?? 0,
    ]);
    return;
}

reap();                                   // clear the leftovers of the previous tick
$pid = pcntl_fork();
if ($pid === -1) {
    http_response_code(500);
    echo "fork failed";
    return;
}

if ($pid === 0) {
    // ---- middle child: detach, then fork the real worker ----
    posix_setsid();                       // new session: the worker survives the request reap
    $w = pcntl_fork();
    if ($w === -1) { exit(1); }
    if ($w > 0) { zap(); }                // the middle dies -> the worker reparents to init

    // ---- worker (grandchild, orphaned, warm opcache) ----
    // This process still reports PHP_SAPI === 'cli' (inherited from the Unit worker), so the
    // boot scripts cannot tell it apart from a real CLI run by SAPI alone. Mark it.
    putenv('FORK_CHILD=1');
    $_ENV['FORK_CHILD'] = '1';
    $_SERVER['FORK_CHILD'] = '1';

    $sc = @opcache_get_status(false);
    slog("CHILD start pid=" . getmypid() . " job=$job opcache="
         . ($sc && $sc['opcache_enabled'] ? 'on' : 'off')
         . " cached=" . ($sc['opcache_statistics']['num_cached_scripts'] ?? 0));
    $t0 = microtime(true);
    set_error_handler(function ($no, $str, $file, $line) { slog("CHILD php-error [$no] $str @ $file:$line"); return false; });
    register_shutdown_function(function () {
        $e = error_get_last();
        if ($e && in_array($e['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR])) {
            slog("CHILD FATAL: " . $e['message'] . " @ " . $e['file'] . ":" . $e['line']);
        }
    });

    switch ($job) {
        case 'sleep':
            $secs = (int) ($_GET['secs'] ?? 5);
            sleep($secs);
            slog("CHILD done job=sleep secs=$secs");
            break;

        case 'cron':
            $boot = getenv('DRUPAL_BOOT') ?: "$JOBDIR/apps/drupal_boot_cron.php";
            if (is_file($boot)) {
                $r = include $boot;       // boots the kernel + runs cron, returns $out
                slog("CHILD job=cron bootstrapped via $boot ok=" . json_encode($r['cron_ok'] ?? null));
            } else {
                slog("CHILD job=cron (no boot script at $boot)");
            }
            break;

        case 'queue':
            $name = $_GET['name'] ?? (getenv('QUEUE_NAME') ?: 'fu_queue_test');
            putenv("QUEUE_NAME=$name");
            $_ENV['QUEUE_NAME'] = $name;
            if (isset($_GET['limit'])) {
                putenv('QUEUE_LIMIT=' . (int) $_GET['limit']);
            }
            $qboot = getenv('DRUPAL_QUEUE_BOOT') ?: "$JOBDIR/apps/drupal_boot_queue.php";
            if (is_file($qboot)) {
                $r = include $qboot;      // boots the kernel + drains the queue, returns $out
                slog("CHILD job=queue name=$name items=" . ($r['items'] ?? '?')
                     . " ok=" . json_encode($r['queue_ok'] ?? null));
            } else {
                slog("CHILD job=queue (no boot script at $qboot)");
            }
            break;

        default:
            slog("CHILD unknown job=$job");
    }

    slog(sprintf("CHILD exit pid=%d job=%s took=%.3fs", getmypid(), $job, microtime(true) - $t0));
    zap();                                // exit() would NOT terminate a fork child here
}

// ---- parent: answer at once, never wait for the job ----
pcntl_waitpid($pid, $status, WNOHANG);   // reap if it is already done, do not block
usleep(2000);                            // let the SIGKILLed middle child land...
reap();                                  // ...then collect it: no zombie accumulates
header('Content-Type: text/plain');
echo "spawned pid=$pid job=$job\n";
