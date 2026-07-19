# Gengo Function Service

A small self-hosted function service: upload Gengoscript source, assign an
exact HTTP route, and the Go host keeps its compiled function ready for future
requests. It demonstrates a practical host boundary, not a production
serverless platform.

The Go host owns HTTP parsing, authentication, request limits, source storage,
and engine lifecycle. Gengoscript owns the request behavior. Uploaded scripts
receive four strings and must return CGI-style headers followed by a body:

```gengo
pub func handle(method string, path string, query string, body string) string {
    return "Content-Type: text/plain; charset=utf-8\r\n\r\nhello from Gengo"
}
```

## Build And Run

Build the release native engine once:

```sh
zig build -Dpreset=1m engine-native-release
```

Start the service with a deployment token:

```sh
cd examples/go-function-service
make run
```

It listens at `http://127.0.0.1:8080` and stores validated source and routes
in an atomically-written `function-data/functions.json` manifest. Override the
defaults when needed:

```sh
LD_LIBRARY_PATH=../../zig-out/lib go run . \
  -listen 127.0.0.1:8090 \
  -data /var/lib/gengo-functions \
  -token "$GENGO_FUNCTION_TOKEN"
```

## Deploy A Function

`POST /v1/functions/{name}` requires `Authorization: Bearer <token>` and this
JSON body:

```json
{
  "route": "/welcome",
  "source": "... Gengoscript source ..."
}
```

Deploy the included template-rendered page with `jq`:

```sh
curl -i -X POST http://127.0.0.1:8080/v1/functions/welcome \
  -H 'Authorization: Bearer dev-token' \
  -H 'Content-Type: application/json' \
  --data "$(jq -n --rawfile source welcome.gengo '{route: "/welcome", source: $source}')"
```

Then invoke it like any route:

```sh
curl -i 'http://127.0.0.1:8080/welcome?name=Ada'
```

`make demo` runs the complete local flow with four bundled functions:

- `/welcome` renders a template-backed HTML page.
- `/request-info` echoes the method, path, query, and body it received.
- `/created` demonstrates a `201` JSON response.
- `/clock` renders the current UTC date and time with `std.time.now()`.

Each handler imports the host-provided `host:http` module and calls
`http.text`, `http.html`, or `http.json`. The module owns CGI response
formatting, so handlers produce ordinary response bodies rather than raw HTTP
headers.

An invalid source upload returns `422` and is not registered. A route already
owned by another function returns `409`. `/v1/*` and `/healthz` are reserved
for the host; `GET /healthz` returns `204`.

## Security And Limits

Each function runs in a dedicated child process of the same Go binary. The
worker links directly to `libgengo-engine`; it does not invoke the Gengo CLI.
It has no I/O capabilities, a 512 KiB heap, 2,048 objects, and a 200,000-op
budget. The host limits source and request bodies to 64 KiB, function responses
to 128 KiB, and each invocation to two seconds. A failed worker is recreated on
its next request without affecting other routes.

The host and workers use a bounded binary stdin/stdout protocol. JSON is used
only at the public HTTP deployment endpoint and in the persisted manifest.
Source is compiled before it is persisted, so a restart reloads only previously
validated functions. The manifest write is synced and atomically renamed.

This is not sufficient isolation for mutually untrusted tenants. Process
separation contains ordinary worker crashes and timeouts, but it is not an OS
sandbox. Run workers under your platform's sandboxing policy when accepting
hostile code.

Native engine active-call state is process-global within a process. One worker
owns one engine, so separate functions can execute concurrently without sharing
that state. Requests to the same function remain serialized by its worker.

## Test

```sh
make test
```

The integration tests verify authenticated upload, strict deployment input,
route invocation, rejected invalid source, safe script response headers,
source/route reload after a service restart, raw worker frame handling, and
independent worker recovery.
