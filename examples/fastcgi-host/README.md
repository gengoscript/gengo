# Gengo FastCGI Host

A small native FastCGI responder that preloads a Gengoscript application and
calls one exported function for each request. It is suitable as a concrete
starting point for `spawn-fcgi`, Apache `mod_proxy_fcgi`, or another FastCGI
process manager.

## Contract

`app.gengo` must export this function:

```gengo
pub func handle(method string, path string, query string, body string) string
```

All arguments are strings. `handle` returns the complete CGI-style response:
optional `Status`, response headers, a blank line, then the body. The example
application returns an HTML page rendered by its precompiled internal
`std.template` template.

The example compiles its template once while the application is loaded, then
calls `Template.execute` for each request. Request-derived values are escaped
before interpolation because `std.template` renders text and does not perform
HTML escaping itself.

The host preloads and compiles the application once. It then reads FastCGI
records from standard input and writes records to standard output. It supports
one request at a time, including fragmented `PARAMS` and `STDIN` streams. It
does not grant Gengoscript `cap:io`; the handler receives the request body as
an explicit argument.

Limits are deliberately explicit: `PARAMS` are limited to 16 KiB and request
bodies to 64 KiB. Larger requests receive a 500 response. The engine has a
512 KiB heap and a 200,000-op instruction budget per script call.

## Build

Build the native engine, then the responder:

```sh
zig build -Dpreset=1m engine-native-release
cd examples/fastcgi-host
make
```

`fastcgi_host` accepts an optional application path:

```sh
./fastcgi_host /srv/gengo/app.gengo
```

Configure the FastCGI process manager to execute that command. The manager
owns the listening socket; this program speaks the FastCGI protocol through
its standard input and output. Do not put diagnostics on stdout: it is the
FastCGI response stream.

## Test

The protocol test constructs a fragmented POST request, runs the responder,
and verifies the returned FastCGI records and response:

```sh
make test
```

## Python Development Server

For local HTTP development, the included standard-library gateway keeps one
`fastcgi_host` process alive and exposes it on localhost:

```sh
python3 serve.py
curl -i 'http://127.0.0.1:8080/hello?name=Ada'
```

It is deliberately a development server: requests are serialized and it does
not provide TLS, process supervision, or production hardening. Use a real
FastCGI process manager and web server in production.

## Concurrency

This host is intentionally sequential. The current native engine uses
process-global active I/O and capability callback state while a call is
running, so concurrent `engine_call` invocations are not safe. Run multiple
FastCGI worker processes for parallelism. Moving that state into each engine
instance, or making it thread-local, is required before adding threads here.
