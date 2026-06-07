# Gengo (言語)

Gengo is an embeddable sandboxed scripting engine. You write the host application. Your users write Gengo scripts. The engine runs those scripts in a controlled environment where you decide what they can see, call, and consume.

**[Try it in the browser](https://gengoscript.github.io/gengo/)**

*Early stage. Language and runtime are still being tightened; breaking changes are expected.*

---

## The problem it solves

You want users to define logic — validation rules, transformation pipelines, policy decisions, configuration behavior — without shipping a new binary every time the rules change and without trusting arbitrary code with your process.

The usual answers are: embed Lua (good runtime, weak types), embed Python (too heavy, no isolation), write a DSL (expensive, limited), or use JSON/YAML (not a language). Gengo is a fourth option: a small scripting VM with a type system designed for domain constraints, a hard execution budget, isolated instances, and WASM as a first-class deployment target.

---

## What makes it different

**Constrained execution.** Every engine instance runs under a configurable instruction budget. Scripts that loop forever or recurse without bound are terminated, not hung. Memory limits are set at build time via presets (`dev`, `tiny`, `stress`).

**Domain-safe types.** The type system enforces constraints at the boundary, not in ad-hoc validation code:

```gengo
type Port      int range 1..65535
type Severity  int range 0..5
type EventCode int predicate func(x) { return x % 2 == 0 }

type AlertRule variant {
    threshold  Severity,
    source     string,
    Metric   { name string,  limit int },
    Webhook  { url string,   retry int },
    Discard
}
```

A script author constructing `Port(0)` or `Severity(10)` gets a runtime error at the constructor, not a silent bad value downstream. `AlertRule.Metric` values always carry valid `Severity` and `string` fields. The host never receives out-of-range data from a well-typed script.

**Host modules.** The host exposes named functions to scripts. Scripts can only call what you register. There is no ambient I/O, no filesystem, no network — unless you add it.

**Isolated instances.** Up to 64 engine instances may be live simultaneously, each with its own heap, state, and module table. One script crashing does not affect others.

**WASM-first, native too.** The engine ships as `gengo-engine.wasm` for sandboxed browser/edge deployment and as `libgengo-engine.so` for in-process native embedding. Both expose the same C API.

---

## Integration example

A host application in Zig loads a user-supplied validation script, enforces an instruction budget, and calls a function to validate a record:

```zig
const api = @import("src/runtime/api.zig");

// Host-defined function the script is allowed to call
fn lookup_category(args: []const api.Value) anyerror!api.Value {
    // ... safe lookup against host data ...
    return api.Value{ .string = "network" };
}

var rt = api.Runtime.init(.{
    .allow_io   = false,       // no println, no file access
    .max_ops    = 50_000,      // terminate runaway scripts
    .host_modules = &.{.{
        .name  = "@module:host",
        .funcs = &.{.{ .name = "lookup_category", .arity = 1 }},
    }},
});

// Load the user's script once
const result = rt.run(user_script_source);

// Call the script's exported function on each record
const verdict = rt.call("validate", &.{
    api.Value{ .number = record.severity },
    api.Value{ .string = record.source },
});
```

The user's script:

```gengo
host := import("@module:host")

type Severity int range 0..5

pub func validate(severity int, source string) bool {
    s := Severity(severity)      // enforced: 0–5 or runtime error
    cat := host.lookup_category(source)
    return s >= 3 && cat == "network"
}
```

The host never receives a severity outside 0–5 from this script. If the user writes `Severity(99)`, the engine throws before `validate` returns.

---

## Engine artifacts

Gengo ships two artifacts:

**`gengo-runtime.wasm`** — a WASI executable. Feed it a script path, get stdout/stderr back. Zero host integration required. Use this for CLI tooling, CI runners, or anywhere you want WASM sandboxing without writing embedding code.

**`gengo-engine.wasm`** — a library for programmatic embedding. The host drives execution through exported functions against WASM linear memory. Supports multiple isolated instances, typed function calls, host module registration, and in-memory source tables.

The same API is available as `libgengo-engine.so` for native in-process embedding via C FFI.

### Engine API

| Export | Description |
|---|---|
| `engine_init() → i32` | Allocate an engine instance; returns handle |
| `engine_destroy(handle)` | Free the instance |
| `engine_run(handle, src_ptr, src_len) → i32` | Compile and run a script |
| `engine_run_path(handle, src_ptr, src_len, path_ptr, path_len) → i32` | Run with a root path for relative imports |
| `engine_call(handle, name_ptr, name_len, args_ptr, argc, out_ptr) → i32` | Call a named exported function |
| `engine_reset(handle)` | Clear runtime state, reuse handle |
| `engine_add_source(handle, path_ptr, path_len, src_ptr, src_len) → i32` | Register an in-memory module |
| `engine_register_module(handle, name_ptr, name_len, funcs_ptr, funcs_count) → i32` | Register a host-defined module |
| `engine_set_write_fn(handle, callback)` | Set write callback (native target) |
| `engine_last_error(handle, out_ptr, max_len) → i32` | Retrieve last error message |
| `engine_last_error_line(handle) → i32` | Source line of last error (1-based) |
| `engine_last_error_col(handle) → i32` | Column of last error (1-based) |

Values cross the boundary as `ValueWire` — a 24-byte struct encoding null, boolean, number, string, array, and map.

See [docs/engine-api.md](docs/engine-api.md) for the full ABI reference and JavaScript helpers.

### TypeScript SDK

`sdk/typescript/` wraps `gengo-engine.wasm` with typed `GVal` encoding so you do not manipulate `ValueWire` directly:

```bash
cd sdk/typescript && npm install && npm run build
```

---

## The language

Gengo is intentionally Go-adjacent in syntax. The goal is that anyone who has read Go can read a Gengo script without a tutorial.

### Type system

The interesting part. Beyond structs, interfaces, and variants, Gengo has:

- **Named scalar types** — `type UserId string`, `type Temperature float`. Distinct types that require explicit conversion; you cannot pass a `UserId` where a plain `string` is expected.
- **Range types** — `type Port int range 1..65535`. Construction enforces the range at runtime.
- **Cyclic types** — `type Weekday int cycle 0..6`. Arithmetic wraps rather than overflows.
- **Predicate subtypes** — `type EventCode int predicate func(x) { return x % 2 == 0 }`. Arbitrary invariant enforced at construction.
- **Variant records** — variants with shared fields unconditionally accessible across all arms, plus arm-specific fields gated behind pattern matching.

These exist because a scripting engine for domain logic needs to encode domain constraints in the type system, not in validation code scattered across both sides of the host/script boundary.

### Feature summary

- structs, methods, interfaces (structural typing), enums
- variant types with single-payload and multi-field arms, variant records with shared fields
- closures with upvalue capture
- multi-return functions and named return values
- `var`/`const` with type annotations, typed arrays and maps
- `defer`, `recover`, `assert`, `trap`
- `for`, `for-in`, `switch` with pattern matching
- tail-call optimisation (self and mutual)
- in-source `test` blocks
- multi-file modules with `pub` visibility
- `std` library: `std.io`, `std.core`, `std.string`, `std.math`, `std.conv`, `std.rand`, `std.json`, `std.template`, `std.regexp`, `std.time`

---

## Quick start

```bash
# Native CLI
zig build -Dpreset=dev cli
./zig-out/bin/gengo script.gengo

# WASI runtime
zig build -Dpreset=dev wasi
wasmtime --dir . ./build/gengo-runtime.wasm -- script.gengo

# Engine WASM
zig build -Dpreset=dev engine-build
# → build/gengo-engine.wasm

# Native shared library
zig build -Dpreset=dev engine-native
# → zig-out/lib/libgengo-engine.so

# Tests
zig build -Dpreset=dev test

# Benchmarks
zig build -Dpreset=dev bench
```

Run `./zig-out/bin/gengo` with no arguments on an interactive terminal to start the REPL.

### Browser (WASI runner)

```js
import { WASI, File, OpenFile, ConsoleStdout, PreopenDirectory }
  from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.3.0/+esm";

const script = `std := import("std")
std.io.println("hello from Gengo!")`;

const enc = new TextEncoder();
const fds = [
  new OpenFile(new File([])),
  ConsoleStdout.lineBuffered(line => console.log(line)),
  ConsoleStdout.lineBuffered(line => console.error(line)),
  new PreopenDirectory(".", new Map([["script.gengo", new File(enc.encode(script))]])),
];

const wasi = new WASI(["gengo-runtime.wasm", "script.gengo"], [], fds);
const wasm = await WebAssembly.instantiateStreaming(fetch("gengo-runtime.wasm"), {
  wasi_snapshot_preview1: wasi.wasiImport,
});
wasi.start(wasm.instance);
```

---

## Build presets

| Preset | Purpose |
|--------|---------|
| `dev` | Default development limits |
| `tiny` | Tighter heap and stack limits for constrained embedding |
| `stress` | Reduced limits for edge-case testing |

Use `-Dpreset=<name>` with any build command.

---

## Repo layout

```
src/lang/         lexer, compiler, bytecode, VM
src/runtime/      heap, GC, runtime, Zig embedding API
src/engine.zig    WASM/native engine exports
examples/spec/    conformance cases (pass and fail)
examples/bench/   benchmark programs
docs/             language, stdlib, embedding, engine API, changelog
sdk/typescript/   TypeScript wrapper for gengo-engine.wasm
playground/       browser playground
```

## Toolchain

- Zig `0.16.0`
- wasmtime for WASI testing and execution

## Docs

- [docs/language.md](docs/language.md)
- [docs/stdlib.md](docs/stdlib.md)
- [docs/embedding.md](docs/embedding.md)
- [docs/engine-api.md](docs/engine-api.md)
- [docs/changelog.md](docs/changelog.md)

---

## A note on authorship

Gengo is built almost entirely with the help of LLMs. It is tested, as any present-day software should be, but this is not an artisanally hand-carved compiler lovingly shaped by a lone language monk in a candlelit workshop while listening to smooth jazz.

Expect pragmatic choices, occasional rough edges, and parts of the codebase that may look like several enthusiastic monkeys tried to type on the keyboard all at once. Because, in several ways, they did.

If software with substantial LLM involvement gives you hives, moral discomfort, or a sudden urge to rewrite everything from first principles, this project may not be for you. That is fine. For everyone else: issues, tests, bug reports, and patches are welcome.

And if you feel a pressing need to rebalance the cosmic ledger, consider donating to serious climate work instead of buying that thing you don't actually need.

That said, please do not send five commits in ten minutes, each with a single spelling fix or a style-guide preference. Small fixes are welcome, but batch them, make them useful, and expect taste calls to remain taste calls.

Judgment on what goes into this alphabet soup remains with me for now.
