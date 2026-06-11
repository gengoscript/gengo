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
| `tiny` | 128 KiB | Constrained embedding |
| `dev` | 512 KiB | Development, short validation scripts |
| `stress` | 2 MiB | Edge-case testing |
| `server` | 16 MiB | Batch and data-processing workloads (large strings, file processing) |

The heap allocator's largest block size scales with the configured heap
(capped at heap/8, floor 64 KiB), so the `server` preset also lifts the
single-allocation ceiling to 2 MiB.

## Capability Modules

System access is opt-in through capability modules:

| Capability | Import path | Purpose |
|---|---|---|
| `http` | `cap:http` | Outbound HTTP |
| `fs` | `cap:fs` | Filesystem access through named mounts |
| `net` | `cap:net` | Raw network operations |

Enabling one capability does not enable the others.

For `cap:fs`, scripts can only reach host-registered mounts. Absolute paths and path traversal are rejected before any syscall.

## Host Modules

Host-defined modules are imported through `host:` paths such as `import("host:db")`. Scripts can call only the functions the host explicitly registers.

Host functions run in ordinary host code, outside the VM instruction budget. They should therefore be treated as trusted integration points and kept fast and predictable.

## Instance Isolation

Each runtime instance has its own heap, globals, stack, and call frames. Errors, panics, or budget exhaustion in one instance do not affect another instance.

## Output Control

Set `allow_io = false` unless scripts should be able to write through `std.io`:

```zig
var rt = api.Runtime.init(.{ .allow_io = false });
```

This suppresses built-in script output only. It does not prevent host callbacks from performing I/O.

## Deployment Checklist

For production use:

- set a finite `max_ops`;
- choose appropriate memory and frame limits;
- disable `std.io` unless it is required;
- enable only the capabilities the use case needs;
- register only the host functions the script should be allowed to call; and
- use a WebAssembly sandbox as defence in depth for higher-risk deployments.
