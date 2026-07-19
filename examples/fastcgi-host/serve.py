#!/usr/bin/env python3
"""Development HTTP gateway for the local FastCGI responder."""

import argparse
import pathlib
import struct
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit


FCGI_VERSION_1 = 1
FCGI_BEGIN_REQUEST = 1
FCGI_END_REQUEST = 3
FCGI_PARAMS = 4
FCGI_STDIN = 5
FCGI_STDOUT = 6
FCGI_STDERR = 7
FCGI_RESPONDER = 1


class GatewayError(Exception):
    pass


def record(record_type, request_id, content=b""):
    padding = (-len(content)) % 8
    return struct.pack(
        ">BBHHBB", FCGI_VERSION_1, record_type, request_id, len(content), padding, 0
    ) + content + (b"\0" * padding)


def name_value(name, value):
    name = name.encode()
    value = value.encode()

    def length(n):
        if n < 128:
            return bytes([n])
        return struct.pack(">I", n | 0x80000000)

    return length(len(name)) + length(len(value)) + name + value


def read_exact(stream, length):
    data = bytearray()
    while len(data) < length:
        chunk = stream.read(length - len(data))
        if not chunk:
            raise GatewayError("FastCGI responder closed its output stream")
        data.extend(chunk)
    return bytes(data)


class FastCGIGateway:
    def __init__(self, binary, app):
        self.process = subprocess.Popen([str(binary), str(app)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.next_request_id = 1

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()

    def request(self, method, target, body):
        if self.process.poll() is not None:
            raise GatewayError("FastCGI responder has exited")

        request_id = self.next_request_id
        self.next_request_id = 1 if request_id == 0xFFFF else request_id + 1
        target_parts = urlsplit(target)
        params = b"".join(
            [
                name_value("REQUEST_METHOD", method),
                name_value("SCRIPT_NAME", target_parts.path or "/"),
                name_value("QUERY_STRING", target_parts.query),
                name_value("CONTENT_LENGTH", str(len(body))),
            ]
        )
        stream = [
            record(FCGI_BEGIN_REQUEST, request_id, struct.pack(">HB5s", FCGI_RESPONDER, 0, b"\0" * 5)),
            record(FCGI_PARAMS, request_id, params),
            record(FCGI_PARAMS, request_id),
        ]
        for offset in range(0, len(body), 65535):
            stream.append(record(FCGI_STDIN, request_id, body[offset : offset + 65535]))
        stream.append(record(FCGI_STDIN, request_id))

        try:
            self.process.stdin.write(b"".join(stream))
            self.process.stdin.flush()
        except BrokenPipeError as exc:
            raise GatewayError("FastCGI responder closed its input stream") from exc

        stdout = bytearray()
        stderr = bytearray()
        while True:
            version, record_type, returned_id, length, padding, reserved = struct.unpack(
                ">BBHHBB", read_exact(self.process.stdout, 8)
            )
            if version != FCGI_VERSION_1 or reserved != 0 or returned_id != request_id:
                raise GatewayError("invalid FastCGI response record")
            content = read_exact(self.process.stdout, length)
            read_exact(self.process.stdout, padding)
            if record_type == FCGI_STDOUT:
                stdout.extend(content)
            elif record_type == FCGI_STDERR:
                stderr.extend(content)
            elif record_type == FCGI_END_REQUEST:
                if len(content) != 8:
                    raise GatewayError("invalid FastCGI END_REQUEST record")
                if content[:4] != b"\0\0\0\0":
                    detail = stderr.decode(errors="replace") or "FastCGI application failed"
                    raise GatewayError(detail)
                return bytes(stdout)


def parse_cgi_response(response):
    if b"\r\n\r\n" in response:
        header_bytes, body = response.split(b"\r\n\r\n", 1)
        lines = header_bytes.split(b"\r\n")
    elif b"\n\n" in response:
        header_bytes, body = response.split(b"\n\n", 1)
        lines = header_bytes.split(b"\n")
    else:
        raise GatewayError("Gengoscript response is missing CGI headers")

    status = 200
    headers = []
    for line in lines:
        if b":" not in line:
            raise GatewayError("invalid CGI response header")
        name, value = line.split(b":", 1)
        if name == b"Status":
            try:
                status = int(value.strip().split(None, 1)[0])
            except (IndexError, ValueError) as exc:
                raise GatewayError("invalid CGI Status header") from exc
        else:
            headers.append((name.decode("ascii"), value.strip().decode("latin-1")))
    return status, headers, body


class GatewayHTTPServer(HTTPServer):
    def __init__(self, address, binary, app):
        self.gateway = FastCGIGateway(binary, app)
        super().__init__(address, GatewayRequestHandler)

    def server_close(self):
        self.gateway.close()
        super().server_close()


class GatewayRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def _handle(self):
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            if content_length < 0:
                raise ValueError
            body = self.rfile.read(content_length)
            response = self.server.gateway.request(self.command, self.path, body)
            status, headers, response_body = parse_cgi_response(response)
            self.send_response(status)
            for name, value in headers:
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(response_body)
        except (GatewayError, ValueError) as exc:
            self.send_error(502, str(exc))

    def do_GET(self):
        self._handle()

    def do_HEAD(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def do_PUT(self):
        self._handle()

    def do_PATCH(self):
        self._handle()

    def do_DELETE(self):
        self._handle()


def create_server(address, binary, app):
    return GatewayHTTPServer(address, binary, app)


def main():
    here = pathlib.Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Serve a Gengo FastCGI app over HTTP for development")
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", default=8080, type=int)
    parser.add_argument("--binary", default=here / "fastcgi_host", type=pathlib.Path)
    parser.add_argument("--app", default=here / "app.gengo", type=pathlib.Path)
    args = parser.parse_args()

    server = create_server((args.bind, args.port), args.binary, args.app)
    print(f"Gengo development server: http://{args.bind}:{server.server_port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
