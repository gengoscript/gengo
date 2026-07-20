# Capability matrix

`std` is always available; capability imports require both a build that
includes the capability and host enablement.

For script-facing imports and operations, see `capabilities.md`.

| Import | Native | WASI CLI | Browser engine | Host setup / default | Operations and security implications |
|---|---|---|---|---|---|
| `cap:fs` | Compiled by default | Native directory mounts are unavailable in the current WASI engine; virtual drivers remain host-defined | No built-in browser filesystem driver | Enable `fs` and register a directory or virtual mount; no usable mount by default | Read/write/list/delete under named mounts. Reject absolute and traversal paths; driver and symlink/race policy remain host responsibility. |
| `cap:http` | Compiled by default | Depends on host HTTP handler | No browser fetch handler is supplied automatically | Enable `http`; register HTTP handler | Outbound HTTP through host callback. Host must set redirect, DNS, private-address, timeout, and response-size policy. |
| `cap:net` | Compiled by default | Depends on socket host support | No browser socket handler is supplied automatically | Enable `net`; register net handlers; policy API can add rules | Raw networking. With no native dial-policy rules, all destinations are allowed; hosts must add an explicit restrictive policy for untrusted code. |
| `cap:env` | Compiled by default | Environment depends on WASI runtime | Not supplied by SDK | Enable `env` (CLI: `--cap env`) and provide compatible host environment | Read-only environment access. Use `env.get(name)` to pass selected host variables to scripts, or `env.list()` only when broad exposure is intended. Allowlist names; inherited environment can contain secrets. |

The compiler rejects an unavailable capability import. A capability name alone
does not grant OS authority: the concrete handlers and mounts determine what a
script can do. `host:*` modules are not capabilities; they are explicit host
callbacks and must be reviewed as authority grants.
