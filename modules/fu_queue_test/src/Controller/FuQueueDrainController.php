<?php

declare(strict_types=1);

namespace Drupal\fu_queue_test\Controller;

use Drupal\Core\Controller\ControllerBase;
use Drupal\Core\Queue\QueueFactory;
use Symfony\Component\DependencyInjection\ContainerInterface;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;

/**
 * HTTP trigger for the queue arm (plan section 3.3 arm B).
 *
 * One request fills the queue to N items when it is empty, then drains it,
 * so the measured cost is exactly N * per-item work plus one bootstrap.
 * The key must match state fu_queue_test.key; the site-build script sets it.
 */
final class FuQueueDrainController extends ControllerBase {

  public function __construct(
    private readonly QueueFactory $queueFactory,
  ) {}

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container): static {
    return new static($container->get('queue'));
  }

  /**
   * Drain up to N items of fu_queue_test and report the timing split.
   */
  public function drain(Request $request, string $key, int $n = 50): JsonResponse {
    $expected = (string) \Drupal::state()->get('fu_queue_test.key', '');
    if ($expected === '' || !hash_equals($expected, $key)) {
      return new JsonResponse(['error' => 'forbidden'], 403);
    }

    $queue = $this->queueFactory->get('fu_queue_test');
    $class = \Drupal::service('plugin.manager.queue_worker')
      ->createInstance('fu_queue_test');

    $filled = 0;
    for ($i = $queue->numberOfItems(); $i < $n; $i++) {
      $queue->createItem(['us' => 1000]);
      $filled++;
    }

    $t0 = hrtime(true);
    $done = 0;
    while ($done < $n && ($item = $queue->claimItem())) {
      $class->processItem($item->data);
      $queue->deleteItem($item);
      $done++;
    }
    $total_us = (int) (hrtime(true) - $t0) / 1000;

    return new JsonResponse([
      'queue' => 'fu_queue_test',
      'filled' => $filled,
      'drained' => $done,
      'total_us' => $total_us,
      'remaining' => $queue->numberOfItems(),
      'sapi' => PHP_SAPI,
    ]);
  }

}
