# gengo Embedding API

`runtime/api.zig` is the stable host-facing entrypoint for embedding.

## Types

### `api.Config`

| Field | Type | Default | Description |
|---|---|---|---|
| `allow_io` | `bool` | `true` | Allow `std.io` output |
| `native_backend` | `vm.Policy.NativeBackend` | `.embedded` | Native dispatch backend |
| `max_ops` | `?u64` | `null` | Instruction budget; `null` = unlimited |
| `module_sources` | `[]const api.SourceEntry` | `&.{}` | In-memory source table for `import("./...")` |
| `module_source_provider` | `?api.SourceProvider` | `null` | Dynamic source callback (wins over `module_sources`) |
| `host_modules` | `[]const api.HostModuleDesc` | `&.{}` | Host-defined modules importable via `@module:` prefix |
| `capabilities` | `[]const []const u8` | `&.{}` | Enabled capability names (e.g. `&.{"http", "fs"}`) |
| `heap_size_bytes` | `usize` | preset default | Gengo heap size in bytes |
| `max_objects` | `usize` | preset default | Maximum live GC objects |
| `max_stack` | `usize` | preset default | VM value stack depth |
| `max_frames` | `usize` | preset default | Call frame limit |
| `max_defers` | `usize` | preset default | Defer stack depth |
| `allocator` | `std.mem.Allocator` | `page_allocator` | Allocator for per-instance backing memory (native only) |

### Other types

- `api.Runtime`
- `api.RuntimeResult`
  - `.ok`
  - `.compile_error { line: u32, kind: anyerror }`
  - `.runtime_error { kind: anyerror, line: u32, col: u32, frames: [max_frames]PanicFrame, frame_count: usize }`
- `api.RuntimeResultWithValue`
  - `.ok: Value`
  - `.runtime_error { kind: anyerror, line: u32, col: u32, frames: [max_frames]PanicFrame, frame_count: usize }`

## Lifecycle

1. `var rt: api.Runtime = undefined; rt.initWithPolicy(config);`  (or `api.Runtime.init(config)`)
2. `const run_res = rt.run(src);`
3. `const call_res = rt.call("fn_name", args);`
4. `rt.reset();` — optional; clears globals, heap, and call stack so the handle can run a fresh script
5. `rt.deinit();` — frees per-instance backing memory; required when using a custom `allocator`

If the embedded script should be allowed to resolve relative source imports, use `rt.runPath(src, "path/to/root.gengo")` instead of `rt.run(src)`.

For non-filesystem embeddings there are two host-loading options:
- `module_sources`: a fixed in-memory source table keyed by canonical logical path
- `module_source_provider`: a callback provider for dynamic lookup

If both are set, `module_source_provider` wins.

## Native Host Example

Build and run the native Zig embedding example:

```bash
zig build -Dpreset=dev embed-example
```

Source:
- `embed_host_example.zig`

## Examples

Run script:

```zig
var rt = api.Runtime.init(.{ .allow_io = false });
switch (rt.run("x := 1")) {
    .ok => {},
    .compile_error => |e| { /* e.line, e.kind */ },
    .runtime_error => |e| { /* e.kind, e.line, e.col, e.frames[0..e.frame_count] */ },
}
```

Run with a root path so `import("./relative")` works:

```zig
switch (rt.runPath(
    \\math := import("./math")
    \\answer := math.add(20, 22)
, "scripts/main.gengo")) {
    .ok => {},
    .compile_error => |e| { /* e.line, e.kind */ },
    .runtime_error => |e| { /* e.kind, e.line, e.col */ },
}
```

Call function repeatedly:

```zig
_ = rt.run(
    \\counter := 0
    \\func bump() int { counter += 1; return counter }
);
_ = rt.call("bump", &[_]Value{});
_ = rt.call("bump", &[_]Value{});
```

Run with an in-memory source table:

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

switch (rt.runPath(
    \\pkg := import("./pkg")
    \\func read() int { return pkg.answer() }
, "app/main.gengo")) {
    .ok => {},
    .compile_error => |e| { /* ... */ },
    .runtime_error => |e| { /* ... */ },
}
```

Run with a host callback provider:

```zig
const SourceSet = struct {
    entries: []const api.SourceEntry,
};

fn loadSource(ctx: *anyopaque, path: []const u8) anyerror!?[]const u8 {
    const set: *const SourceSet = @ptrCast(@alignCast(ctx));
    for (set.entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry.source;
    }
    return null;
}

const entries = [_]api.SourceEntry{
    .{
        .path = "mem/math.gengo",
        .source =
            \\pub func add(a int, b int) int {
            \\    return a + b
            \\}
        ,
    },
};
const set = SourceSet{ .entries = &entries };

var rt = api.Runtime.init(.{ .allow_io = false });
switch (rt.runPathWithSourceProvider(
    \\math := import("./math")
    \\func read() int { return math.add(20, 22) }
, "mem/main.gengo", .{
    .callback = .{
        .ctx = @constCast(&set),
        .load = loadSource,
    },
})) {
    .ok => {},
    .compile_error => |e| { /* ... */ },
    .runtime_error => |e| { /* ... */ },
}
```

Enforce operation budget:

```zig
var rt = api.Runtime.init(.{ .allow_io = false, .max_ops = 10000 });
const res = rt.run("for {}");
// res is .runtime_error with InstructionBudgetExceeded
```

## Capabilities

Scripts can access system capabilities (`@cap:http`, `@cap:fs`, `@cap:net`) only when the host enables them. Pass capability names in `api.Config.capabilities`:

```zig
var rt: api.Runtime = undefined;
rt.initWithPolicy(.{
    .allow_io = true,
    .capabilities = &.{ "http", "fs" },
});
```

### HTTP capability handler

By default the native CLI provides a built-in HTTP implementation. For embedding, register a custom handler via `http_state.setHttpHandler` to route HTTP calls through your own networking stack:

```zig
const http_state = @import("lang/native/http_state.zig");

fn myHttpFetch(
    req: *const http_state.GengoHttpRequest,
    out: *http_state.GengoHttpResponse,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    _ = userdata;
    // populate out.status, out.body, out.body_len, out.headers
    out.status = 200;
    const body = "hello";
    out.body = body.ptr;
    out.body_len = @intCast(body.len);
    out.headers = .{ .keys = null, .values = null, .count = 0 };
    return 0; // 0 = success; negative = network error
}

http_state.setHttpHandler(&myHttpFetch, null);
```

`GengoHttpRequest` fields:

| Field | Type | Description |
|---|---|---|
| `method` | `[*:0]const u8` | HTTP method (null-terminated) |
| `url` | `[*:0]const u8` | Full URL (null-terminated) |
| `body` | `[*]const u8` | Request body bytes (may be empty) |
| `body_len` | `c_int` | Length of `body` in bytes |
| `headers` | `GengoHttpHeaders` | Request headers |
| `timeout_ms` | `i64` | Timeout in ms; `0` = no timeout |

### Net capability handlers

For `@cap:net`, register a `GengoNetHandlers` struct with all socket-level callbacks:

```zig
const net_state = @import("lang/native/net_state.zig");

const handlers = net_state.GengoNetHandlers{
    .dial   = myDial,
    .read   = myRead,
    .write  = myWrite,
    .close  = myClose,
    .local_addr    = myLocalAddr,
    .remote_addr   = myRemoteAddr,
    .set_deadline       = mySetDeadline,
    .set_read_deadline  = mySetReadDeadline,
    .set_write_deadline = mySetWriteDeadline,
};
net_state.setNetHandlers(handlers, null);
```

If no handler is registered the built-in POSIX socket implementation is used on native targets; on WASM `CapabilityNotAvailable` is raised.

## Concurrency Contract

- Isolated runtime instances are supported.
- Interleaved calls across runtimes are supported.
- Concurrent execution of multiple runtimes on different host threads is not yet supported in the current active-context model.
- `run(src)` has no source path context, so relative source imports are unavailable there.
- `runPath(src, path)` provides source path context for relative imports.
- `module_sources` and callback providers are resolved against normalized logical paths such as `app/pkg/mod.gengo`.
