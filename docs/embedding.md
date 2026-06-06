# gengo Embedding API

`runtime/api.zig` is the stable host-facing entrypoint for embedding.

## Types

- `api.Config`
- `allow_io: bool = true`
- `native_backend: vm.Policy.NativeBackend = .embedded`
- `max_ops: ?u64 = null`
- `module_sources: []const api.SourceEntry = &.{}`
- `module_source_provider: ?api.SourceProvider = null`
- `host_modules: []const api.HostModuleDesc = &.{}`
  - each entry has a module name and a slice of `HostModuleFuncDesc` (name + arity)
  - scripts import with `@module:` prefix: `mymod := import("@module:mymod")`
- `api.Runtime`
- `api.RuntimeResult`
  - `.ok`
  - `.compile_error { line: u32, kind: anyerror }`
  - `.runtime_error { kind: anyerror, line: u32, col: u16, frames: [max_frames]PanicFrame, frame_count: usize }`
- `api.RuntimeResultWithValue`
  - `.ok: Value`
  - `.runtime_error { kind: anyerror, line: u32, col: u16, frames: [max_frames]PanicFrame, frame_count: usize }`

## Lifecycle

1. `var rt = api.Runtime.init(config);`
2. `const run_res = rt.run(src);`
3. `const call_res = rt.call("fn_name", args);`
4. `rt.reset();` (optional, clears runtime state)

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
const res = rt.run("for true {}");
// res is .runtime_error with InstructionBudgetExceeded
```

## Concurrency Contract

- Isolated runtime instances are supported.
- Interleaved calls across runtimes are supported.
- Concurrent execution of multiple runtimes on different host threads is not yet supported in the current active-context model.
- `run(src)` has no source path context, so relative source imports are unavailable there.
- `runPath(src, path)` provides source path context for relative imports.
- `module_sources` and callback providers are resolved against normalized logical paths such as `app/pkg/mod.gengo`.
