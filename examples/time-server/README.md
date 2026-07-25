# Time server (RFC 868)

The simplest possible demonstration of `net.listen`/`Listener.accept`: an
[RFC 868](https://www.rfc-editor.org/rfc/rfc868) Time Protocol server. A
client connects, the server writes back the current time as a single
32-bit binary number, and closes the connection — no request to parse, no
reply format beyond four bytes. Nothing about this example needs a host
embedding; both scripts run directly under the `gengo` CLI.

`time_server.gengo` binds a port and serves that protocol forever.
`check_time.gengo` is a client that connects, decodes the reply, and
prints it as a calendar time — useful for testing without reaching for
`nc`/`xxd`.

RFC 868's registered port is 37, which (like any port below 1024) requires
root on POSIX. This example binds `7370` instead so it runs without
special permission; change the port in both scripts together if you want
something else.

## Run it

`net.listen` needs both a scope grant and a policy rule — the listen
policy defaults to deny-all, deliberately the opposite of `net.dial`'s
default-allow (see `docs/security.md`).

```bash
gengo --cap net=listen --net-listen-allow "*:7370" examples/time-server/time_server.gengo
```

In another terminal:

```bash
gengo --cap net=dial examples/time-server/check_time.gengo
```

Expected output from the client:

```
server time: 2026 7 25 ...
```

The server keeps running (and printing nothing further) until you stop it
— it's written as a dedicated long-running process, the natural shape for
`gengo server.gengo` as a standalone daemon (see "Execution model" in
`dev-docs/design/net-listen-design.md`).
