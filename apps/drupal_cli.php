<?php

/**
 * drupal_cli.php -- the site operations the benchmark needs, without drush.
 *
 * Drupal 12 cannot take drush 13 (it requires guzzle ^7, which the advisory
 * policy blocks while 12.0 pins guzzle 8), so the harness needs its own way to
 * enable a module, set a state key, create the authenticated benchmark user,
 * mint a one-time login URL, run cron and drain the queue. All of it is a thin
 * layer over the same Drupal APIs drush calls.
 *
 *   php drupal_cli.php enable fu_queue_test
 *   php drupal_cli.php state-set fu_queue_test.key benchmark
 *   php drupal_cli.php user-create bench-user bench-pass
 *   php drupal_cli.php login-url bench-user
 *   php drupal_cli.php cron
 *   php drupal_cli.php queue-run fu_queue_test 50
 *
 * DRUPAL_ROOT selects the site (default /app/web). Output is one JSON object on
 * stdout; a failure exits nonzero with {"error": ...}.
 */

$root = getenv('DRUPAL_ROOT') ?: '/app/web';
$cmd = $argv[1] ?? '';
$args = array_slice($argv, 2);

function fail(string $msg): never {
    fwrite(STDOUT, json_encode(['error' => $msg]) . "\n");
    exit(1);
}

if (!is_file($root . '/autoload.php')) {
    fail("no autoload.php under $root");
}

// Install runs before a kernel exists, so it is handled by core's own script.
if ($cmd === 'install') {
    $profile = $args[0] ?? 'demo_umami';
    $db = getenv('DB_URL') ?: 'mysql://root@db/drupal';
    $pass = getenv('SITE_PASS') ?: 'admin';
    $site = getenv('SITE_NAME') ?: 'FreeUnit benchmark';
    $script = $root . '/core/scripts/drupal';
    if (!is_file($script)) {
        fail("no $script");
    }
    chdir($root);
    $cmdline = sprintf(
        'php %s install %s --db-url=%s --account-name=admin --account-pass=%s --site-name=%s 2>&1',
        escapeshellarg($script), escapeshellarg($profile), escapeshellarg($db),
        escapeshellarg($pass), escapeshellarg($site)
    );
    exec($cmdline, $out, $rc);
    echo json_encode(['install' => $profile, 'rc' => $rc, 'tail' => array_slice($out, -8)]) . "\n";
    exit($rc === 0 ? 0 : 1);
}

chdir($root);
$autoloader = require_once $root . '/autoload.php';
$request = \Symfony\Component\HttpFoundation\Request::createFromGlobals();
$kernel = \Drupal\Core\DrupalKernel::createFromRequest($request, $autoloader, 'prod');
$kernel->boot();
$kernel->preHandle($request);

switch ($cmd) {
    case 'enable':
        $mods = $args;
        if (!$mods) {
            fail('enable needs at least one module');
        }
        \Drupal::service('module_installer')->install($mods, TRUE);
        echo json_encode(['enabled' => $mods]) . "\n";
        break;

    case 'disable':
        $mods = $args;
        \Drupal::service('module_installer')->uninstall($mods, TRUE);
        echo json_encode(['disabled' => $mods]) . "\n";
        break;

    case 'state-set':
        [$key, $value] = [$args[0] ?? '', $args[1] ?? ''];
        if ($key === '') {
            fail('state-set needs a key and a value');
        }
        \Drupal::state()->set($key, $value);
        echo json_encode(['state' => $key, 'value' => $value]) . "\n";
        break;

    case 'user-create':
        [$name, $pass] = [$args[0] ?? 'bench-user', $args[1] ?? 'bench-pass'];
        $storage = \Drupal::entityTypeManager()->getStorage('user');
        $found = $storage->loadByProperties(['name' => $name]);
        if ($found) {
            $user = reset($found);
            $user->setPassword($pass);
            $user->activate();
        }
        else {
            $user = $storage->create([
                'name' => $name,
                'pass' => $pass,
                'status' => 1,
                'mail' => $name . '@example.com',
            ]);
        }
        $user->addRole('authenticated');
        $user->save();
        echo json_encode(['user' => $name, 'uid' => (int) $user->id()]) . "\n";
        break;

    case 'login-url':
        $name = $args[0] ?? 'bench-user';
        \Drupal::moduleHandler()->loadInclude('user', 'module');
        $storage = \Drupal::entityTypeManager()->getStorage('user');
        $found = $storage->loadByProperties(['name' => $name]);
        if (!$found) {
            fail("no user $name");
        }
        $user = reset($found);
        echo json_encode(['url' => user_pass_reset_url($user)]) . "\n";
        break;

    case 'cache-rebuild':
        drupal_flush_all_caches();
        echo json_encode(['cache' => 'rebuilt']) . "\n";
        break;

    case 'cron':
        \Drupal::moduleHandler()->loadInclude('user', 'module');
        $result = \Drupal::service('cron')->run();
        echo json_encode(['cron' => is_scalar($result) ? $result : gettype($result)]) . "\n";
        break;

    case 'queue-run':
        $queue_name = $args[0] ?? '';
        $n = (int) ($args[1] ?? 50);
        if ($queue_name === '') {
            fail('queue-run needs a queue name');
        }
        $queue = \Drupal::queue($queue_name);
        $worker = \Drupal::service('plugin.manager.queue_worker')->createInstance($queue_name);
        $done = 0;
        $t0 = hrtime(true);
        while ($done < $n && ($item = $queue->claimItem())) {
            $worker->processItem($item->data);
            $queue->deleteItem($item);
            $done++;
        }
        echo json_encode([
            'queue' => $queue_name,
            'drained' => $done,
            'total_us' => (int) ((hrtime(true) - $t0) / 1000),
        ]) . "\n";
        break;

    default:
        fail("unknown command '$cmd'");
}
