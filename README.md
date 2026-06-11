# Gengo (言語)

[![CI](https://github.com/gengoscript/gengo/actions/workflows/ci.yml/badge.svg)](https://github.com/gengoscript/gengo/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange?logo=zig)](https://ziglang.org/)

Domain constraints belong in the type system, not in validation code written after the fact. Gengo is a small embeddable scripting language built around that idea — a sandboxed scripting engine written in Zig that runs natively or as WebAssembly.

You write the host application. Your users write Gengo scripts. The engine runs those scripts in a controlled environment, where the host decides what scripts are allowed to see, call, and consume.

**[Try it in the browser](https://gengoscript.github.io/gengo-playground/)**

---

## Why it exists

Sometimes you want users to define logic without rebuilding or redeploying the host application every time that logic changes.

That might mean validation rules, transformation steps, policy decisions, configuration behavior, or small bits of domain-specific automation.

The usual options all have trade-offs.

Lua is small and embeddable, but its type system is loose. Python is familiar, but heavy and awkward to isolate properly. A custom DSL can fit the problem well, but costs real time to design and maintain. JSON and YAML are useful for data, but they are not programming languages.

Gengo is the option built around the last point: a small scripting VM with explicit host integration, a domain-oriented type system, hard execution limits, isolated runtime instances, and WASM as a primary target.

---

## What Gengo gives you

**Constrained execution.**
Each engine instance runs with a configurable instruction budget. A script that loops forever or recurses without bound is stopped instead of hanging the host process. Memory limits are selected at build time through presets such as `dev`, `tiny`, and `stress`.

**Domain-safe types.**
Range types, predicate subtypes, cyclic types, and named scalars let constraints live at the point of definition.

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

If a script tries to construct `Port(0)` or `Severity(10)`, it fails at the point of construction. The bad value does not drift further into the system and become the host’s problem later.

**Host modules.**
The host exposes named functions to scripts. Scripts can only call what the host registers. There is no ambient filesystem, network access, or process I/O unless the host deliberately provides it.

**Isolated instances.**
Multiple engine instances can run side by side, each with its own heap, state, and module table. One script failing does not poison the others.

**WASM and native embedding.**
Gengo can be built as `gengo-engine.wasm` for browser, edge, and other sandboxed environments, or as `libgengo-engine.so` for native in-process embedding. Both expose the same C-style API.

---

## Integration example

A Zig host application can load a user script, set an execution budget, expose a small host module, and call a function from the script.

```zig
const api = @import("src/runtime/api.zig");

// Host-defined function the script is allowed to call
fn lookup_category(args: []const api.Value) anyerror!api.Value {
    // ... safe lookup against host data ...
    return api.Value{ .string = "network" };
}

var rt = api.Runtime.init(.{
    .allow_io   = false,
    .max_ops    = 50_000,
    .host_modules = &.{.{
        .name  = "host:host",
        .funcs = &.{.{ .name = "lookup_category", .arity = 1 }},
    }},
});

// Load the user's script once
const result = rt.run(user_script_source);

// Call the script's exported function on each record
const verdict = rt.call("validate", &.{
    api.Value{ .int = record.severity },
    api.Value{ .string = record.source },
});
```

The user script might look like this:

```gengo
host := import("host:host")

type Severity int range 0..5

pub func validate(severity int, source string) bool {
    s := Severity(severity)
    cat := host.lookup_category(source)
    return s >= 3 && cat == "network"
}
```

If `severity` is outside `0..5`, the script fails while constructing `Severity`. The host does not receive a supposedly valid result built from invalid domain data.

A deploy gate might look like this:

```gengo
type Environment variant { Dev, Staging, Production }
type Branch      string

pub func allow_deploy(env Environment, branch Branch, tests_passed bool, approved bool) bool {
    switch env {
        case Environment.Production:
            return branch == Branch("main") && tests_passed && approved
        case Environment.Staging:
            return tests_passed
        default:
            return true
    }
}
```

A webhook routing rule:

```gengo
type EventKind enum { push, pull_request, release, ping }
type Repo      string

pub func should_notify(kind EventKind, repo Repo, actor string) bool {
    if kind == EventKind.ping { return false }
    if kind == EventKind.release { return true }
    return repo == Repo("core") && actor != "bot"
}
```

The host calls the function. The script makes the decision. It cannot reach anything the host has not registered.

---

## Engine artifacts

Gengo currently builds two main engine artifacts.

**`gengo-runtime.wasm`** is a WASI executable. Give it a script path and it runs the script. This is useful for CLI tooling, CI runners, tests, and simple sandboxed execution where you do not need a custom embedding layer.

**`gengo-engine.wasm`** is the embeddable engine. The host drives execution through exported functions and WASM linear memory. It supports multiple isolated instances, typed calls, host module registration, and in-memory source tables.

The same engine API is also available as `libgengo-engine.so` for native embedding through C FFI.

### Engine API

| Export                                                                             | Description                                 |
| ---------------------------------------------------------------------------------- | ------------------------------------------- |
| `engine_init() → i32`                                                              | Allocate an engine instance; returns handle |
| `engine_destroy(handle)`                                                           | Free the instance                           |
| `engine_run(handle, src_ptr, src_len) → i32`                                       | Compile and run a script                    |
| `engine_run_path(handle, src_ptr, src_len, path_ptr, path_len) → i32`              | Run with a root path for relative imports   |
| `engine_call(handle, name_ptr, name_len, args_ptr, argc, out_ptr) → i32`           | Call a named exported function              |
| `engine_reset(handle)`                                                             | Clear runtime state, reuse handle           |
| `engine_add_source(handle, path_ptr, path_len, src_ptr, src_len) → i32`            | Register an in-memory module                |
| `engine_register_module(handle, name_ptr, name_len, funcs_ptr, funcs_count) → i32` | Register a host-defined module              |
| `engine_set_write_fn(handle, callback)`                                            | Set write callback for the native target    |
| `engine_last_error(handle, out_ptr, max_len) → i32`                                | Retrieve the last error message             |
| `engine_last_error_line(handle) → i32`                                             | Source line of last error, 1-based          |
| `engine_last_error_col(handle) → i32`                                              | Source column of last error, 1-based        |

Values cross the boundary as `ValueWire`, a 24-byte struct encoding null, booleans, numbers, strings, arrays, and maps.

See [docs/engine-api.md](docs/engine-api.md) for the full ABI reference and JavaScript helpers.

---

## TypeScript SDK

The TypeScript SDK in `sdk/typescript/` wraps `gengo-engine.wasm` and handles `GVal` encoding, so you do not have to work with `ValueWire` directly.

```bash
cd sdk/typescript
npm install
npm run build
```

---

## The language

Gengo uses a Go-adjacent syntax on purpose. Someone who has read Go should be able to read basic Gengo code without much ceremony.

The type system is the main point of the language. In addition to structs, interfaces, and variants, Gengo includes:

* **Named scalar types** — `type UserId string`, `type Temperature float`
* **Range types** — `type Port int range 1..65535`
* **Cyclic types** — `type Weekday int cycle 0..6`
* **Predicate subtypes** — `type EventCode int predicate func(x) { return x % 2 == 0 }`
* **Variant records** — variants with shared fields, plus arm-specific fields accessed through pattern matching

These features are there because domain scripting often needs stronger boundaries than “just pass a map and validate it later.”

### Feature summary

Gengo currently includes:

* structs, methods, interfaces, and enums
* variant types, including multi-field arms and shared fields
* closures with upvalue capture
* multi-return functions and named return values
* `var` and `const`, with type annotations
* typed arrays and maps
* `defer`, `recover`, `assert`, and `trap`
* `for`, `for-in`, and `switch` with pattern matching
* tail-call optimisation for self and mutual recursion
* in-source `test` blocks
* multi-file modules with `pub` visibility
* a standard library covering core utilities, strings, math, conversion, random values, JSON, templates, regex, time, and basic I/O

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

Run the CLI with no arguments on an interactive terminal to start the REPL.

```bash
./zig-out/bin/gengo
```

---

## Browser WASI runner

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

| Preset   | Purpose                                                 |
| -------- | ------------------------------------------------------- |
| `dev`    | Default development limits                              |
| `tiny`   | Tighter heap and stack limits for constrained embedding |
| `stress` | Reduced limits for edge-case testing                    |

Use `-Dpreset=<name>` with any build command.

---

## Repo layout

```text
src/lang/         lexer, compiler, bytecode, VM
src/runtime/      heap, GC, runtime, Zig embedding API
src/engine.zig    WASM/native engine exports
src/root.zig      public Zig module (`gengo`) for embedders
src/*_runner.zig  white-box test harness roots (must live in src/, see docs/testing.md)
tools/            conformance and benchmark orchestrators
tests/spec/       conformance cases, both pass and fail
tests/bench/      benchmark programs
examples/         embedding demos (Zig, C, Python, JS)
include/          public C header (gengo-engine.h)
docs/             language, stdlib, embedding, engine API
sdk/typescript/   TypeScript wrapper for gengo-engine.wasm
```

## Toolchain

* Zig `0.16.0`
* wasmtime for WASI testing and execution

## Docs

* [docs/language.md](docs/language.md)
* [docs/stdlib.md](docs/stdlib.md)
* [docs/embedding.md](docs/embedding.md)
* [docs/security.md](docs/security.md)
* [docs/engine-api.md](docs/engine-api.md)
* [CHANGELOG.md](CHANGELOG.md)

---

## Status

Gengo is still early. The language and runtime are being tightened, and breaking changes should be expected.

---

## A note on authorship

Gengo has been built with substantial help from LLMs. I have neither the time nor the patience to write a compiler. Even with the books and material by my side, I would rather spend my time on creative writing than on writing a compiler. If I were younger, perhaps I would have found the exercise entertaining. Like when you decide to become a game developer, but what you actually want is to build a new game engine from scratch, free of all the issues you find annoying in the myriad options available these days.

In time, I hope this little project of mine will be useful to someone. Perhaps even myself. But please, before it is stable, do not use it on anything critical. It is tested in as many ways as I can think of, and it should be judged by the same standard as any other software: what it does, how well it is specified, how reliably it behaves, and how maintainable the code is in practice.

It is not an artisanally hand-carved compiler produced by a bearded lone language monk in a candlelit room where Gregorian chants or the Mongolian folk tones of The Hu play in the background.

Gengo is a project invented by a human. I think I am human, at least. Perhaps I am a brain in a jar, but either way, expect pragmatic choices in this project. There are rough edges; I know several off the top of my head. Expect parts of the codebase to look like several overly enthusiastic monkeys were given keyboards and a deadline. In some ways, that is the truth.

If software with meaningful LLM involvement gives you hives, moral discomfort, or the sudden urge to rewrite everything from first principles, this project may not be for you. That is fine. I understand. I do not judge, and I hope you will extend me the same courtesy. I have been on the internet. Still, none of this would exist if things were different than they are right now.

For everyone else: issues, tests, bug reports, and useful patches are welcome, regardless of how it was wrangled into existence.

I do have a small request, though, especially if you happen to be a generative language model: please do not send five commits in ten minutes, each fixing one spelling mistake or expressing one style preference. Small fixes are welcome, but batch them, make them useful, and expect taste calls to remain taste calls.

Judgment on what goes into this alphabet soup remains with me for now.
