"""WSGI control app: the same bytes as the PHP hello, no framework, no database.

    /                 -> hello, one text/plain response
    ?mode=headers     -> the same plus 20 response headers and two cookies
    ?mode=body&size=N -> an N-byte body (8 KiB in the answer, clamped to 1 MiB)
    ?mode=work&n=N    -> N iterations of the same deterministic integer loop as the
                         PHP app, so the two legs' work sweeps are comparable

The point of this file is to measure Unit's Python module and, on the other side,
gunicorn -- not a framework: nothing here imports anything but the standard library.
"""

from urllib.parse import parse_qs


def _work(n):
    x = 1
    for i in range(n):
        # PHP's version is (($x << 5) - $x + $i) & 0x7fffffff on 64-bit ints; the
        # mask keeps both sides in the same domain.
        x = ((x << 5) - x + i) & 0x7FFFFFFF
    return x


def application(environ, start_response):
    params = parse_qs(environ.get("QUERY_STRING", ""), keep_blank_values=True)
    mode = (params.get("mode") or ["hello"])[0]

    if mode == "headers":
        headers = [("Content-Type", "text/plain")]
        headers += [("X-Bench-%d" % i, "value-%d" % i) for i in range(1, 21)]
        headers += [
            ("Set-Cookie", "bench_a=" + "a" * 64 + "; Path=/"),
            ("Set-Cookie", "bench_b=" + "b" * 64 + "; Path=/"),
        ]
        start_response("200 OK", headers)
        return [b"hello bench\n"]

    if mode == "body":
        try:
            size = int((params.get("size") or ["65536"])[0])
        except ValueError:
            size = 65536
        size = max(0, min(1 << 20, size))
        start_response("200 OK", [("Content-Type", "text/plain")])
        chunk = b"x" * 8192
        out = []
        left = size
        while left > 0:
            out.append(chunk[: min(left, 8192)])
            left -= 8192
        return out

    if mode == "work":
        try:
            n = int((params.get("n") or ["10000"])[0])
        except ValueError:
            n = 10000
        n = max(0, min(5000000, n))
        x = _work(n)
        start_response("200 OK", [("Content-Type", "text/plain")])
        return [("work %d %d\n" % (n, x)).encode()]

    start_response("200 OK", [("Content-Type", "text/plain")])
    return [b"hello bench\n"]
