# Capability modules

Capability modules are separate from `std`. An import asks the host for an
explicitly named external authority; it does not make that authority available
by itself. See `capability-matrix.md` for target availability and required host
registration.

## `cap:env`

```gengo
env := import("cap:env")
```

`cap:env` provides read-only access to host-provided environment variables.
The host must enable `env` (the CLI uses `--cap env`); otherwise the import
fails to compile. It is available to native hosts and, when supplied by the
WASI runtime, to WASI. The browser TypeScript SDK does not supply it. Treat
environment values as potentially secret.

### `env.get(name string) string|null`

Returns the named value, or `null` when it is absent. Prefer this narrow API
when a script needs a small, explicit configuration surface.

```gengo
env := import("cap:env")
region := env.get("APP_REGION") ?? "local"
```

### `env.list() [string]string`

Returns the environment as a map. It exposes every variable made available by
the host, so use it only when broad visibility is intended.

Neither function mutates the host environment. The returned strings and map
belong to the script runtime; they are not references that a host can retain.
Supplying a wrong argument count or type is a runtime error.

## `cap:fs`

```gengo
fs := import("cap:fs")
```

Filesystem access is limited to host-registered named mounts. Current
operations are listed below. A capability import does not create a mount. In
the CLI, `--mount docs=docs` permits a script to use paths such as
`"docs/capabilities.md"`.

### `fs.read(path string) string`

Reads the complete file at `path`.

### `fs.exists(path string) bool`

Returns whether `path` exists. A missing path returns `false`; mount and
other filesystem failures are runtime capability errors.

### `fs.write(path string, content string) null`

Creates or truncates the file and writes `content`.

### `fs.list(path string) [string]`

Returns entry names. The order is host/driver order and must not be relied on.

### `fs.delete(path string) null`

Deletes a file.

### `fs.mkdir(path string) null`

Creates `path`, including missing parent directories for native directory
mounts.

All filesystem functions require string paths and use the mounted path syntax;
absolute paths and traversal are rejected before the native operation. They
allocate returned strings/arrays in the script runtime and never return host
pointers. Failure to find a mount, a denied driver operation, or a native I/O
error is a runtime capability error. Native directory mounts are unavailable
to the current WASI engine; a host-provided virtual filesystem driver is the
portable alternative. Mount boundaries do not by themselves settle symlink,
race, device-file, quota, or virtual-driver trust policy.

## `cap:http`

```gengo
http := import("cap:http")
```

`cap:http` calls a host HTTP handler. The result is always two values:
`Response, null` on success or `null, error` on request failure. HTTP status
codes, including non-2xx statuses, are successful requests; inspect `resp.ok`.

### `http.get(url string) (Response|null, error|null)`

Sends a GET request.

### `http.post(url string, body string) (Response|null, error|null)`

Sends a POST request with `body`.

### `http.fetch(url string, options map) (Response|null, error|null)`

Sends a request. Recognised string-keyed options are `method` (string,
default `"GET"`), `body` (string), `timeout_ms` (integer or float, truncated
toward zero), and `headers` (a map whose string entries are passed to the
handler). Unknown keys are ignored. A wrong recognised option type is a
runtime type error.

`Response` has immutable `status` (int), `body` (string), `headers`
(`[string]string`), and `ok` (bool) fields. Its values are copied into the
script runtime. If no HTTP handler is registered, calling an HTTP function is
a runtime capability error rather than a request-result error.

```gengo
std := import("std")
http := import("cap:http")

resp, err := http.get("https://example.com/data")
if err != null {
    std.io.println("request failed:", err)
} else {
    std.io.println(resp.status, resp.ok)
}
```

## `cap:net`

```gengo
net := import("cap:net")
```

`net.dial(network string, address string) Conn|error` opens a TCP connection.
It returns an error value on refusal or connection failure.
`network` must be one of `"tcp"`, `"tcp4"`, or `"tcp6"`.

`net.dial_tls(network string, address string) Conn|error` opens a TCP connection
and performs a TLS handshake, verifying the server certificate against the OS
trust store. The returned `Conn` is transparent — `read`, `write`, and `close`
work identically to a plain `dial` connection. `network` and `address` follow
the same rules as `dial`; the server name for SNI is derived from the host part
of `address`. `dial_tls` requires the `dial` scope, the same as plain `dial`.

`dial_tls` is not available on WASM/WASI (no OS trust store) or when a host net
callback is registered; in those cases it returns an error.

`network` and `address` are passed to the host implementation; portable
scripts should not assume a particular address syntax beyond their host's
documented contract.

`Conn` values are opaque handles. Do not construct or retain their internal
state outside the engine that created them.

| Method | Result |
|---|---|
| `conn.read(max_bytes)` | string or error; `max_bytes` must be non-negative. Native POSIX reads return at most 4096 bytes per call. |
| `conn.write(data)` | number of bytes written, or error. |
| `conn.close()` | `null`; closes the handle. |
| `conn.local_addr()` | local address string. |
| `conn.remote_addr()` | remote address string. |
| `conn.set_deadline(ms)` | `null`; sets both deadlines. |
| `conn.set_read_deadline(ms)` | `null`. |
| `conn.set_write_deadline(ms)` | `null`. |

Deadline values accept integers and floats, with floats truncated toward zero.
Handle misuse and an unavailable socket host implementation are runtime
capability errors; read, write, and dial failures return error values.

The native dial policy allows all destinations when it has no rules. This is
not a safe default for untrusted scripts: hosts should install explicit deny
or allow rules and enforce DNS, IPv4/IPv6, private-address, port, timeout, and
byte limits. Read `security.md` before enabling either network capability.

### Scopes: `dial` vs `listen`

`net` is gated by scope, expressed as `--cap net=dial`, `--cap net=listen`,
or `--cap net=dial,listen` (CLI) — see `cli.md`. Dialing out and listening
for inbound connections are different authorities with different blast
radii: a listening socket is reachable by anyone who can reach the bound
port, not just destinations the script itself chose, so it isn't granted
just because dial is.

| Flag | Scopes granted |
|---|---|
| `--cap net` (bare) | `dial` only — exactly today's behavior; upgrading never silently grants listen. |
| `--cap net=dial` | `dial` only (explicit form of the above). |
| `--cap net=listen` | `listen` only — no dial. A script that can serve but cannot phone out. |
| `--cap net=dial,listen` | Both, explicit opt-in. |

The `cap:net` import succeeds as long as *some* net scope is granted; each
function is refused individually at call time if its specific scope wasn't
— the same shape as calling an `fs` operation against a path with no
matching mount.

`net.listen(network string, address string) [Listener, error]` binds and
starts listening. `network` is one of `"tcp"`, `"tcp4"`, `"tcp6"` (same
restriction as `dial`). Unlike `dial`, this returns a `[value, error]` pair
— use `l, err := net.listen(...)`.

`Listener` values are opaque handles, same rule as `Conn`.

| Method | Result |
|---|---|
| `listener.accept()` | `[Conn, error]` pair. Blocks until a connection arrives or the accept deadline elapses; with no deadline set, blocks indefinitely (safe for a dedicated long-running process — see below, not for a request-scoped handler without a deadline). |
| `listener.close()` | `null`; stops accepting and releases the bound port. |
| `listener.local_addr()` | bound address string (same shape as `conn.local_addr()`). |
| `listener.set_accept_deadline(ms)` | `null`; bounds how long `accept()` will wait. |

There is no `listener.read`/`.write` — all data I/O happens on the `Conn`
objects `accept()` hands out, using the exact same API `dial()`-produced
connections already have.

**The listen policy defaults to deny-all**, unlike dial's default-allow: a
host must affirmatively add at least one allow rule (via
`engine_net_listen_policy_add`) before `net.listen(...)` will succeed on
anything. This is a separate rule list from the dial policy — adding a dial
rule has no effect on what listen allows, and vice versa. See
`security.md`.

A typical server script owns an unbounded loop and runs as a dedicated
long-lived process (`gengo server.gengo` with `--max-ops 0`):

```gengo
net := import("cap:net")
l, err := net.listen("tcp", "0.0.0.0:8080")
if err != null {
    std.io.println("listen failed:", err)
    return
}
for {
    conn, err := l.accept()
    if err != null { continue }  // includes "timeout" if an accept deadline was set
    handle(conn)
}
```

A host embedding Gengo inside a larger process that also does other work
should instead set an accept deadline and call `accept()` repeatedly from
its own event loop, the same way the read/write deadline pattern is already
recommended for connections — nothing about "the script never returns"
requires new VM state; it's the same `for` loop primitive calling a native
function that happens to block.
