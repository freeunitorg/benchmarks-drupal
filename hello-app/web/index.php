<?php
// Control app: the same bytes from every runtime, no framework, no database.
//   /            -> hello, one text/plain response
//   ?mode=headers -> the same plus 20 response headers and two cookies
//   ?mode=body    -> a 64 KiB body
$mode = $_GET['mode'] ?? 'hello';
if ($mode === 'headers') {
    for ($i = 1; $i <= 20; $i++) {
        header("X-Bench-$i: value-$i");
    }
    setcookie('bench_a', str_repeat('a', 64));
    setcookie('bench_b', str_repeat('b', 64));
}
if ($mode === 'body') {
    header('Content-Type: text/plain');
    echo str_repeat('x', 65536);
    return;
}
header('Content-Type: text/plain');
echo "hello bench\n";
