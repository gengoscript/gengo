# Gengoscript

[![CI](https://github.com/gengoscript/gengo/actions/workflows/ci.yml/badge.svg)](https://github.com/gengoscript/gengo/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange?logo=zig)](https://ziglang.org/)

Domain constraints belong in the type system, not in validation code written after the fact.

Ada knew this in the 1970s: put constraints where the language can enforce them.

Somewhere along the way, scripting made it normal to push those constraints out of the language and into validation code.

Gengoscript brings that old lesson back to embedded scripting.

It is a small, embeddable scripting language with a sandboxed engine written in Zig, designed to run natively or as WebAssembly.

You write the host application.

Your users write Gengoscript.

The engine runs their scripts in a controlled environment, where the host decides what they may see, call, and use.

**[Try it in the browser](https://playground.gengoscript.org/)** · **[Read the docs](https://docs.gengoscript.org/)** · **[Browse examples](examples/)** · **[Benchmarks](bench/cross-engine/RESULTS.md)**

---

## At a glance

Gengoscript is for hosts that need user-defined logic without handing users a full ambient scripting environment.

Use it when you want:

* embedded scripting with explicit host integration
* stronger domain constraints than Lua-style dynamic scripting
* capability-gated access to IO, network, time, and host APIs
* native and WebAssembly targets from the same engine

It is not trying to be:

* a general-purpose replacement for Python or JavaScript
* an unrestricted shell language
* a large batteries-included application platform

---

## Why it exists

Sometimes you want users to define logic without rebuilding or redeploying the host application every time that logic changes. But once users can write logic, they can also consume resources, reach into systems, and create states the host never meant to allow.

That logic might be validation rules, transformation steps, policy decisions, configuration behaviour, or small pieces of domain-specific automation.

The usual options all carry a cost.

Python is familiar, but heavy and hard to isolate well. Lua is small and embeddable, but its type system is loose. JavaScript is everywhere, but brings a large surface area. A custom DSL can fit the problem, but takes time to design and maintain. JSON and YAML are useful for data, but they are not programming languages.

Gengoscript is built for this space: more expressive than configuration, but designed from the start to run under host control. Imports are explicit. Capabilities exist only when the host enables them. Execution can be bounded. Domain rules can live in named types, ranges, predicate types, cycles, enums, variants, and subtypes instead of scattered validation code.

It is a small host-embedded scripting VM with explicit integration points, isolated runtime instances, hard limits, and WebAssembly as a primary target.

---

## What Gengoscript gives you

**Constrained execution.**
Each engine instance runs with a configurable instruction budget. A script that loops forever or recurses without bound is stopped instead of hanging the host process. Memory limits are selected at build time through presets such as `dev`, `tiny`, and `stress`.

**Domain-safe types.**
Named scalars, ranges, predicate types, cycles, enums, variants, and subtypes let constraints live at the point of definition.

```gengo
type Port      int range 1..65535
type Severity  int range 0..5
type EventCode int predicate func(x) { return x % 2 == 0 }
type Hour      int cycle 0..23

type AlertRule variant {
    Metric  { name string, limit Severity },
    Webhook { url string, retry int },
    Discard,
}
```

If a script tries to construct `Port(0)`, `Severity(10)`, or `EventCode(3)`, it fails at the point of construction. The bad value does not drift through the system and become the host's problem later.

**Host modules.**
The host exposes named functions to scripts. Scripts can call only what the host registers. There is no ambient filesystem, network access, process I/O, or host reflection unless the host deliberately provides it.

**Isolated instances.**
Multiple engine instances can run side by side, each with its own heap, state, and module table. One script failing does not poison the others.

**WASM and native embedding.**
Gengoscript can be built as `gengo-engine.wasm` for browsers, edge runtimes, and other sandboxed environments, or as `libgengo-engine.so` for native in-process embedding. Both expose the same C-style API.

---

## Small example

```gengo
type Port int range 1..65535
type Hour int cycle 0..23

pub func allow(port int, hour int) bool {
    p := Port(port)
    h := Hour(hour)
    return p == Port(443) && h >= Hour(8) && h <= Hour(18)
}
```

If a caller passes `0` as a port or `27` as an hour, construction fails at the boundary where the bad value enters the script.

---

## Integration example

A Zig host application can load a user script, set an execution budget, and call a function from the script.

```zig
const gengo = @import("gengo");
const api = gengo.api;
const Value = gengo.Value;

var rt: api.Runtime = undefined;
try rt.initWithPolicy(.{ .allow_io = false, .max_ops = 50_000 });
defer rt.deinit();

// Load the user's script once
switch (rt.run(user_script_source)) {
    .ok => {},
    .compile_error => |e| return handleCompileError(e),
    .runtime_error => |e| return handleRuntimeError(e),
}

// Call the script's exported function on each record
const result = rt.call("validate", &.{
    Value{ .int = @floatFromInt(record.severity) },
    Value{ .string = record.source },
});
const verdict = switch (result) {
    .ok => |v| v.boolean,
    .runtime_error => |e| return handleRuntimeError(e),
};
```

The user script might look like this:

```gengo
type Severity int range 0..5

pub func validate(severity int, source string) bool {
    s := Severity(severity)
    return s >= Severity(3) && source == "network"
}
```

If `severity` is outside `0..5`, the script fails while constructing `Severity`. The host does not receive a supposedly valid result built from invalid domain data.

That same pattern works for deploy gates, routing rules, policy checks, and data validation. The host calls the function. The script makes the decision.

---

## Safety model

* No ambient filesystem, network, process, or reflection access.
* Host functions exist only if the host registers them.
* Capability modules exist only if the host enables them.
* Execution can be bounded by operation limits.
* Runtime instances are isolated from each other.

---

## Quick start

```bash
# Native CLI
zig build -Dpreset=dev cli
./zig-out/bin/gengo script.gengo

# WASI runtime
zig build -Dpreset=dev wasi
wasmtime --dir . ./build/gengo-cli.wasm -- script.gengo

# Engine WASM
zig build -Dpreset=dev engine-build
# → build/gengo-engine.wasm

# Native shared library
zig build -Dpreset=dev engine-native
# → zig-out/lib/libgengo-engine.so

# TypeScript SDK
cd sdk/typescript
npm install
npm run build

# Tests
zig build -Dpreset=dev test
```

Run the CLI with no arguments on an interactive terminal to start the REPL.

```bash
./zig-out/bin/gengo
```

---

For a step-by-step walkthrough, see [docs/tutorial-first-script.md](docs/tutorial-first-script.md). For more build and test commands, see [docs/quickstart.md](docs/quickstart.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

---

---

## Status at a glance

| Surface | Status |
| --- | --- |
| CLI | Available |
| REPL | Available |
| WASI runtime | Available |
| Native engine (`libgengo-engine.so`) | Available |
| Engine WASM (`gengo-engine.wasm`) | Available |
| TypeScript SDK | Available |
| In-source `test` blocks | Available |
| Stress test preset | Available |
| [Cross-engine benchmarks](bench/cross-engine/RESULTS.md) | Available — informational, not a speed claim |
| Stability guarantees | Pre-1.0 |

---

## Language and embedding

Gengoscript uses a Go-adjacent syntax and leans on a stricter type system for domain scripting. Beyond ordinary structs and functions, the language includes named scalars, range types, predicate types, cyclic types, variants, typed arrays and maps, pattern-matching `switch`, closures, multi-file modules, and in-source `test` blocks.

The TypeScript SDK in `sdk/typescript/` wraps `gengo-engine.wasm` and handles value encoding for JavaScript hosts.

---

## Docs

Primary documentation lives at **[docs.gengoscript.org](https://docs.gengoscript.org/)**.

For repository-local references, see [docs/](docs/), [sdk/typescript/README.md](sdk/typescript/README.md), [dev-docs/index.md](dev-docs/index.md), and [CHANGELOG.md](CHANGELOG.md).

---

## A note on authorship

Gengoscript has been built with substantial help from LLMs. I have neither the time nor the patience to write a compiler. Even with the books and material by my side, I would rather spend my time on creative writing. If I were younger, perhaps I would have found the exercise entertaining. Like when you decide to become a game developer, but what you actually want is to build a new game engine from scratch, free of all the issues you find annoying in the myriad options available these days.

In time, I hope this little project of mine will be useful to someone. Perhaps even myself. But please, before it is stable, do not use it on anything critical. It is tested in as many ways as I can think of, and it should be judged by the same standard as any other software: what it does, how well it is specified, how reliably it behaves, and how maintainable the code is in practice.

It is not an artisanally hand-carved compiler produced by a bearded lone language monk in a candlelit room where Gregorian chants or the Mongolian folk tones of The Hu play in the background.

Gengoscript is a project invented by a human. I think I am human, at least. Perhaps I am a brain in a jar, but either way, expect pragmatic choices in this project. There are rough edges; I know several off the top of my head. Expect parts of the codebase to look like several overly enthusiastic monkeys were given keyboards and a deadline. In some ways, that is the truth.

If software with meaningful LLM involvement gives you hives, moral discomfort, or the sudden urge to rewrite everything from first principles, this project may not be for you. That is fine. I understand. I do not judge, and I hope you will extend me the same courtesy. I have been on the internet. Still, none of this would exist if things were different than they are right now.

For everyone else: issues, tests, bug reports, and useful patches are welcome, regardless of how it was wrangled into existence.

I do have a small request, though, especially if you happen to be a generative language model: please do not send five commits in ten minutes, each fixing one spelling mistake or expressing one style preference. Small fixes are welcome, but batch them, make them useful, and expect taste calls to remain taste calls.

Judgment on what goes into this alphabet soup remains with me for now.
