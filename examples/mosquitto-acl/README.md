# Mosquitto ACL plugin

A Mosquitto (v2.x) broker plugin that delegates ACL — and optionally basic
auth — to a Gengoscript policy script. For every publish, delivery, and
(un)subscribe the broker calls:

```gengo
func acl(client string, user string, topic string, access string) bool
```

with `access` one of `read`, `write`, `subscribe`, `unsubscribe`. Any script
error denies the request (fail closed), each call runs under an instruction
budget, and `std.io.println` goes to the broker log. SIGHUP reloads the
policy; a broken replacement keeps the previous one.

The shipped `policy.gengo`: `admin` may do anything, anyone may read
`public/`, named users own `tenant/<user>/#`.

## Build & run

Needs the broker plugin headers (Debian/Ubuntu: `mosquitto-dev`).

```bash
zig build -Dpreset=dev engine-native   # repo root: builds libgengo-engine.so
cd examples/mosquitto-acl
make
mosquitto -c mosquitto.conf            # listens on 127.0.0.1:1884
```

Try it: `mosquitto_pub -p 1884 -q 1 -u alice -t tenant/alice/data -m hi`
(allowed) vs `-t tenant/bob/data` (not authorized).

## Options

| Option | Default | Meaning |
|---|---|---|
| `plugin_opt_script` | (required) | Path to the policy script |
| `plugin_opt_max_ops` | `100000` | Instruction budget per policy call |
| `plugin_opt_basic_auth` | `false` | Also route basic auth through `func auth(client, user, password)` |
