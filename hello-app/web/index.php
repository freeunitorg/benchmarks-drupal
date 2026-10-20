<?php
// Control app: the same bytes from every runtime, no framework, no database.
//   /            -> hello, one text/plain response
//   ?mode=headers -> the same plus 20 response headers and two cookies
//   ?mode=body    -> a 64 KiB body; ?mode=body&size=N for any N up to 1 MiB
//   ?mode=work&n=N -> N iterations of a deterministic PHP loop
$mode = $_GET['mode'] ?? 'hello';
if ($mode === 'headers') {
    for ($i = 1; $i <= 20; $i++) {
        header("X-Bench-$i: value-$i");
    }
    setcookie('bench_a', str_repeat('a', 64));
    setcookie('bench_b', str_repeat('b', 64));
}
if ($mode === 'work') {
    // ?mode=work&n=N burns a deterministic amount of PHP, so a sweep can ask whether
    // Unit's worker costs more per unit of PHP work than php-fpm's (the auth cell says
    // the deficit is in the worker; this separates per-request setup from per-PHP-work).
    $n = isset($_GET['n']) ? (int) $_GET['n'] : 10000;
    $n = max(0, min(5000000, $n));
    $x = 1;
    for ($i = 0; $i < $n; $i++) {
        $x = (($x << 5) - $x + $i) & 0x7fffffff;
    }
    header('Content-Type: text/plain');
    echo "work $n $x\n";
    return;
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
