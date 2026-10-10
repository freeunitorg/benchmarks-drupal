<?php

declare(strict_types=1);

namespace Drupal\fu_queue_test\Plugin\QueueWorker;

use Drupal\Core\Queue\Attribute\QueueWorker;
use Drupal\Core\Queue\QueueWorkerBase;
use Drupal\Core\StringTranslation\TranslatableMarkup;

/**
 * Harness worker: deterministic, measurable work per queue item.
 *
 * Item data: ['us' => <microseconds of deliberate sleep>]. The default is 1 ms,
 * so draining N items costs N ms of "real" work — enough to tell a queue tick's
 * own cost (bootstrap + queue machinery) apart from the work it performs.
 */
#[QueueWorker(
  id: 'fu_queue_test',
  title: new TranslatableMarkup('FreeUnit queue test'),
  cron: ['time' => 30],
)]
class FuQueueTest extends QueueWorkerBase {

  /**
   * {@inheritdoc}
   */
  public function processItem($data): void {
    $us = (int) ($data['us'] ?? 1000);

    // CPU work that the interpreter cannot elide, so the loop is not free.
    $h = 0;
    for ($i = 0; $i < 5000; $i++) {
      $h = (($h << 5) - $h + $i) & 0xFFFFFF;
    }
    if ($h === -1) {
      throw new \RuntimeException('unreachable');
    }

    if ($us > 0) {
      usleep($us);
    }
  }

}
