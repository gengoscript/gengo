# Capability matrix

`std` is always available; capability imports require both a build that
includes the capability and host enablement.

For script-facing imports and operations, see `capabilities.md`.

| Import | Native | WASI CLI | Browser engine | Host setup / default | Operations and security implications |
|---|---|---|---|---|---|
| `cap:fs` | Compiled by default | Native directory mounts are unavailable in the current WASI engine; virtual drivers remain host-defined | No built-in browser filesystem driver | Enable `fs` and register a directory or virtual mount; no usable mount by default | Read/write/list/delete under named mounts. Reject absolute and traversal paths; driver and symlink/race policy remain host responsibility. |
| `cap:http` | Compiled by default | Depends on host HTTP handler | No browser fetch handler is supplied automatically | Enable `http`; register HTTP handler | Outbound HTTP through host callback. Host must set redirect, DNS, private-address, timeout, and response-size policy. |
| `cap:net` | Compiled by default | Listen unsupported (no WASI accept/bind); dial depends on socket host support | No browser socket handler is supplied automatically | Enable `net=dial`, `net=listen`, or `net=dial,listen` (bare `net` = dial only, unchanged from before scopes existed); register net handlers; policy APIs can add rules | Raw networking, scoped: `dial` (outbound) and `listen` (inbound, via `net.listen`/`Listener.accept`) are independent authorities with independent policy lists. Dial has no native rules by default (all destinations allowed — restrict for untrusted code); listen defaults to deny-all (a host must add an explicit allow rule before any bind succeeds). |
| `cap:env` | Compiled by default | Environment depends on WASI runtime | Not supplied by SDK | Enable `env` (CLI: `--cap env`) and provide compatible host environment | Read-only environment access. Use `env.get(name)` to pass selected host variables to scripts, or `env.list()` only when broad exposure is intended. Allowlist names; inherited environment can contain secrets. |
| `cap:ffi` | Native CLI only (`x86_64`, `aarch64`) | Not available | Not available | Enable `ffi` (CLI: `--cap ffi`) | Load a shared library and call exported C functions. Highest-trust capability; a wrong declaration can crash the process. v1 supports scalar, float, `cstring`, and pointer args/returns only. |

The compiler rejects an unavailable capability import. A capability name alone
does not grant OS authority: the concrete handlers and mounts determine what a
script can do. `host:*` modules are not capabilities; they are explicit host
callbacks and must be reviewed as authority grants.
