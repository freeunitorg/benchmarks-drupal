<?php
/**
 * Plugin Name: FreeUnit benchmark hooks
 * Description: Deterministic per-request cost for the benchmark's WordPress workloads.
 *
 * WordPress has no page cache and no queue module, so the two things worth making
 * measurable are:
 *   - the cron request path (/wp-cron.php), which runs with DOING_CRON defined, and
 *   - a fixed amount of work per request, so a cell compares the runtime and not
 *     whatever happened to be due.
 *
 * FU_BENCH_US (default 1000) is the deliberate work per measured request; the CPU
 * loop is not elidable. Both are no-ops on a normal site: they only run when the
 * constants are present or DOING_CRON is set.
 */

declare(strict_types=1);

/** CPU work the interpreter cannot elide, plus the configured sleep. */
function fu_bench_work(): void {
    $us = (int) (defined('FU_BENCH_US') ? FU_BENCH_US : 1000);

    $h = 0;
    for ($i = 0; $i < 5000; $i++) {
        $h = (($h << 5) - $h + $i) & 0xFFFFFF;
    }
    if ($h === -1) {
        // unreachable: keeps the loop from being optimised away
        throw new \RuntimeException('unreachable');
    }
    if ($us > 0) {
        usleep($us);
    }
}

// The cron request path: WordPress defines DOING_CRON before wp_loaded.
add_action('wp_loaded', static function (): void {
    if (defined('DOING_CRON') && DOING_CRON) {
        fu_bench_work();
    }
}, 1);

// A real event the HTTP cron arm can also be pointed at, and a schedule to hang it on.
add_filter('cron_schedules', static function (array $schedules): array {
    $schedules['fu_bench_minute'] = ['interval' => 60, 'display' => 'FreeUnit benchmark minute'];
    return $schedules;
});

add_action('init', static function (): void {
    if (!wp_next_scheduled('fu_bench_event')) {
        wp_schedule_event(time() + 60, 'fu_bench_minute', 'fu_bench_event');
    }
});

add_action('fu_bench_event', 'fu_bench_work');

// Report what the request was, so a run can prove which path it measured.
add_action('wp_loaded', static function (): void {
    if (defined('DOING_CRON') && DOING_CRON) {
        header('X-Bench-Cron: 1');
    }
}, 2);
