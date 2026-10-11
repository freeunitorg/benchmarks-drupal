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

/**
 * The database specification for DB_DRIVER, in the shape Drupal's installer and
 * settings.php expect (the driver key is the namespace).
 */
function db_spec(): array {
    $driver = getenv('DB_DRIVER') ?: 'mysql';
    $url = getenv('DB_URL') ?: '';
    $p = $url !== '' ? (parse_url($url) ?: []) : [];
    $drivers = [
        'mysql' => ['Drupal\\mysql\\Driver\\Database\\mysql', 'core/modules/mysql/src/Driver/Database/mysql/', 3306, 'root', 'db'],
        'mysqli' => ['Drupal\\mysqli\\Driver\\Database\\mysqli', 'core/modules/mysqli/src/Driver/Database/mysqli/', 3306, 'root', 'db'],
        'pgsql' => ['Drupal\\pgsql\\Driver\\Database\\pgsql', 'core/modules/pgsql/src/Driver/Database/pgsql/', 5432, 'postgres', 'db'],
        'sqlite' => ['Drupal\\sqlite\\Driver\\Database\\sqlite', 'core/modules/sqlite/src/Driver/Database/sqlite/', 0, '', ''],
    ];
    if (!isset($drivers[$driver])) {
        fail("unknown DB_DRIVER '$driver' (mysql, mysqli, pgsql, sqlite)");
    }
    [$namespace, $autoload, $port, $user, $host] = $drivers[$driver];
    if ($driver === 'sqlite') {
        return [
            'database' => 'sites/default/files/.sqlite',
            'driver' => 'sqlite',
            'namespace' => $namespace,
            'autoload' => $autoload,
        ];
    }
    return [
        'database' => ltrim($p['path'] ?? '/drupal', '/'),
        'username' => $p['user'] ?? $user,
        'password' => $p['pass'] ?? '',
        'prefix' => '',
        'host' => $p['host'] ?? $host,
        'port' => (int) ($p['port'] ?? $port),
        'driver' => $driver,
        'namespace' => $namespace,
        'autoload' => $autoload,
    ];
}

// Install runs before a kernel exists. Drupal 12's core/scripts/drupal installer is
// hardcoded to SQLite (it has no --db-url), so this calls install_drupal() with the
// database spec in the settings form -- exactly what drush's site:install does.
if ($cmd === 'install' || $cmd === 'install-recipe') {
    // A recipe installs with an empty profile: the recipe carries the whole site.
    // Drupal 12's own `dr install` accepts a recipe too, but it hardcodes SQLite
    // (it requires pdo_sqlite and has no --db-url), so the same recipe parameter
    // goes to install_drupal() with a real driver spec instead.
    $recipe = '';
    if ($cmd === 'install-recipe') {
        $recipe = $args[0] ?? '';
        if ($recipe === '') {
            fail('install-recipe needs a recipe directory, e.g. core/recipes/standard');
        }
        $profile = '';
    }
    else {
        $profile = $args[0] ?? 'demo_umami';
    }
    $pass = getenv('SITE_PASS') ?: 'admin';
    $site_name = getenv('SITE_NAME') ?: 'FreeUnit benchmark';
    chdir($root);
    if (!is_file($root . '/core/includes/install.core.inc')) {
        fail("no install.core.inc under $root");
    }
    define('MAINTENANCE_MODE', 'install');
    require_once $root . '/core/includes/install.core.inc';
    require_once $root . '/core/includes/install.inc';
    $class_loader = require_once $root . '/autoload.php';

    $db_spec = db_spec();
    $namespace = $db_spec['namespace'];
    $settings = [
        'parameters' => [
            'profile' => $profile,
            'langcode' => 'en',
        ],
        'forms' => [
            'install_settings_form' => [
                'driver' => $namespace,
                $namespace => $db_spec,
                'op' => 'Save and continue',
            ],
            'install_configure_form' => [
                'site_name' => $site_name,
                'site_mail' => 'admin@example.com',
                'account' => [
                    'name' => 'admin',
                    'mail' => 'admin@example.com',
                    'pass' => ['pass1' => $pass, 'pass2' => $pass],
                ],
                'enable_update_status_module' => TRUE,
                'enable_update_status_emails' => NULL,
                'clean_url' => TRUE,
                'op' => 'Save and continue',
            ],
        ],
    ];
    try {
        if ($recipe !== '') {
            // The key Drupal\Core\Command\InstallCommand uses, so install_drupal()
            // builds the site from the recipe (it resolves the path from the root).
            $settings['parameters']['recipe'] = $recipe;
        }
        install_drupal($class_loader, $settings);
    }
    catch (\Throwable $e) {
        fail('install failed: ' . get_class($e) . ': ' . $e->getMessage());
    }
    echo json_encode([
        'install' => $recipe !== '' ? "recipe:$recipe" : $profile,
        'database' => $db_spec['database'],
        'host' => $db_spec['host'] ?? '',
    ], JSON_UNESCAPED_SLASHES) . "\n";
    exit(0);
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

    case 'module-enabled':
        $name = $args[0] ?? '';
        if ($name === '') {
            fail('module-enabled needs a module name');
        }
        $on = \Drupal::moduleHandler()->moduleExists($name);
        echo json_encode(['module' => $name, 'enabled' => $on ? 1 : 0]) . "\n";
        exit($on ? 0 : 1);

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

    case 'front':
        // Drupal 12's standard profile sets page.front to /admin/welcome, an
        // admin-only page, so an anonymous GET / is a 403 and nothing is page
        // cached. Drupal 11's standard profile used /node; do the same.
        $path = $args[0] ?? '/node';
        \Drupal::configFactory()->getEditable('system.site')->set('page.front', $path)->save();
        echo json_encode(['front' => $path]) . "\n";
        break;

    case 'front-node':
        // /node is not a route in Drupal 12: the frontpage view is optional config
        // of the node module in 11.4 but ships only with the demo_umami profile in
        // 12, so a standard site has no front page at all. Create a real page (as
        // the old standard profile's welcome node did) and point the front page at
        // it; it is cacheable and readable by anonymous and authenticated users.
        $title = $args[0] ?? 'Welcome to the FreeUnit benchmark';
        $node = \Drupal\node\Entity\Node::create([
          'type' => 'page',
          'title' => $title,
          'status' => 1,
          'promote' => 1,
          'body' => ['value' => 'Front page of the benchmark site.', 'format' => 'basic_html'],
        ]);
        $node->save();
        $path = '/node/' . $node->id();
        \Drupal::configFactory()->getEditable('system.site')->set('page.front', $path)->save();
        echo json_encode(['front' => $path, 'nid' => (int) $node->id()]) . "\n";
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
        // Drupal 12 refuses to assign the built-in roles by hand; a user with a
        // password and status 1 is authenticated implicitly, so only named roles
        // would need addRole() here.
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

    case 'queue-fill':
        $queue_name = $args[0] ?? '';
        $n = (int) ($args[1] ?? 50);
        if ($queue_name === '') {
            fail('queue-fill needs a queue name');
        }
        $queue = \Drupal::queue($queue_name);
        for ($i = $queue->numberOfItems(); $i < $n; $i++) {
            $queue->createItem(['us' => 1000]);
        }
        echo json_encode(['queue' => $queue_name, 'items' => $queue->numberOfItems()]) . "\n";
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
