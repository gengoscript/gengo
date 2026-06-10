# Security model

Gengo is designed to run untrusted or user-supplied scripts inside a host application. This document describes what the engine guarantees, what it does not guarantee, and how to configure it for safe embedding.

---

## Threat model

Gengo assumes the following:

- **Scripts are untrusted.** A script may be written by an end user, loaded from external storage, or supplied by a third party. It should not be able to harm the host process, read sensitive data, or exhaust host resources.
- **The host is trusted.** The application embedding Gengo controls what scripts are allowed to see and do. Any capability the host does not explicitly register is unavailable to scripts.
- **Denial of service is in scope.** A runaway script — infinite loop, deep recursion, excessive allocation — should be stoppable without killing the host process.

Gengo does **not** provide OS-level isolation. It is not a sandbox in the container or seccomp sense. It is a language-level isolation boundary: scripts run in the Gengo VM, not in a separate process or memory-protected region. A bug in the VM itself could allow a script to affect host memory. For defence-in-depth in high-risk deployments, run the WASM engine inside a WASM sandbox (Wasmtime, WasmEdge, etc.).

---

## What a script can never do

Without explicit host opt-in, a script cannot:

- Read or write the filesystem
- Open network connections
- Spawn processes
- Access environment variables
- Allocate memory outside its configured heap
- Call any function not registered by the host
- Import any module not provided by the host

There is no ambient global namespace. `std` is the only built-in import, and it is a library of pure utilities (math, strings, JSON, time, etc.) with no I/O side effects beyond what the host permits through `allow_io`.

---

## Instruction budget

Every VM opcode decrements a counter. When the counter reaches zero the engine halts with `error.InstructionBudgetExceeded` and returns control to the host.

```zig
var rt = api.Runtime.init(.{
    .allow_io = false,
    .max_ops = 100_000,
});
const result = rt.run(user_script);
switch (result) {
    .runtime_error => |e| {
        if (e.kind == error.InstructionBudgetExceeded) {
            // script ran too long — safe to discard and continue
        }
    },
    else => {},
}
```

**What counts as an instruction:** every bytecode opcode — arithmetic, comparisons, loads, stores, calls, loop iterations, field accesses. A tight loop increments the counter once per iteration.

**Choosing a budget:** a budget of `100_000` is enough for non-trivial validation logic and completes in under a millisecond on modern hardware. For transformation pipelines processing large collections, `1_000_000` or higher is more appropriate. Profile with `null` (unlimited) first, then set a ceiling with headroom.

**`null` means unlimited.** The default is no budget. Always set `max_ops` in production.

---

## Resource limits

In addition to the instruction budget, the engine enforces hard limits on memory and call depth. These are set at build time through presets and can be overridden per instance via `api.Config`.

| Field | What it limits | Threat it addresses |
|---|---|---|
| `heap_size_bytes` | Total Gengo heap in bytes | Unbounded allocation |
| `max_objects` | Live GC object count | Object graph exhaustion |
| `max_stack` | VM value stack depth | Stack overflow via expression depth |
| `max_frames` | Call frame depth | Infinite recursion |
| `max_defers` | Defer stack depth | Deferred call accumulation |

When any limit is exceeded, the engine returns a runtime error. The host process is not affected.

**Build presets** select a pre-tuned combination of these limits:

| Preset | Intended use |
|---|---|
| `dev` | Development and testing; generous limits |
| `tiny` | Constrained embedding; tight heap and stack |
| `stress` | Reduced limits for edge-case testing |

For production embedding, `tiny` or a custom per-instance config is appropriate. Example:

```zig
var rt: api.Runtime = undefined;
rt.initWithConfig(.{
    .allow_io        = false,
    .max_ops         = 50_000,
}, heap_size, max_objects, max_stack, max_frames, max_defers, allocator);
```

---

## Capability modules

System access is opt-in through named capability modules. A script that imports `cap:http` will fail at compile time unless the host has enabled the `"http"` capability.

```zig
// Host enables only the capabilities it intends to allow
var rt = api.Runtime.init(.{
    .allow_io    = false,
    .max_ops     = 50_000,
    .capabilities = &.{"http"},  // net and fs remain unavailable
});
```

Available capability modules:

| Name | What it exposes |
|---|---|
| `http` | Outbound HTTP requests (`cap:http`) |
| `net` | Raw TCP/UDP socket operations (`cap:net`) |
| `fs` | Local filesystem access via `fs.local.*` (`cap:fs`) |

Capabilities are additive and opt-in. Enabling `"http"` does not enable `"net"` or `"fs"`.

For `cap:net` and `cap:http`, the host can register per-call handlers that intercept and allow or deny individual requests before they execute. See [embedding.md](embedding.md) for the handler interface.

---

## Host modules

The host can expose named functions to scripts via `host:` imports. Scripts can only call functions the host explicitly registers. There is no reflection, no dynamic function lookup, and no way for a script to discover what host functions exist beyond what it successfully imports.

```zig
// Only lookup_category is available to scripts; nothing else from the host
var rt = api.Runtime.init(.{
    .host_modules = &.{.{
        .name  = "host:db",
        .funcs = &.{.{ .name = "lookup_category", .arity = 1 }},
    }},
});
```

Host function implementations run outside the Gengo VM, in normal host code. They are not subject to the instruction budget. A host function that blocks or loops infinitely will block the VM thread. Host functions should be fast and non-blocking.

---

## Instance isolation

Each `api.Runtime` instance has its own heap, value stack, globals table, and frame state. Instances do not share memory or state. A script error, panic, or budget exhaustion in one instance does not affect any other.

After a runtime error, call `rt.reset()` to clear state and reuse the instance for a new script without reallocating. After a compile error, no VM state is modified and the instance is ready to use immediately.

---

## I/O control

`allow_io` controls whether `std.io` functions produce output. Set it to `false` in any context where scripts should not be able to write to stdout/stderr.

```zig
var rt = api.Runtime.init(.{ .allow_io = false });
```

This does not affect host module calls — a host function can still perform I/O. It only suppresses the built-in `std.io` output path.

---

## Summary checklist

For a production embedding:

- [ ] Set `allow_io = false` unless scripts should produce output
- [ ] Set `max_ops` to a finite value
- [ ] Choose a preset or set explicit resource limits (`heap_size_bytes`, `max_objects`, `max_stack`, `max_frames`)
- [ ] Enable only the capability modules the use case requires
- [ ] Register only the host functions scripts are permitted to call
- [ ] Handle `error.InstructionBudgetExceeded` and resource-limit errors at the call site
- [ ] For high-risk deployments, run `gengo-engine.wasm` inside a WASM runtime for OS-level isolation
