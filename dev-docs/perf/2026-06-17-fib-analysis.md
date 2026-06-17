# VM Performance Analysis: Recursive fib(32)

**Date:** 2026-06-17
**Branch:** `perf-analysis`
**Analyst:** AI assistant

## Executive Summary

Profiling the naive recursive `fib(32)` benchmark reveals that **~52–62% of execution time is spent in call/ret overhead**, with the return path being disproportionately expensive. The root cause is that **all typed functions are forced through `retSlowPath`**, even when the return type is a primitive (e.g. `int`) whose validation is a single tag check. The `ret` fast path is gated behind `!frame.has_typed_returns`, so typed functions like `fib(n int) int` bypass it entirely.

The `call` path is already reasonably efficient at ~82–92 cycles per call. The `ret` path costs ~103–153 cycles per return because it must:
1. Push/pop a GC temp-root
2. Look up the function signature via `frameFuncSig`
3. Check for named returns
4. Call `enforceFuncReturnTypes`

For a function returning `int`, steps 1–3 are pure overhead.

## Benchmark Data

| Benchmark | User Time | Notes |
|---|---|---|
| fib(32) recursive | 0.74 s | Main target |
| fib(35) tail-recursive | <0.001 s | Confirms TCO works |
| loop_sum (20M iters) | 1.84 s | 87 MIPS reference |
| dispatch_loop (100M iters) | 9.78 s | Pure dispatch baseline |
| call_overhead (10M calls) | 1.84 s | Trivial `inc(x int) int` in loop |

### fib(32) Opcode Mix (from `bench-perf`)

| Opcode | Count | Notes |
|---|---|---|
| `call` | 7,049,155 | Non-root invocations |
| `ret` | 7,049,155 |  |
| `get_global` | 7,049,157 | IC resolves after first miss |
| `get_local_const_sub` | 7,049,154 |  |
| `get_local_const_lt_jif_pop` | 7,049,155 |  |
| `get_local` | 3,524,578 | Base cases |
| `add` | 3,524,577 |  |

Total ~35M opcode dispatches.

### Cycle-Accurate Measurements (RDTSC)

Measured with instrumentation compiled into ReleaseSafe build (`-Dperf=true`):

| Metric | fib(32) | call_overhead (10M) |
|---|---|---|
| Avg `call` cycles | 92 | 82 |
| Avg `ret` cycles | 103 | 153 |
| **Total call+ret per pair** | **~195** | **~235** |
| Total call-ret pairs | 7,049,155 | 10,000,000 |
| Call+ret total cycles | 1,377M | 2,353M |
| Wall time | 0.74 s | 1.84 s |
| Call-ret % of total | ~52% | ~100% (by design) |

> Note: `ret` is more expensive than `call` because the `call` measurement includes only `performCall`, while `ret` includes the entire `ret` opcode handler (fast path + slow path). In `call_overhead`, the `ret` includes `retSlowPath` for typed returns.

## Root Cause: `ret` Fast Path Excludes Typed Functions

The `ret` opcode handler in `vm.zig` (lines 3013–3030):

```zig
.ret => {
    vmperf.breakOpChain();
    if (vmState().frame_top == 0) return error.ReturnAtTopLevel;
    const retval = try vmPop();
    const fi = vmState().frame_top - 1;
    const frame = &vmState().frames[fi];
    if (vmState().defer_top == frame.defer_base and !frame.has_typed_returns) {
        // FAST PATH — inlined unwind
        vmState().frame_top = fi;
        vmState().stack_top = if (frame.base > 0) frame.base - 1 else 0;
        vmState().ip = frame.ret_ip;
        try vmPush(retval);
        if (vmState().call_depth_target) |d| {
            if (vmState().frame_top == d) return;
        }
        continue;
    }
    if (try retSlowPath(retval)) return;
},
```

The fast path requires **both**:
1. `defer_top == defer_base` (no pending defers)
2. `!has_typed_returns`

Condition 2 fails for **every function with an explicit return type** (e.g. `func fib(n int) int`). This forces **all** typed returns through `retSlowPath`, which does:

1. `pushTempRoot(retval)` + `popTempRoot()`
2. `frameFuncSig()` lookup (hash table or cached)
3. Named return handling (not applicable for scalar returns)
4. `enforceFuncReturnTypes(fsig, retval)`

For `int`, step 4 is just `retval.tag == .int` — a single comparison. Steps 1–3 are pure overhead.

## Optimization Candidates

| # | Optimization | Expected Impact | Files |
|---|---|---|---|
| 1 | **Inline primitive return type check in `ret` fast path** | Eliminate `retSlowPath` for ~80% of typed functions; save ~30–50% of ret overhead (~30–50 cycles per ret) | `vm.zig` |
| 2 | Fuse `get_global` + `call` opcodes | Save one dispatch per call site (7M dispatches in fib) | Emitter + `vm.zig` |
| 3 | Cache return type validator in `CallFrame` | Avoid `frameFuncSig` lookup on every ret | `vm_types.zig`, `vm.zig` |
| 4 | Closure self-reference (`get_upvalue`) | Recursive functions avoid `get_global` entirely | Emitter + runtime |

## Implementation

Optimization #1 was implemented on branch `perf-analysis`.

### Changes Made

**`src/lang/vm_types.zig`** — added two helper functions:
- `isPrimitiveReturn(f: FuncObj) bool` — checks if a function has a single simple primitive return type eligible for inline checking
- `checkPrimitiveReturn(f: FuncObj, v: Value) bool` — performs the inline tag check (e.g. `v == .int or v == .rune`)

**`src/lang/vm.zig`** — widened the `ret` fast-path condition:
- Both `.ret` and `.ret_const` handlers now check: if the function has typed returns, extract its `FuncObj`, verify `isPrimitiveReturn`, and inline `checkPrimitiveReturn` before taking the fast path
- If the inline check fails, falls through to `retSlowPath` as before

**`src/lang/vm_perf.zig`** — added RDTSC-based cycle counters for instrumentation (`readTsc`, `callCycles`, `retCycles`). These are compiled only when `-Dperf=true`.

### Results

| Metric | Before | After | Change |
|---|---|---|---|
| fib(32) wall time | ~0.74 s | ~0.65 s | **~12% faster** |
| fib(32) user time | ~0.72 s | ~0.63 s | **~14% faster** |
| Avg `ret` cycles (instrumented) | ~103 | ~35 | **65% reduction** |
| Avg `call` cycles (instrumented) | ~92 | ~96 | stable |
| call_overhead (10M calls) | — | 1.23 s | — |

The `ret` path dropped from ~103 cycles to ~35 cycles because typed functions with primitive return types (like `fib(n int) int`) now use the inlined fast path instead of `retSlowPath`.

### Test Results

- `zig build test` — **226/226 tests passed**, conformance OK (197 pass-cases, 227 fail-cases — fail-cases are expected error-condition tests)
- `zig build -Dpreset=stress test` — passed with no regressions

### Files Modified

- `src/lang/vm.zig` — `.ret` and `.ret_const` opcode handlers
- `src/lang/vm_types.zig` — `isPrimitiveReturn()`, `checkPrimitiveReturn()`
- `src/lang/vm_perf.zig` — cycle-counting instrumentation (compile-time gated)
- `dev-docs/perf/2026-06-17-fib-analysis.md` — this document

## Additional Optimizations Implemented

### Optimization #2: `get_local_ret` superinstruction

**Commit:** `6cd762e`

Fuses `get_local slot` + `ret` → `get_local_ret slot` (2 bytes, 1 dispatch). Very common in recursive base cases (`return n`).

| Metric | Before | After | Change |
|---|---|---|---|
| `ret` opcodes in fib(32) | 7.0M | 3.5M `ret` + 3.5M `get_local_ret` | **3.5M dispatches saved** |
| fib(32) user time | ~0.63s | ~0.61s | **~3% faster** |

### Optimization #3: `get_local_const_sub_call` superinstruction

**Commit:** `4b61868`

Fuses `get_local_const_sub` + `call` → `get_local_const_sub_call` (6 bytes, 1 dispatch). Saves the hottest opcode pair in fib(32) (7M occurrences).

| Metric | Before | After | Change |
|---|---|---|---|
| Opcode bytes per recursive call | 7 bytes | 6 bytes | **1 byte + 1 dispatch saved per call** |
| fib(32) user time | ~0.63s | ~0.63s | ~0% (dispatch savings offset by handler complexity) |

The wall-time improvement is marginal because the saved dispatch (~17ns) is small compared to `performCall` overhead (~100ns). The primary value is reducing instruction cache pressure and interpreter loop overhead.

### Optimization #4: `add_ret` superinstruction

**Commit:** `00f3a4b`

Fuses `add` + `ret` → `add_ret` (1 byte, 1 dispatch). Avoids pushing/popping the intermediate result.

| Metric | Before | After | Change |
|---|---|---|---|
| `add` + `ret` pairs in fib(32) | 3.5M | 3.5M `add_ret` | **3.5M dispatches saved, no intermediate stack traffic** |
| fib(32) user time | ~0.63s | ~0.63s | ~0% |

Extracted `computeAddResult(a, b)` helper to share `add` logic between `.add` and `.add_ret` handlers, covering string concatenation, decimal arithmetic, and named-type carriers.

### Cumulative Results

| Metric | Baseline | After all optimizations | Total Improvement |
|---|---|---|---|
| fib(32) user time | ~0.72s | ~0.61–0.63s | **~12–15% faster** |
| `ret` cycles | ~103 | ~35 | **65% reduction** |
| Superinstructions added | 0 | 3 (`get_local_ret`, `get_local_const_sub_call`, `add_ret`) | — |
| Dispatches saved in fib(32) | — | ~14M | — |

### Remaining Bottlenecks

After the superinstruction optimizations, the dominant overhead is still the **call frame push/pop** in `performCall`:
- `performCall` saves `ret_ip`, `base`, `closure`, `func_obj`, `defer_base`, `has_typed_returns` (6 fields, ~48 bytes)
- Typed parameter validation (`enforceFuncArgTypes`) adds a tag check per call
- Frame array bounds check

To improve further, the most impactful changes would be:
1. **Direct-threaded dispatch** — replace the `switch` with a jump table of function pointers (saves ~5–10ns per dispatch)
2. **Frame caching / register-window calling convention** — reduce the field writes per call
3. **Compiler-level TCO detection** — convert naive recursion to tail-recursive form where possible
4. **Closure self-reference** — recursive functions store a self-reference in upvalues, avoiding `get_global` entirely

---
*Generated on 2026-06-17 as part of the `perf-analysis` branch investigation.*
