# Gengoscript Embedding in Zig

This page covers the Zig embedding API exposed through `runtime/api.zig`.

Use this page if your host is written in Zig. For the C-compatible engine surface, see `engine-api.md`.

## Core Types

The main entry points are:

- `api.Config`
- `api.Runtime`
- `api.RuntimeResult`
- `api.RuntimeResultWithValue`

Values passed to and returned from the runtime use the `Value` type from
`lang/value.zig`, imported separately:

```zig
const Value = @import("lang/value.zig").Value;
```

Important `api.Config` fields:

| Field | Purpose |
|---|---|---|
| `allow_io` | Enable or suppress `std.io` output |
| `native_backend` | `.embedded` (default) or `.host` (WASM/callback mode) |
| `max_ops` | Instruction budget; `null` means unlimited |
| `enable_predicates` | Enable `predicate` clause on named types (default `true`) |
| `host_modules` | Host-defined modules available through `host:*` imports |
| `capabilities` | Enabled capability names such as `"http"` or `"fs"` |
| `module_sources` | In-memory source table for relative imports |
| `module_source_provider` | Dynamic source callback |
| `heap_size_bytes` | Per-instance heap limit |
| `max_objects` | Live object limit |
| `max_stack` | VM value stack limit |
| `max_frames` | Call frame limit |
| `max_defers` | Deferred-call limit |
| `allocator` | Backing allocator for native instances |

## Lifecycle

The usual lifecycle is:

1. initialise a runtime;
2. run a script;
3. call exported functions as needed;
4. reset the runtime if you want to reuse it; and
5. deinitialise it when finished.

```zig
var rt = api.Runtime.init(.{
    .allow_io = false,
    .max_ops = 100_000,
}) catch return;
defer rt.deinit();
```

## Minimal Example

```zig
var rt = api.Runtime.init(.{ .allow_io = false }) catch return;
defer rt.deinit();

switch (rt.run(
    \\pub func add(a int, b int) int {
    \\    return a + b
    \\}
)) {
    .ok => {},
    .compile_error => |e| return e.kind,
    .runtime_error => |e| return e.kind,
}

const result = rt.call("add", &.{
    .{ .int = 40 },
    .{ .int = 2 },
});
```

Use `runPath` instead of `run` when the script uses relative imports.

## Handling Results

`run` and `call` return tagged results rather than throwing directly. In practice you usually branch on:

- `.ok`
- `.compile_error`
- `.runtime_error`

Compile errors report the source line, column, kind, and message. Runtime errors report the kind, line, column, message, and stack frames.

## Relative Imports

If scripts import sibling modules, use one of these approaches:

- `module_sources` for a fixed in-memory source table; or
- `module_source_provider` for dynamic lookup.

`module_source_provider` takes precedence when both are present.

Example with `module_sources`:

```zig
const sources = [_]api.SourceEntry{
    .{
        .path = "app/pkg/mod.gengo",
        .source =
            \\pub func answer() int {
            \\    return 42
            \\}
        ,
    },
};

var rt = api.Runtime.init(.{
    .allow_io = false,
    .module_sources = &sources,
}) catch return;
defer rt.deinit();
```

## Capabilities

Capability modules are also opt-in:

```zig
var rt = api.Runtime.init(.{
    .allow_io = false,
    .capabilities = &.{"http", "fs"},
}) catch return;
```

Current public capabilities:

- `"http"`
- `"fs"`
- `"net"`

### Filesystem Mounts

`cap:fs` can only reach host-registered named mounts:

```zig
try api.setFsMounts(&.{
    .{ .name = "data", .real = "/var/app/data" },
    .{ .name = "out", .real = "/tmp/app-out" },
});
```

Without mounts, enabling `"fs"` grants no usable filesystem access.

### HTTP Handler

For custom HTTP behaviour, register a handler through `http_state.setHttpHandler`:

```zig
const http_state = @import("lang/native/http_state.zig");
http_state.setHttpHandler(&myHttpFetch, null);
```

### Net Handlers

For `cap:net`, register a `GengoNetHandlers` struct that supplies the socket callbacks your host wants to support.

## Reuse and Reset

Call `rt.reset()` when you want to discard globals, heap state, and call frames but keep the runtime allocation itself.

For REPL-style incremental execution without resetting globals, use
`rt.runIncremental(src)` — each call compiles and executes the snippet in the
same global scope as previous calls.

Use a fresh runtime when isolation is more important than reuse.

## Request-Loop Pattern

A common embedding pattern is a long-lived runtime that loads a script once and
then calls exported functions repeatedly — once per request, event, or policy
check. The script stays loaded for the lifetime of the runtime; each `call()`
invocation runs against the same globals without reloading bytecode.

```zig
var rt = api.Runtime.init(.{
    .allow_io = false,
    .max_ops = 100_000,
}) catch return;
defer rt.deinit();

// Load the business-logic script once at startup.
const setup = rt.run(
    \\pub func allow_update(age int, score int,
    \\                       active bool, verified bool,
    \\                       limit int) bool {
    \\    return active and verified and age >= 18 and score < limit
    \\}
);
switch (setup) {
    .ok => {},
    else => return,
}

// In a request loop, call the loaded function directly.
// No reset() here — the function and its bytecode stay loaded.
while (try nextRequest(&req)) {
    const result = rt.call("allow_update", &.{
        .{ .int = req.age },
        .{ .int = req.score },
        .{ .boolean = req.active },
        .{ .boolean = req.verified },
        .{ .int = req.limit },
    });
    switch (result) {
        .ok => |v| handleDecision(v.boolean),
        .runtime_error => |e| {
            logError("policy error: {s} at line {d}\n", .{ e.msg, e.line });
            handleDecision(false);
        },
    }
}
```

`reset()` clears the entire runtime state — globals, heap, and bytecode — which
removes loaded functions. Only call it when you want to unload the current script
and start fresh. For per-request isolation without shared globals, use a separate
runtime instance per request instead.

## Host Modules

Host modules are imported through `host:*` paths and must be registered
explicitly.

```zig
var rt = api.Runtime.init(.{
    .host_modules = &.{.{
        .name = "host:db",
        .functions = &.{.{ .name = "lookup", .arity = 1, .call_id = 0 }},
    }},
}) catch return;
```

Use host modules when the script needs a narrow, controlled bridge into host
logic.

### Host Module Constraints

**Host modules require a callback-capable backend.** The `api.Runtime` Zig
surface uses `native_backend = .embedded` by default, which does **not**
provide a callback mechanism for host modules. If you register a host module
and the script calls it, the VM will raise `HostNativeUnsupported`.

Host modules only work when the runtime is compiled with
`native_backend = .host`, which is the mode used by the WASM/C-compatible
engine surface (`engine-api.md`). In that mode, the host registers a callback
function that the VM invokes through the `gengo_host` import.

If you are embedding from Zig and want script-to-host communication, the
supported path is to run the script, then call back into the host from the
result value, or use `std.io` hooks to capture output.

### Host Module Failure Modes

When a host module function is called, the host callback can return one of four
failure codes:

| Status | Error raised |
|---|---|
| `unsupported` | `HostNativeUnsupported` — host does not implement this call ID |
| `denied` | `PermissionDenied` — host refused the call |
| `bad_args` | `HostNativeBadArgs` — host rejected the argument types |
| `failed` | `HostNativeFailed` — host callback failed internally |

These are runtime errors that the embedding code should handle like any other
`runtime_error` result.

## Call Boundary Types

The `api.Runtime.call()` method accepts `[]const Value`. From the Zig host
side, scalar values are directly constructable:

```zig
const result = rt.call("score", &.{
    .{ .int = 42 },
    .{ .boolean = true },
    .{ .null },
});
```

Constructable tags: `.int`, `.float`, `.decimal`, `.rune`, `.boolean`,
`.null`. String values can be constructed but require a `*const StringSlice`
pointer (use `chunk.internStr` or a persistent `StringSlice` local).

The `Value` type also has an `.object` variant used for arrays, maps, structs,
closures, and named types, but constructing one requires a live GC-managed
pointer from inside the VM heap. There is no public API to allocate objects from
outside the runtime. If a script needs to receive a complex value (a config map,
a record), the two supported approaches are:

- **Script-side initialisation** — run a setup script that builds the object and
  stores it in a global; then call a function that reads that global.
- **Serialise to JSON** — pass a JSON string and let the script call
  `std.json.parse`.

Return values from `call()` may be objects (arrays, maps, structs, etc.);
reading their contents from the Zig side is supported through the `Value` union.
For string results, check both the `.string` variant (`v.string.bytes`) and the
`.object` variant (`v.object.dyn_string` or `v.object.string_view.bytes`) since
the VM may return short strings as interned slices and long strings as dynamic
allocations.

The **host-module wire boundary** is more restricted. Values are serialised into
`ValueWire` structs (scalar tag + payload + length) before crossing to the host
callback. The wire format supports:

- `null`, `boolean`, `int`, `float`, `rune`, `decimal`
- `string` (including dyn strings)
- `error` (message string)
- `array` of any wire-supported element
- `map` with string keys and wire-supported values
- `variant` (converted to a map with `tag` and `value` fields)

Values that are **not** supported across the host wire boundary:

- `named_value` — named types are unwrapped to their raw value
- `struct_instance` — structs are not serialised
- `function` / `closure` — functions cannot cross the wire
- `enum_value` — enum values are not serialised

If a script passes an unsupported value to a host module, the VM will raise
`UnsupportedHostValueType`.

## Concurrency

Treat a runtime instance as single-threaded. Do not call into the same
`api.Runtime` from multiple threads at once.

Separate runtime instances may be used independently.

## Further Reading

- `engine-api.md` for the C-compatible surface
- `host-abi.md` for the host backend ABI
- `security.md` for deployment controls and limits
