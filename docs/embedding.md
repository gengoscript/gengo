# gengo Embedding API

`runtime/api.zig` is the stable host-facing entrypoint for embedding.

## Types

- `api.Config`
  - `allow_io: bool = true`
  - `native_backend: vm.Policy.NativeBackend = .embedded`
  - `max_ops: ?u64 = null`
- `api.Runtime`
- `api.RuntimeResult`
  - `.ok`
  - `.compile_error { line, kind }`
  - `.runtime_error { kind }`
- `api.RuntimeResultWithValue`
  - `.ok: Value`
  - `.runtime_error { kind }`

## Lifecycle

1. `var rt = api.Runtime.init(config);`
2. `const run_res = rt.run(src);`
3. `const call_res = rt.call("fn_name", args);`
4. `rt.reset();` (optional, clears runtime state)

## Examples

Run script:

```zig
var rt = api.Runtime.init(.{ .allow_io = false });
switch (rt.run("x := 1")) {
    .ok => {},
    .compile_error => |e| { /* e.line, e.kind */ },
    .runtime_error => |e| { /* e.kind */ },
}
```

Call function repeatedly:

```zig
_ = rt.run(
    \\counter := 0
    \\func bump() { counter += 1; return counter }
);
_ = rt.call("bump", &[_]Value{});
_ = rt.call("bump", &[_]Value{});
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
