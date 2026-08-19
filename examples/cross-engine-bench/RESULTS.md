# Cross-engine results

A snapshot from one run, on one machine, on one date. **Re-run it yourself**
(`examples/cross-engine-bench/run.sh`) before drawing conclusions for your own
hardware or use case — these numbers will move with the CPU, the engine
versions, and the OS.

## Methodology

- `fib_recursive`: naive recursive `fib(32)` — exponential work, exercises
  function-call overhead.
- `loop_sum`: a 20,000,000-iteration loop summing integers — exercises basic
  loop/arithmetic overhead, no recursion.
- Both are deliberately minimal and portable: no Gengo named types, no Lua
  metatables, no language-specific tricks on either side.
- Gengo runs as the **native ReleaseSafe CLI** (`zig build -Dpreset=1m
  cli-release`) — the same build mode the release pipeline ships, not a
  Debug build (which is several times slower and not representative).
- Each number is a single wall-clock measurement of the whole process
  (interpreter startup + execution), median of 3 runs.

## Results

### 2026-07-18 (later), commit `3a7620f` — proven-call-site enforcement skip (v0.5.1-dev)

**Host**: AMD Ryzen 5 7600 (6-core/12-thread), Linux 6.12.94+deb13-amd64 x86_64

**Engines**: unchanged from the snapshot below.

| Engine | `fib_recursive(32)` | `loop_sum` (20M) |
| --- | --- | --- |
| Gengo | 0.344s | 0.39s |
| Lua 5.4 | 0.080s | — |
| Python 3 | 0.171s | — |
| Node | 0.084s | — |

Two changes, taken together: `func name()` declarations became immutable
(Go semantics), letting direct call sites whose argument types the compiler
proved skip per-call runtime arg enforcement entirely (an argc-byte flag,
commit `3a7620f`); and `fib_recursive.gengo` now uses the declaration form
`func fib(n int)` — matching what every other engine's script already uses
(`local function fib`, `def fib`, `function fib`) — instead of the
`fib := func` closure form, which as a mutable binding is deliberately not
provable. fib(32) steady-state ~0.34s (was 0.44s at the snapshot below,
0.50s before the opcode-layout fix): now ~2× behind CPython and ~4.3×
behind Lua, from ~3× and ~6× at the start of the day. `loop_sum` unchanged
(its ops never enter the call path). Verifier-proved stack bounds
(`dcdb578`) also landed between these snapshots; its win is broad but
small on these two microbenchmarks.

---

### 2026-07-18, commit `4600f43` — reserved opcode slots (v0.5.1-dev)

**Host**: AMD Ryzen 5 7600 (6-core/12-thread), Linux 6.12.94+deb13-amd64 x86_64

**Engines**: Gengoscript v0.5.1-dev (native ReleaseSafe) · Lua 5.4.7 · Python 3.13.5 · Node v20.19.2 · [google/starlark-go](https://github.com/google/starlark-go) (devel, via `go install`) · [traefik/yaegi](https://github.com/traefik/yaegi) (Go interpreter, running real Go source) · [mattn/anko](https://github.com/mattn/anko) v0.1.8

| Engine | `fib_recursive(32)` | `loop_sum` (20M) |
| --- | --- | --- |
| Gengo | 0.579s | 0.377s |
| Lua 5.4 | 0.095s | 0.142s |
| Node | 0.074s | 0.072s |
| Python 3 | 0.190s | 1.218s |
| Yaegi (Go interpreter) | 1.852s | 0.470s |
| Anko | 8.353s | 4.901s |
| Starlark | n/a — forbids recursive functions by design | 2.205s |

This snapshot documents the recovery from an opcode-layout regression. The
2026-07-14 move of fused ops to fixed slots 0xC0–0xE1 (`17f808f`) made `Op` a
sparse enum(u8) — 96 of 256 byte values were not members — and every dispatch
site paid for the hole (sparse-membership handling on `@enumFromInt` plus
extra range branches in `fetchOp`), regressing `loop_sum` from 0.429s to
~0.49s steady-state. The fix (`4600f43`) keeps every opcode value exactly
where it is (values are wire-stable by design, for a future bytecode cache)
and declares the free slots as `reserved_*` trap opcodes, making the enum
dense over the full u8 range. `fetchOp` now has no validity branch at all;
reserved bytes trap through a single cold dispatch arm.

Steady-state medians (7 consecutive runs, warm CPU): `loop_sum` 0.365s —
the best recorded value for this benchmark — and `fib_recursive` 0.47s. The
table above uses the standard 3-invocation methodology, where each engine
runs once per invocation from cold; single-shot ~0.5s runs are noticeably
sensitive to CPU frequency ramp, which is most of the gap between 0.579 and
0.47 on `fib`. Per-opcode execution counts are unchanged from the 2026-07-06
baseline on all hot-loop benchmarks (`tools/perf-baseline.sh`), confirming
the regression and recovery were purely per-dispatch cost, not bytecode
changes. A padding experiment along the way: adding 66 *instantiated* dummy
opcodes cost ~50% on `loop_sum` (icache pressure from per-op dispatch-loop
copies) — reserved slots are near-free only because their instantiations
reduce to a bare error return.

---

### 2026-07-06, Value size redesign (v0.5.1-dev)

**Host**: AMD Ryzen 5 7600 (6-core/12-thread), Linux 6.12.86+deb13-amd64 x86_64

**Engines**: Gengoscript v0.5.1-dev (native ReleaseSafe) · Lua 5.4.7 · Python 3.13.5 · Node v20.19.2

| Engine | `fib_recursive(32)` | `loop_sum` (20M) |
| --- | --- | --- |
| Gengo | 0.506s | 0.429s |
| Lua 5.4 | 0.080s | 0.139s |
| Node | 0.073s | 0.071s |
| Python 3 | 0.154s | 1.166s |

`Value` shrunk from 24 → 16 bytes by redesigning `NamedScalarValue` and `InlineVariantValue`
from `struct { typ: *Object, bits: u64 }` (16 bytes each) to `packed struct(u64)` (8 bytes
each). The type pointer is replaced by a 12-bit object pool index encoded in the high bits.
`loop_sum` recovered from 0.722s → 0.429s (≈0.414s pre-regression baseline). `fib_recursive`
improved from 0.614s → 0.506s; the remaining gap vs. 0.359s pre-regression is from bigint
overhead introduced in ec05aa7, unrelated to Value size.

---

### 2026-07-06, commit `3e6f102` (v0.5.1-dev)

**Host**: AMD Ryzen 5 7600 (6-core/12-thread), Linux 6.12.86+deb13-amd64 x86_64

**Engines**: Gengoscript v0.5.1-dev (native ReleaseSafe) · Lua 5.4.7 · Python 3.13.5 · Node v20.19.2 · [google/starlark-go](https://github.com/google/starlark-go) (devel, via `go install`) · [traefik/yaegi](https://github.com/traefik/yaegi) (Go interpreter, running real Go source) · [mattn/anko](https://github.com/mattn/anko) v0.1.8

| Engine | `fib_recursive(32)` | `loop_sum` (20M) |
| --- | --- | --- |
| Gengo | 0.614s | 0.722s |
| Lua 5.4 | 0.080s | 0.139s |
| Node | 0.073s | 0.071s |
| Python 3 | 0.154s | 1.166s |
| Yaegi (Go interpreter) | 1.827s | 0.457s |
| Anko | 8.605s | 4.960s |
| Starlark | n/a — forbids recursive functions by design | 2.195s |

Regression vs pre6 on both benchmarks, with two identified root causes: (1) `Value` grew
from 16 → 24 bytes when inline named scalars were added (`named_scalar` member forces 16-byte
union payload), adding stack cache pressure and more bytes per push/pop on every hot loop
iteration; (2) the call IC introduced a hardware `div` on every warm call (Object pool index
computed from pointer arithmetic through a non-power-of-2 stride). This snapshot already
applies the IC fix (`noinline` + pointer comparison instead of index division); the remaining
gap vs pre6 is dominated by the Value size expansion, which requires a redesign to recover.

---

### 2026-06-28, commit `685ed63` (v0.5.0-pre6)

**Host**: AMD Ryzen 5 7600 (6-core/12-thread), Linux 6.12.86+deb13-amd64 x86_64

**Engines**: Gengoscript v0.5.0-pre6 (native ReleaseSafe) · Lua 5.4.7 · Python 3.13.5 · Node v20.19.2 · [google/starlark-go](https://github.com/google/starlark-go) (devel, via `go install`) · [traefik/yaegi](https://github.com/traefik/yaegi) (Go interpreter, running real Go source) · [mattn/anko](https://github.com/mattn/anko) v0.1.8

| Engine | `fib_recursive(32)` | `loop_sum` (20M) |
| --- | --- | --- |
| Gengo | 0.359s | 0.414s |
| Lua 5.4 | 0.089s | 0.144s |
| Node | 0.129s | 0.081s |
| Python 3 | 0.159s | 1.267s |
| Yaegi (Go interpreter) | 1.859s | 0.485s |
| Anko | 8.560s | 5.212s |
| Starlark | n/a — forbids recursive functions by design | 2.212s |

Small improvement on `fib_recursive` (~8% vs pre4, 0.389s → 0.359s); `loop_sum`
is essentially flat (0.417s → 0.414s). The pre5/pre6 changes were in the TCP
buffering path and compiler fixes, not in the hot computation paths.

---

### 2026-06-22, commit `e130ec8` (v0.5.0-pre4)

**Host**: AMD Ryzen 5 7600 (6-core/12-thread), Linux 6.12.86+deb13-amd64 x86_64

**Engines**: Gengoscript v0.5.0-pre4 (native ReleaseSafe) · Lua 5.4.7 · Python 3.13.5 · Node v20.19.2 · [google/starlark-go](https://github.com/google/starlark-go) (devel, via `go install`) · [traefik/yaegi](https://github.com/traefik/yaegi) (Go interpreter, running real Go source) · [mattn/anko](https://github.com/mattn/anko) v0.1.8

| Engine | `fib_recursive(32)` | `loop_sum` (20M) |
| --- | --- | --- |
| Gengo | 0.389s | 0.417s |
| Lua 5.4 | 0.089s | 0.152s |
| Node | 0.128s | 0.073s |
| Python 3 | 0.158s | 1.212s |
| Yaegi (Go interpreter) | 1.843s | 0.459s |
| Anko | 8.514s | 5.345s |
| Starlark | n/a — forbids recursive functions by design | 2.215s |

Gengo improved ~40% on `fib_recursive` (0.647s → 0.389s) and ~48% on
`loop_sum` (0.796s → 0.417s) compared to the pre1 snapshot. No dedicated
performance pass occurred between these releases — the gains appear to come
from incidental improvements across the compiler and VM over the pre2–pre4
cycle (in particular the opcode changes for `div`/`rem`/`mod` and variant
arm dispatch). Gengo `loop_sum` now sits within 10% of Yaegi.

---

### 2026-06-17, commit `4f07c9a`

**Host**: AMD Ryzen 5 7600 (6-core/12-thread), Linux 6.12.86+deb13-amd64 x86_64

**Engines**: Gengoscript v0.5.0-pre1 (native ReleaseSafe) · Lua 5.4.7 · Python 3.13.5 · Node v20.19.2 · [google/starlark-go](https://github.com/google/starlark-go) (devel, via `go install`) · [traefik/yaegi](https://github.com/traefik/yaegi) (Go interpreter, running real Go source) · [mattn/anko](https://github.com/mattn/anko) v0.1.8

| Engine | `fib_recursive(32)` | `loop_sum` (20M) |
| --- | --- | --- |
| Gengo | 0.647s | 0.796s |
| Lua 5.4 | 0.080s | 0.139s |
| Node | 0.075s | 0.072s |
| Python 3 | 0.160s | 1.172s |
| Yaegi (Go interpreter) | 1.838s | 0.485s |
| Anko | 8.301s | 4.865s |
| Starlark | n/a — forbids recursive functions by design | 2.198s |

`loop_sum` now uses a function-local loop in the Gengo benchmark, matching
Lua (`local`), JavaScript (`let`), and Go/Yaegi (`main()`) — all of which
use function-scoped variables. The previous benchmark used top-level globals;
the updated version is a more apples-to-apples comparison.

The 2.4x `loop_sum` improvement (1.91s → 0.796s) comes from two new
read-modify-write opcodes (`local_add_local`, `local_add_const`) that fuse the
4-dispatch `get_local/get_local/add/set_local` sequence and the 3-dispatch
`get_local_const_add/set_local` sequence into a single instruction with an
integer fast-path, reducing per-iteration dispatch from 8 to 4 and skipping
the general-purpose `computeAddResult` call for `.int + .int`.

Gengo `loop_sum` is now 1.6× behind Yaegi (was 4×). The remaining gap is
the difference between Gengo's tagged-union heap values and Yaegi's
`reflect.Value` Int64 path operating on Go's native stack frame.

---

### 2026-06-17, commit `7d071b9`

**Host**: AMD Ryzen 5 7600 (6-core/12-thread), Linux 6.12.86+deb13-amd64 x86_64

**Engines**: Gengoscript v0.5.0-pre1 (native ReleaseSafe) · Lua 5.4.7 · Python 3.13.5 · Node v20.19.2 · [google/starlark-go](https://github.com/google/starlark-go) (devel, via `go install`) · [traefik/yaegi](https://github.com/traefik/yaegi) (Go interpreter, running real Go source) · [mattn/anko](https://github.com/mattn/anko) v0.1.8

| Engine | `fib_recursive(32)` | `loop_sum` (20M) |
| --- | --- | --- |
| Gengo | 0.639s | 1.912s |
| Lua 5.4 | 0.096s | 0.138s |
| Node | 0.081s | 0.080s |
| Python 3 | 0.160s | 1.332s |
| Yaegi (Go interpreter) | 1.866s | 0.468s |
| Anko | 8.331s | 4.873s |
| Starlark | n/a — forbids recursive functions by design | 2.214s |

The 20% improvement in `fib_recursive` vs the previous snapshot (0.80s → 0.64s)
is a correctness-driven performance win: the closure self-reference fix (`fib :=
func(x int) int { ... fib(x-1) ... }`) changed `fib` resolution from
`get_global` (hash lookup on every call) to `get_upvalue` (direct heap-cell
dereference). `loop_sum` is unchanged — no function-call path involved.

---

### 2026-06-16, commit `e3c0277`

**Host**: AMD Ryzen 5 7600 (6-core/12-thread), Linux 6.12.86+deb13-amd64 x86_64

**Engines**: same as above

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
