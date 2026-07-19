#!/usr/bin/env python3
"""End-to-end HTTP test for the Python FastCGI development gateway."""

import pathlib
import sys
import threading
import urllib.request


HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import serve


def main():
    server = serve.create_server(
        ("127.0.0.1", 0),
        HERE / "fastcgi_host",
        HERE / "app.gengo",
    )
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        request = urllib.request.Request(
            f"http://127.0.0.1:{server.server_port}/hello?name=Ada",
            data=b"hello world",
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            assert response.status == 200
            assert response.headers["Content-Type"] == "text/html; charset=utf-8"
            body = response.read()
            assert b"<title>Gengo FastCGI</title>" in body
            assert b"<h1>POST /hello</h1>" in body
            assert b"<dd>name=Ada</dd>" in body
            assert b"<pre>hello world</pre>" in body
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()


if __name__ == "__main__":
    main()
