#!/usr/bin/env python3
"""Black-box protocol test for the sequential FastCGI responder."""

import pathlib
import struct
import subprocess
import sys


FCGI_VERSION_1 = 1
FCGI_BEGIN_REQUEST = 1
FCGI_END_REQUEST = 3
FCGI_PARAMS = 4
FCGI_STDIN = 5
FCGI_STDOUT = 6
FCGI_RESPONDER = 1


def record(record_type, request_id, content=b""):
    padding = (-len(content)) % 8
    return struct.pack(
        ">BBHHBB", FCGI_VERSION_1, record_type, request_id, len(content), padding, 0
    ) + content + (b"\0" * padding)


def name_value(name, value):
    name = name.encode()
    value = value.encode()
    assert len(name) < 128 and len(value) < 128
    return bytes([len(name), len(value)]) + name + value


def decode_records(data):
    records = []
    offset = 0
    while offset < len(data):
        assert offset + 8 <= len(data), "truncated FastCGI header"
        version, record_type, request_id, length, padding, reserved = struct.unpack_from(
            ">BBHHBB", data, offset
        )
        assert version == FCGI_VERSION_1
        assert reserved == 0
        offset += 8
        assert offset + length + padding <= len(data), "truncated FastCGI content"
        records.append((record_type, request_id, data[offset : offset + length]))
        offset += length + padding
    return records


def main():
    here = pathlib.Path(__file__).resolve().parent
    host = here / "fastcgi_host"
    app = here / "app.gengo"

    params = b"".join(
        [
            name_value("REQUEST_METHOD", "POST"),
            name_value("SCRIPT_NAME", "/hello"),
            name_value("QUERY_STRING", "name=Ada"),
        ]
    )
    request = b"".join(
        [
            record(FCGI_BEGIN_REQUEST, 1, struct.pack(">HB5s", FCGI_RESPONDER, 0, b"\0" * 5)),
            record(FCGI_PARAMS, 1, params[:17]),
            record(FCGI_PARAMS, 1, params[17:]),
            record(FCGI_PARAMS, 1),
            record(FCGI_STDIN, 1, b"hello "),
            record(FCGI_STDIN, 1, b"world"),
            record(FCGI_STDIN, 1),
        ]
    )

    result = subprocess.run([str(host), str(app)], input=request, capture_output=True, check=False)
    assert result.returncode == 0, result.stderr.decode(errors="replace")

    records = decode_records(result.stdout)
    stdout = b"".join(content for typ, request_id, content in records if typ == FCGI_STDOUT and request_id == 1)
    assert stdout.startswith(b"Status: 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<!doctype html>")
    assert b"<title>Gengo FastCGI</title>" in stdout
    assert b"<h1>POST /hello</h1>" in stdout
    assert b"<dd>name=Ada</dd>" in stdout
    assert b"<pre>hello world</pre>" in stdout
    assert records[-2] == (FCGI_STDOUT, 1, b"")
    assert records[-1] == (FCGI_END_REQUEST, 1, b"\0\0\0\0\0\0\0\0")

    followup_params = b"".join(
        [
            name_value("REQUEST_METHOD", "GET"),
            name_value("SCRIPT_NAME", "/health"),
            name_value("QUERY_STRING", ""),
        ]
    )
    followup = b"".join(
        [
            record(FCGI_BEGIN_REQUEST, 2, struct.pack(">HB5s", FCGI_RESPONDER, 0, b"\0" * 5)),
            record(FCGI_PARAMS, 2, followup_params),
            record(FCGI_PARAMS, 2),
            record(FCGI_STDIN, 2),
        ]
    )
    result = subprocess.run([str(host), str(app)], input=request + followup, capture_output=True, check=False)
    assert result.returncode == 0, result.stderr.decode(errors="replace")
    records = decode_records(result.stdout)
    stdout = b"".join(content for typ, request_id, content in records if typ == FCGI_STDOUT and request_id == 2)
    assert b"<h1>GET /health</h1>" in stdout
    assert b"<pre>" not in stdout
    assert records[-1] == (FCGI_END_REQUEST, 2, b"\0\0\0\0\0\0\0\0")

    oversized = b"x" * 65537
    request = b"".join(
        [
            record(FCGI_BEGIN_REQUEST, 1, struct.pack(">HB5s", FCGI_RESPONDER, 0, b"\0" * 5)),
            record(FCGI_PARAMS, 1, params),
            record(FCGI_PARAMS, 1),
            record(FCGI_STDIN, 1, oversized[:65535]),
            record(FCGI_STDIN, 1, oversized[65535:]),
            record(FCGI_STDIN, 1),
        ]
    )
    result = subprocess.run([str(host), str(app)], input=request, capture_output=True, check=False)
    assert result.returncode == 0, result.stderr.decode(errors="replace")
    records = decode_records(result.stdout)
    stdout = b"".join(content for typ, request_id, content in records if typ == FCGI_STDOUT and request_id == 1)
    assert b"Status: 500 Internal Server Error" in stdout
    assert b"request body exceeds host limit" in stdout
    assert records[-1] == (FCGI_END_REQUEST, 1, b"\0\0\0\1\0\0\0\0")


if __name__ == "__main__":
    main()
