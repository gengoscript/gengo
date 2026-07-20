# Gengoscript Security Model

This page describes the security boundary Gengoscript is designed to provide and the controls a host should use when running untrusted scripts.

## Threat Model

Gengoscript assumes:

- scripts are untrusted;
- the host application is trusted; and
- denial of service is in scope.

Gengoscript is a language-level isolation boundary, not an operating-system sandbox. A script runs inside the Gengoscript VM, not in a separate process. For higher-risk deployments, run `gengo-engine.wasm` inside a WebAssembly runtime as an additional isolation layer.

## What Scripts Cannot Do by Default

Without explicit host opt-in, a script cannot:

- read or write the filesystem;
- open network connections;
- spawn processes;
- read environment variables;
- call host functions that were not registered; or
- import modules that were not made available.

`std` is the only built-in import. It provides language utilities and does not grant ambient access to the machine.

## Instruction Budget

Each VM opcode decrements a counter. When the counter reaches zero, execution stops with `error.InstructionBudgetExceeded`.

```zig
var rt = api.Runtime.init(.{
    .allow_io = false,
    .max_ops = 100_000,
});
```

Set `max_ops` in production. `null` means unlimited execution and should normally be treated as a development setting.

## Resource Limits

In addition to the instruction budget, the engine enforces hard limits on memory and call depth.

| Field | What it limits |
|---|---|
| `heap_size_bytes` | Total Gengoscript heap |
| `max_objects` | Live GC object count |
| `max_stack` | VM value stack depth |
| `max_frames` | Call frame depth |
| `max_defers` | Deferred call depth |

These limits come from the active build preset and may be tightened per instance.

| Preset | Heap | Intended use |
|---|---|---|
| `256k` | 256 KiB | Constrained embedded targets |
| `1m` | 1 MiB | Default — CLI and general scripting |
| `16m` | 16 MiB | Production embedding / large workloads |
| `unlimited` | 256 MiB | No practical limits |

The heap allocator's largest block size scales with the configured heap
(capped at heap/8, floor 64 KiB), so the `16m` preset lifts the
single-allocation ceiling to 2 MiB.

## Capability Modules

System access is opt-in through capability modules:

| Capability | Import path | Purpose |
|---|---|---|
| `http` | `cap:http` | Outbound HTTP |
| `fs` | `cap:fs` | Filesystem access through named mounts |
| `net` | `cap:net` | Raw network operations |
| `env` | `cap:env` | Read-only process environment access |

Enabling one capability does not enable the others.

The full target and host-registration inventory is `capability-matrix.md`.
In particular, `cap:env` can expose inherited secrets: enable it only with a
host-side allowlist. `cap:http` and `cap:net` callbacks are host authority;
use default-deny address, port, redirect, timeout, and response-size policies
for untrusted scripts. The VM operation budget does not account for time spent
inside host callbacks.

For `cap:fs`, scripts can only reach host-registered mounts. Absolute paths and path traversal are rejected before any syscall.

### Network and HTTP policy

Do not enable `cap:http` or `cap:net` for untrusted scripts with an implicit
allow-all policy. In particular, the current native network dial policy allows
all destinations when it has no rules. The host must provide the restriction;
the VM cannot infer a safe destination from a URL or address string.

A restrictive policy should, at minimum:

- start deny-by-default and allow only required schemes, hostnames/IP ranges,
  and ports;
- resolve and validate every destination address, including IPv4 and IPv6,
  and reject loopback, link-local, private, and other internal ranges unless
  explicitly required;
- validate redirect destinations with the same policy, and account for DNS
  rebinding by validating the address used for each connection;
- set connect, read, write, and total-request timeouts; cap request and
  response sizes; and limit redirect count; and
- treat HTTP status as application data, not proof that the destination or
  response is trustworthy.

These controls defend against SSRF and data exfiltration. They also prevent a
small number of VM instructions from causing a long blocking host operation.
The instruction budget does not interrupt a running HTTP or socket callback.

### Filesystem policy

Mount names restrict the script-visible path syntax, but they are not a
complete filesystem sandbox. The host or filesystem driver remains responsible
for symlink escape, time-of-check/time-of-use races, device files, recursive
enumeration, quotas, and per-file or total-size limits. Prefer a dedicated,
read-only directory or a virtual driver for untrusted read-only workloads.
Do not mount a writable application, configuration, or credential directory
merely because path traversal is rejected.

### Environment policy

`cap:env` is read-only but can disclose credentials, tokens, proxy settings,
and deployment metadata inherited by the host process. Prefer passing one
specific non-secret value through `env.get`, or better, through a narrowly
designed `host:` function. Do not expose `env.list()` to untrusted scripts
when the process environment contains secrets. WASI and native hosts can have
different inherited environments; review them independently.

## Import Sandboxing

When the CLI runs a script, file imports are restricted to the script's own directory. Any `import` that would resolve outside that directory is rejected at compile time with `ImportOutsideRoot`:

```
gengo: compile error: ImportOutsideRoot: import '../shared/utils' is outside the allowed source directories
```

Additional directories can be whitelisted with `--modules` (repeatable):

```bash
gengo --modules /app/lib script.gengo
```

Embedded runtimes created through the Zig API are unrestricted unless `source_root` is configured explicitly in the `Config`. `.table` and `.callback` source providers bypass filesystem resolution entirely and are unaffected by this restriction.

## Host Modules

Host-defined modules are imported through `host:` paths such as `import("host:db")`. Scripts can call only the functions the host explicitly registers.

Host functions run in ordinary host code, outside the VM instruction budget. They should therefore be treated as trusted integration points and kept fast and predictable.

Host callbacks should enforce their own input-size, timeout, allocation, and
concurrency limits. They must not assume that a bounded VM operation count
means a bounded amount of host work. Treat callback re-entry into the same
engine as an advanced integration case and follow the ownership and reentry
rules in `host-abi.md`; independent engine instances are not an
operating-system isolation boundary against memory-unsafe native code or a
malicious callback.

## Instance Isolation

Each runtime instance has its own heap, globals, stack, and call frames. Errors, panics, or budget exhaustion in one instance do not affect another instance.

## Output Control

Set `allow_io = false` unless scripts should be able to write through `std.io`:

```zig
var rt = api.Runtime.init(.{ .allow_io = false });
```

This suppresses built-in script output only. It does not prevent host callbacks from performing I/O.

## Confusable Identifiers

Unicode identifiers are not normalized. Two identifiers that look identical but are composed differently (for example, NFC vs NFD) are treated as distinct names. This creates the same confusable-identifier risk as Go. Review scripts that accept untrusted source code, and consider running them through a normalizing preprocessor if visual spoofing is a concern.

## Deployment Checklist

For production use:

- set a finite `max_ops`;
- choose appropriate memory and frame limits;
- disable `std.io` unless it is required;
- enable only the capabilities the use case needs;
- register only the host functions the script should be allowed to call;
- set `source_root` (and optionally `module_roots`) in the embedding config to restrict which files scripts can import; and
- apply explicit deny-by-default network/HTTP policy, timeout, and response-size limits before enabling `cap:http` or `cap:net`;
- use dedicated read-only or virtual filesystem mounts, with host-side size and symlink policy, before enabling `cap:fs`;
- avoid `cap:env` for untrusted scripts unless the supplied environment is intentionally safe to disclose; and
- use a WebAssembly sandbox or separate OS process as defence in depth for higher-risk deployments.
