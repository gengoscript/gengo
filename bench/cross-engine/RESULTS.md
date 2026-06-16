# Cross-engine results

A snapshot from one run, on one machine, on one date. **Re-run it yourself**
(`bench/cross-engine/run.sh`) before drawing conclusions for your own
hardware or use case — these numbers will move with the CPU, the engine
versions, and the OS.

## Methodology

- `fib_recursive`: naive recursive `fib(32)` — exponential work, exercises
  function-call overhead.
- `loop_sum`: a 20,000,000-iteration loop summing integers — exercises basic
  loop/arithmetic overhead, no recursion.
- Both are deliberately minimal and portable: no Gengo named types, no Lua
  metatables, no language-specific tricks on either side.
- Gengo runs as the **native ReleaseSafe CLI** (`zig build -Dpreset=dev
  cli-release`) — the same build mode the release pipeline ships, not a
  Debug build (which is several times slower and not representative).
- Each number is a single wall-clock measurement of the whole process
  (interpreter startup + execution), median of 3 runs.

## Results

Captured 2026-06-16, commit `e3c0277`.

**Host**: AMD Ryzen 5 7600 (6-core/12-thread), Linux 6.12.86+deb13-amd64 x86_64

**Engines**: Gengoscript v0.5.0-pre1 (native ReleaseSafe) · Lua 5.4.7 · Python 3.13.5 · Node v20.19.2 · [google/starlark-go](https://github.com/google/starlark-go) (devel, via `go install`) · [traefik/yaegi](https://github.com/traefik/yaegi) (Go interpreter, running real Go source) · [mattn/anko](https://github.com/mattn/anko) v0.1.8

| Engine | `fib_recursive(32)` | `loop_sum` (20M) |
| --- | --- | --- |
| Gengo | 0.80s | 1.93s |
| Lua 5.4 | 0.08s | 0.14s |
| Node | 0.08s | 0.07s |
| Python 3 | 0.16s | 1.19s |
| Yaegi (Go interpreter) | 1.83s | 0.47s |
| Anko | 8.50s | 4.98s |
| Starlark | n/a — forbids recursive functions by design | 2.20s |

## Reading this honestly

Gengo is clearly behind Lua's register-based, NaN-boxed VM and behind V8's
JIT — that's expected; neither is the comparison this language is optimized
for. It's roughly in line with Python's tree-walking-adjacent bytecode
interpreter on `loop_sum`, and behind it on `fib_recursive` (function-call
overhead is Gengo's weaker spot relative to its other costs right now).

Against the other embedded-scripting-style engines: Gengo beats Anko
clearly on both, and beats Yaegi on `fib_recursive` — interesting given
Yaegi is interpreting real Go source, which suggests Yaegi's interpretation
overhead per Go statement is higher than Gengo's bytecode dispatch per
opcode, even though Go itself compiles to native code. Yaegi wins
`loop_sum` by a wide margin, which is more about its faster handling of a
tight numeric loop than about Gengo's function-call cost. Starlark has no
`fib_recursive` entry at all — it's not a missing benchmark, the language
spec disallows recursive functions outright (a deliberate hermeticity/
determinism constraint, since Starlark is designed for things like Bazel
build files where unbounded recursion is a liability, not a feature).

This positions Gengo in the same general bracket as other "VM-tier"
embedded scripting engines — clearly slower than Lua, in a believable range
for a young stack-based bytecode VM that hasn't had a dedicated performance
pass yet.

Gengo's actual target use cases — policy/rule scripts, low-frequency
embedded scripting, domain validation — don't approach fib(32)-level
computational density. These numbers exist for transparency ("is there any
evidence this is fast or slow"), not because raw compute throughput is the
thing Gengo is being designed to win at.
