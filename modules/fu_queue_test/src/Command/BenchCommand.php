<?php

declare(strict_types=1);

namespace Drupal\fu_queue_test\Command;

use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * The benchmark's operations as one Drupal console command (`dr bench`).
 *
 * Drupal 11.4 and 12 ship `vendor/bin/dr` (drupal/core "bin": scripts/dr, a
 * Symfony Console application), and a class carrying #[AsCommand] in an enabled
 * module is discovered automatically (core's ConsoleCompilerPass), so this is the
 * supported extension point on 11.4, 11.5 and 12 -- no drush (which cannot be
 * installed on 12.0 while drush needs the advisory-blocked guzzle 7) and no
 * bespoke bootstrap script.
 *
 * One JSON object per invocation, including timings and opcache state, so the
 * cron/queue arms of the benchmark read the same shape on every Drupal line:
 *
 *   dr bench cron
 *   dr bench queue-fill fu_queue_test 50
 *   dr bench queue-run fu_queue_test 50
 *   dr bench user-create bench-user bench-pass
 *   dr bench login-url bench-user
 *   dr bench state-set fu_queue_test.key benchmark
 *   dr bench module-enable fu_queue_test page_cache dynamic_page_cache
 *   dr bench module-disable big_pipe
 *   dr bench cache-rebuild
 */
#[AsCommand(
  name: 'bench',
  description: 'Benchmark operations: cron, queue, user, login URL, state, module enable, cache rebuild.',
)]
final class BenchCommand extends Command {

  /**
   * {@inheritdoc}
   */
  protected function configure(): void {
    $this
      ->addArgument('operation', InputArgument::REQUIRED,
        'cron | queue-fill | queue-run | user-create | login-url | state-set | module-enable | module-disable | cache-rebuild')
      ->addArgument('args', InputArgument::IS_ARRAY, 'Operation arguments.');
  }

  /**
   * {@inheritdoc}
   */
  protected function execute(InputInterface $input, OutputInterface $output): int {
    $operation = (string) $input->getArgument('operation');
    $args = $input->getArgument('args');
    $started = microtime(TRUE);
    try {
      $result = match ($operation) {
        'cron' => $this->cron(),
        'queue-fill' => $this->queueFill($args[0] ?? '', (int) ($args[1] ?? 50)),
        'queue-run' => $this->queueRun($args[0] ?? '', (int) ($args[1] ?? 50)),
        'user-create' => $this->userCreate($args[0] ?? 'bench-user', $args[1] ?? 'bench-pass'),
        'login-url' => $this->loginUrl($args[0] ?? 'bench-user'),
        'state-set' => $this->stateSet($args[0] ?? '', $args[1] ?? ''),
        'module-enable' => $this->modules('install', $args),
        'module-disable' => $this->modules('uninstall', $args),
        'cache-rebuild' => $this->cacheRebuild(),
        default => throw new \InvalidArgumentException("unknown operation '$operation'"),
      };
    }
    catch (\Throwable $e) {
      $output->writeln(json_encode([
        'operation' => $operation,
        'error' => get_class($e) . ': ' . $e->getMessage(),
        'total_s' => round(microtime(TRUE) - $started, 4),
      ], JSON_UNESCAPED_SLASHES));
      return Command::FAILURE;
    }

    $status = @opcache_get_status(FALSE);
    $rss_kb = 0;
    if (preg_match('/^VmRSS:\s+(\d+)/m', (string) @file_get_contents('/proc/self/status'), $m)) {
      $rss_kb = (int) $m[1];
    }
    $output->writeln(json_encode($result + [
      'operation' => $operation,
      'total_s' => round(microtime(TRUE) - $started, 4),
      'opcache' => ($status && ($status['opcache_enabled'] ?? FALSE)) ? 1 : 0,
      'cached_scripts' => $status['opcache_statistics']['num_cached_scripts'] ?? 0,
      'hits' => $status['opcache_statistics']['hits'] ?? 0,
      'rss_kb' => $rss_kb,
    ], JSON_UNESCAPED_SLASHES));
    return Command::SUCCESS;
  }

  /**
   * Runs cron and reports the time it took.
   */
  private function cron(): array {
    $t = microtime(TRUE);
    $result = \Drupal::service('cron')->run();
    return ['cron_s' => round(microtime(TRUE) - $t, 4), 'cron_result' => is_scalar($result) ? (string) $result : gettype($result)];
  }

  /**
   * Fills a queue to N items.
   */
  private function queueFill(string $name, int $n): array {
    if ($name === '') {
      throw new \InvalidArgumentException('queue-fill needs a queue name');
    }
    $queue = \Drupal::queue($name);
    for ($i = $queue->numberOfItems(); $i < $n; $i++) {
      $queue->createItem(['us' => 1000]);
    }
    return ['queue' => $name, 'items' => $queue->numberOfItems()];
  }

  /**
   * Drains up to N items and reports the per-item work time.
   */
  private function queueRun(string $name, int $n): array {
    if ($name === '') {
      throw new \InvalidArgumentException('queue-run needs a queue name');
    }
    $queue = \Drupal::queue($name);
    $worker = \Drupal::service('plugin.manager.queue_worker')->createInstance($name);
    $t = microtime(TRUE);
    $done = 0;
    while ($done < $n && ($item = $queue->claimItem())) {
      $worker->processItem($item->data);
      $queue->deleteItem($item);
      $done++;
    }
    return [
      'queue' => $name,
      'drained' => $done,
      'queue_s' => round(microtime(TRUE) - $t, 4),
      'remaining' => $queue->numberOfItems(),
    ];
  }

  /**
   * Creates or updates the benchmark user.
   */
  private function userCreate(string $name, string $pass): array {
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
    return ['user' => $name, 'uid' => (int) $user->id()];
  }

  /**
   * Prints a one-time login URL for the user.
   */
  private function loginUrl(string $name): array {
    \Drupal::moduleHandler()->loadInclude('user', 'module');
    $storage = \Drupal::entityTypeManager()->getStorage('user');
    $found = $storage->loadByProperties(['name' => $name]);
    if (!$found) {
      throw new \InvalidArgumentException("no user $name");
    }
    $user = reset($found);
    return ['url' => user_pass_reset_url($user)];
  }

  /**
   * Sets a state key.
   */
  private function stateSet(string $key, string $value): array {
    if ($key === '') {
      throw new \InvalidArgumentException('state-set needs a key and a value');
    }
    \Drupal::state()->set($key, $value);
    return ['state' => $key, 'value' => $value];
  }

  /**
   * Installs or uninstalls modules.
   */
  private function modules(string $action, array $modules): array {
    if (!$modules) {
      throw new \InvalidArgumentException("$action needs at least one module");
    }
    \Drupal::service('module_installer')->{$action}($modules, TRUE);
    return [$action === 'install' ? 'enabled' : 'disabled' => $modules];
  }

  /**
   * Rebuilds every cache.
   */
  private function cacheRebuild(): array {
    drupal_flush_all_caches();
    return ['cache' => 'rebuilt'];
  }

}
