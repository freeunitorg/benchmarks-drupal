"""ASGI control app: the same bytes as the PHP hello and as the WSGI sibling.

    /                 -> hello, one text/plain response
    ?mode=headers     -> the same plus 20 response headers and two cookies
    ?mode=body&size=N -> an N-byte body (8 KiB in the answer, clamped to 1 MiB)
    ?mode=work&n=N    -> N iterations of the same deterministic integer loop

Pure standard library, so the numbers measure Unit's Python module or uvicorn and not
a framework.
"""

from urllib.parse import parse_qs

from wsgi import _work  # the loop is identical by construction, not by copy


async def application(scope, receive, send):
    assert scope["type"] == "http"

    params = parse_qs(scope.get("query_string", b"").decode(), keep_blank_values=True)
    mode = (params.get("mode") or ["hello"])[0]

    headers = [(b"content-type", b"text/plain")]
    body = b"hello bench\n"

    if mode == "headers":
        headers += [(b"x-bench-%d" % i, b"value-%d" % i) for i in range(1, 21)]
        headers += [
            (b"set-cookie", b"bench_a=" + b"a" * 64 + b"; Path=/"),
            (b"set-cookie", b"bench_b=" + b"b" * 64 + b"; Path=/"),
        ]

    elif mode == "body":
        try:
            size = int((params.get("size") or ["65536"])[0])
        except ValueError:
            size = 65536
        size = max(0, min(1 << 20, size))
        body = b"x" * size

    elif mode == "work":
        try:
            n = int((params.get("n") or ["10000"])[0])
        except ValueError:
            n = 10000
        n = max(0, min(5000000, n))
        body = ("work %d %d\n" % (n, _work(n))).encode()

    await send(
        {
            "type": "http.response.start",
            "status": 200,
            "headers": headers + [(b"content-length", str(len(body)).encode())],
        }
    )
    await send({"type": "http.response.body", "body": body})
