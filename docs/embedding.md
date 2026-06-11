# Gengoscript Embedding in Zig

This page covers the Zig embedding API exposed through `runtime/api.zig`.

Use this page if your host is written in Zig. For the C-compatible engine surface, see `engine-api.md`.

## Core Types

The main entry points are:

- `api.Config`
- `api.Runtime`
- `api.RuntimeResult`
- `api.RuntimeResultWithValue`

Important `api.Config` fields:

| Field | Purpose |
|---|---|
| `allow_io` | Enable or suppress `std.io` output |
| `max_ops` | Instruction budget; `null` means unlimited |
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
});
defer rt.deinit();
```

## Minimal Example

```zig
var rt = api.Runtime.init(.{ .allow_io = false });
defer rt.deinit();

switch (rt.run(
    \\pub func greet(name string) string {
    \\    return "hello " + name
    \\}
)) {
    .ok => {},
    .compile_error => |e| return e.kind,
    .runtime_error => |e| return e.kind,
}

const result = rt.call("greet", &.{
    api.Value{ .string = "world" },
});
```

Use `runPath` instead of `run` when the script uses relative imports.

## Handling Results

`run` and `call` return tagged results rather than throwing directly. In practice you usually branch on:

- `.ok`
- `.compile_error`
- `.runtime_error`

Compile errors report the source line. Runtime errors report the kind, line, column, and stack frames.

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
});
defer rt.deinit();
```

## Host Modules

Host modules are imported through `host:*` paths and must be registered explicitly.

```zig
var rt = api.Runtime.init(.{
    .host_modules = &.{.{
        .name = "host:db",
        .funcs = &.{.{ .name = "lookup", .arity = 1 }},
    }},
});
```

Use host modules when the script needs a narrow, controlled bridge into host logic.

## Capabilities

Capability modules are also opt-in:

```zig
var rt = api.Runtime.init(.{
    .allow_io = false,
    .capabilities = &.{"http", "fs"},
});
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

Use a fresh runtime when isolation is more important than reuse.

## Concurrency

Treat a runtime instance as single-threaded. Do not call into the same `api.Runtime` from multiple threads at once.

Separate runtime instances may be used independently.

## Further Reading

- `engine-api.md` for the C-compatible surface
- `host-abi.md` for the host backend ABI
- `security.md` for deployment controls and limits
