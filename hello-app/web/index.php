<?php
// Control app: the same bytes from every runtime, no framework, no database.
//   /            -> hello, one text/plain response
//   ?mode=headers -> the same plus 20 response headers and two cookies
//   ?mode=body    -> a 64 KiB body; ?mode=body&size=N for any N up to 1 MiB
$mode = $_GET['mode'] ?? 'hello';
if ($mode === 'headers') {
    for ($i = 1; $i <= 20; $i++) {
        header("X-Bench-$i: value-$i");
    }
    setcookie('bench_a', str_repeat('a', 64));
    setcookie('bench_b', str_repeat('b', 64));
}
if ($mode === 'body') {
    // ?size=N sets the body size, so a sweep can tell a per-byte worker cost from a
    // per-request one: the same response, only its length changes.
    $size = isset($_GET['size']) ? (int) $_GET['size'] : 65536;
    $size = max(0, min(1 << 20, $size));
    header('Content-Type: text/plain');
    $chunk = str_repeat('x', 8192);
    for ($left = $size; $left > 0; $left -= 8192) {
        echo substr($chunk, 0, min($left, 8192));
    }
    return;
}
header('Content-Type: text/plain');
echo "hello bench\n";
