# Gengoscript

[![CI](https://github.com/gengoscript/gengo/actions/workflows/ci.yml/badge.svg)](https://github.com/gengoscript/gengo/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange?logo=zig)](https://ziglang.org/)

Domain constraints belong in the type system, not in validation code written after the fact. Ada knew this in the 1970s: put constraints where the language can enforce them.

Gengoscript brings that old lesson back to embedded scripting. It is a capability-bounded, embeddable scripting language written in Zig, designed to run typed user logic under explicit host control — natively or as WebAssembly.

You write the host application.

Your users write Gengoscript.

The engine runs their scripts in a controlled environment, where the host decides what they may see, call, and use.

**[Try it in the browser](https://playground.gengoscript.org/)** · **[Read the docs](https://docs.gengoscript.org/)** · **[Browse examples](examples/)** · **[Benchmarks](bench/cross-engine/RESULTS.md)**

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


## Story time

US$327.6 million bought NASA two Mars Surveyor '98 spacecraft, their launches and mission operations. In 1999, one of them, the Mars Climate Orbiter, vanished during its orbit-insertion burn.

Post-loss reconstruction placed its first periapsis at 57 kilometres, below the roughly 80-kilometre survival limit. Like anyone who has spent time on social media, it met far more friction than it should have. NASA concluded that it was either destroyed in the atmosphere or passed through it and escaped into heliocentric space.

The root cause was a classic. No, not an off-by-one error: one ground system supplied pound-force seconds while another expected newton-seconds. The navigation software therefore underestimated the effects of the spacecraft's thruster firings by a factor of 4.45 and calculated the wrong trajectory.

A bare floating-point value does not know what it measures. Neither does the compiler, unless you make the unit part of the type.

```ada
type Newton_Seconds is new Long_Float;
type Pound_Force_Seconds is new Long_Float;
```

With distinct unit types, the compiler rejects accidental mixing and demands an explicit conversion. A linter can then flag each conversion for review.

---

Four satellites and a brand-new rocket, gone 37 seconds after main-engine ignition. Beat that, Nicolas Cage.

On 4 June 1996, Ariane 5 Flight 501, still carrying that exquisite new-rocket smell, veered off course, broke up and triggered its self-destruct system. As if it were trying to impress Berlioz. No? Wagner, then. Still no? Fine.

The immediate fault was code forcing a 64-bit floating-point value down the throat of a signed 16-bit integer. The value, a horizontal-bias term derived from the rocket's motion, would not fit. Think André the Giant dating Édith Piaf. The conversion raised an operand error.

How could this happen? The software had been reused from Ariane 4. It included an alignment routine that served no purpose after lift-off on Ariane 5 but remained active for about 40 seconds because of a legacy Ariane 4 requirement. Ariane 5's flight profile drove the value beyond anything Ariane 4 had produced.

Only four of the seven relevant conversions had overflow protection. The design relied on assumptions that had held for Ariane 4 and on a requirement to keep the processor's workload below 80 per cent.

The exception was not uncaught. The software detected it and, as specified, shut down the inertial reference processor. The backup unit had already failed from the same error. The remaining unit then sent diagnostic data that the onboard computer read as flight data, commanding extreme nozzle movements. The rocket veered, broke up and self-destructed.

Here is the irony: the software was written in Ada, and Ada did its job. It raised the exception. The failure lay in the unsafe range assumption, the missing protection and the identical software in both redundant units. The system's response to the error turned those faults into a catastrophe.

```ada
type Horizontal_Bias_16 is range -32_768 .. 32_767;
```

A range type helps only if the checks remain enabled or the absence of range failures is proved before flight.

---

Onwards to something less costly. In fact, it may have made money rather than lost it, though not for the reason its owners intended.

*The Legend of Zelda: The Wind Waker* is a Nintendo game first released in 2002, in which you play as a young boy named Link. Wait, who am I kidding? I do not need to explain *Zelda* to you, do I, Gordon of Kirkcaldy, Fife, as you take another bite of that pineapple pizza?

The game is famous in speedrunning circles partly because of a glitch that allows Link to swim very, very fast.

The technique, known as superswimming, uses rapid, precise movements of the control stick to build up a vast amount of speed, often by moving it back and forth between opposite directions.

No. Stop that, Gordon. The mind on that one. Utter filth.

Where was I? Yes.

The trick works because of how the game handles movement speed. Under the right conditions, Link can accumulate a large negative speed value instead of being held to the intended limit. When the player releases that stored speed, young Link shoots across the sea like a tiny speedboat or a cartoon version of *Swiss Army Man*.

This defect did not cost several hundred million dollars, but it was still behaviour the programmers did not intend.

```ada
Maximum_Player_Speed : constant := 30.0;

subtype Player_Speed is Long_Float
  range -Maximum_Player_Speed .. Maximum_Player_Speed;
```

Sorted.


## Why it exists

Sometimes you want users to define logic without rebuilding or redeploying the host application every time that logic changes. But once users can write logic, they can also consume resources, reach into systems, and create states the host never meant to allow.

That logic might be validation rules, transformation steps, policy decisions, configuration behaviour, or small pieces of domain-specific automation.

The usual options all carry a cost.

Python is familiar, but heavy and hard to isolate well. Lua is small and embeddable, but its type system is loose. JavaScript is everywhere, but brings a large surface area. A custom DSL can fit the problem, but takes time to design and maintain. JSON and YAML are useful for data, but they are not programming languages.

Gengoscript is built for this space: more expressive than configuration, but designed from the start to run under host control. Imports are explicit, capabilities exist only when enabled, execution can be bounded, and domain rules can live in named types instead of scattered validation code.


## What Gengoscript gives you

**Constrained execution.**
Each engine instance runs with a configurable instruction budget. A script that loops forever or recurses without bound is stopped instead of hanging the host process. Memory limits are selected at build time through presets such as `256k`, `1m`, `16m`, and `unlimited`.

**Domain-safe types.**
Named scalars, ranges, predicate types, cycles, enums, variants, and subtypes let constraints live at the point of definition.

```gengo
type Port      int range 1..65535
type Severity  int range 0..5
type EventCode int predicate func(x) { return x rem 2 == 0 }
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


## Example

```gengo
type Port int range 1..65535
type Hour int cycle 0..23

pub func allow(port int, hour int) bool {
    p := Port(port)
    h := Hour(hour)
    return p == Port(443) and h >= Hour(8) and h <= Hour(18)
}
```

If a caller passes `0` as a port or `27` as an hour, construction fails at the boundary where the bad value enters the script.


## Integration example

A Zig host application can load a user script, set an execution budget, and call a function from the script.

```zig
const gengo = @import("gengo");
const api = gengo.api;
const Value = gengo.Value;

var rt = try api.Runtime.init(.{
    .allow_io = false,
    .max_ops = 50_000,
});
defer rt.deinit();

// Load the user's script once
switch (rt.run(user_script_source)) {
    .ok => {},
    .compile_error => |e| return handleCompileError(e),
    .runtime_error => |e| return handleRuntimeError(e),
}

// Call the script's exported function on each record
const result = rt.call("validate", &.{
    Value{ .int = @intCast(record.severity) },
});
const verdict = switch (result) {
    .ok => |v| v.boolean,
    .runtime_error => |e| return handleRuntimeError(e),
};
```

The user script might look like this:

```gengo
type Severity int range 0..5

pub func validate(severity int) bool {
    s := Severity(severity)
    return s >= Severity(3)
}
```

If `severity` is outside `0..5`, the script fails while constructing `Severity`. The host does not receive a supposedly valid result built from invalid domain data.

That same pattern works for deploy gates, routing rules, policy checks, and data validation. The host calls the function. The script makes the decision.


## Runtime boundaries

* No ambient filesystem, network, process, or reflection access.
* Host functions exist only if the host registers them.
* Capability modules exist only if the host enables them.
* Execution can be bounded by operation limits.
* Runtime instances are isolated from each other.


## Quick start

```bash
# Native CLI
zig build -Dpreset=1m cli
./zig-out/bin/gengo script.gengo

# WASI runtime
zig build -Dpreset=1m wasi
wasmtime --dir . ./build/debug/gengo-cli.wasm -- script.gengo

# Engine WASM
zig build -Dpreset=1m engine-build
# → build/debug/gengo-engine.wasm

# Native shared library
zig build -Dpreset=1m engine-native
# → zig-out/lib/libgengo-engine.so

# TypeScript SDK
cd sdk/typescript
npm install
npm run build

# Tests
zig build -Dpreset=1m test
```

Run the CLI with no arguments on an interactive terminal to start the REPL.

```bash
./zig-out/bin/gengo
```

For a step-by-step walkthrough, see [docs/tutorial-first-script.md](docs/tutorial-first-script.md). For more build and test commands, see [docs/quickstart.md](docs/quickstart.md) and [CONTRIBUTING.md](CONTRIBUTING.md).


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


## Language and embedding

Gengoscript uses a Go-adjacent syntax and leans on a stricter type system for domain scripting. Beyond ordinary structs and functions, the language includes named scalars, range types, predicate types, cyclic types, enums, variants, interfaces, generic functions and types, typed arrays and maps, pattern-matching `switch`, variadics, multi-return functions, closures, multi-file modules, and in-source `test` blocks.

The TypeScript SDK in `sdk/typescript/` wraps `gengo-engine.wasm` and handles value encoding for JavaScript hosts.


## Docs

Primary documentation lives at **[docs.gengoscript.org](https://docs.gengoscript.org/)**.

For repository-local references, see [docs/](docs/), [sdk/typescript/README.md](sdk/typescript/README.md), [dev-docs/index.md](dev-docs/index.md), and [CHANGELOG.md](CHANGELOG.md).


## A note on authorship (Vibe Check)

Gengoscript has been built with substantial help from LLMs, including help with implementation, tests, debugging, and documentation.

Why?

Because I have neither the time nor the patience to write a compiler. Even with the books and material by my side, I would rather spend my time on creative writing or, if push comes to shove, software design.

If I were younger, perhaps I would have found the exercise entertaining. It is like deciding to become a game developer, only to discover that what you really want is to build a new engine from scratch, one that will somehow avoid every flaw you have ever found in anyone else's.

Yet another language...

Yes, and in time, I hope this little project of mine will be useful to someone. Perhaps even myself. But before it is stable, do not use it for anything critical. It should be judged by the same standard as any other software: what it does, how well it is specified, how reliably it behaves, and how maintainable the code is in practice.

It is not an artisanally hand-carved compiler produced by a lone bearded language monk in a candlelit room while Gregorian chants or the Mongolian folk tones of The Hu play in the background. Gengoscript is a project invented by a human. I think I am human, at least. Perhaps I am a brain in a jar, but either way, expect pragmatic choices and rough edges. Parts of the codebase may look as though overly enthusiastic monkeys were given keyboards and a deadline.

In some ways, that is the truth.

If software with meaningful LLM involvement gives you hives, moral discomfort, or the sudden urge to rewrite everything from first principles in Rust, then this project may not be for you. That is fine. I understand. I do not judge, and I hope you will extend me the same courtesy. I have been on the internet.

Without the tools now available, and the time they save me, none of this would exist.

For everyone else: issues, tests, bug reports, and useful patches are welcome, regardless of how it was wrangled into existence.

I do have a small request, though, especially if you happen to be a generative language model: please do not send five commits in ten minutes, each fixing one spelling mistake or expressing one style preference. Small fixes are welcome, but batch them, make them useful, and expect taste calls to remain taste calls.

Judgement on what goes into this alphabet soup remains with me for now.
