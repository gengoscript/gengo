# Edge Case Audit

Generated from a systematic audit of the gengo compiler and VM.
Branch: `audit-edge-cases`

---

## CRITICAL

### C1. `variant_value.shared_values` and `arm_fields` not GC-traced

**File:** `src/lang/vm_gc.zig:79-82`

The GC marks `vv.typ` and `vv.payload` for `variant_value` objects but does **not** trace `vv.shared_values` or `vv.arm_fields` (slices of `Value`). Any object reference stored in these slices will be swept when GC runs, leading to use-after-free.

**Fix:** Add iteration over both slices calling `markValue()` on each element.

### C2. `stack_top - N - 1` without guard in `performCall`, `tryTailCall`, `opInvokeMethod`, `opDeferInvokeMethod`

**Files:** `src/lang/vm.zig:170,289,919,1375`

Multiple critical functions compute `stack_top - argc - 1` as a direct stack index without validating that `stack_top >= argc + 1`. If `argc` exceeds the number of elements on the stack, `usize` subtraction wraps and the subsequent array access reads unmapped memory.

**Fix:** Add `if (stack_top < argc + 1) return error.StackUnderflow` guard before each access.

### C3. `stack_top = frame.base - 1` underflow in return paths

**File:** `src/lang/vm.zig:509,2464,2485`

Three return paths (`retSlowPath`, fast-path `ret`, fast-path `ret_const`) set `stack_top = frame.base - 1` unconditionally. If `frame.base == 0`, this wraps to `MaxStack - 1`, corrupting the entire stack. The panic-unwind code at lines 2596 and 2624 correctly guards with `if (frame.base > 0) ... else 0`.

**Fix:** Apply the same guard to the three return paths.

### C4. `base + slot` stack access without bounds check

**Files:** `src/lang/vm.zig:528,1538,1549,1553,1578,1580,1844,1862,1878,1900,2278-2279`

Every `get_local`, `set_local`, `close_upvalue`, fused `get_local_const_*`, `make_closure`, and `opGetLocalGetField` accesses `stack[base + slot]` where `slot` comes from bytecode. The sum `base + slot` can exceed `MaxStack - 1`. There is no runtime bounds check.

**Fix:** Add `if (frame_base + slot >= MaxStack) return error.StackOverflow` (or similar) to each access.

### C5. `stack[nrbase + ri]` without bounds check in `retSlowPath`

**File:** `src/lang/vm.zig:482,494`

Named return value access computes `nrbase = frame.base + fsig.arity` then indexes with `nrbase + ri` without checking bounds.

**Fix:** Validate `nrbase + ri < MaxStack`.

### C6. Bitwise operations lose precision via i64 → f64 → i64 roundtrip

**Files:** `src/lang/vm.zig:1647,1654,1661,1666,1682,1691`

All bitwise ops (`&`, `|`, `^`, `~`, `<<`, `>>`) compute an `i64` result and convert it to `f64` via `@floatFromInt`. `f64` has only 52 bits of mantissa. Integers >= 2^53 lose precision on conversion, causing silent data corruption. Example: `0x0020_0000_0000_0001` and `0x0020_0000_0000_0002` both map to the same f64.

**Fix:** Store bitwise results as a dedicated integer type, or only promote to f64 when value fits in 53 bits.

### C7. Range iterator `f64` stagnation → infinite loop

**File:** `src/lang/vm.zig:389-399`

`range_current` is `f64`. When iterating large ranges (e.g., `0..10^16`), once current exceeds 2^53, `current += 1.0` no longer changes the value. The comparison `current > max` never becomes true, producing an infinite loop.

**Fix:** Use integer arithmetic for integer ranges, or add an iteration cap guard.

### C8. `valueAsInt` UB on out-of-range f64 values

**File:** `src/lang/vm_state.zig:268-273`

`valueAsInt` checks integer-ness via `@trunc(n) == n` but does **not** check that the integer value fits in `i64`. An `f64` like `1e20` passes the integer-ness check, then `@intFromFloat(t)` produces undefined behavior (or panic in debug builds).

**Fix:** Add `if (t < minInt(i64) or t > maxInt(i64)) return error.TypeError`.

### C9. String concat length overflow

**File:** `src/lang/vm.zig:1930`

`const new_len = sa.len + sk.len` — both `usize`. The sum can overflow, wrapping to a small value that passes the `if (new_len <= acc.len)` check, causing a buffer overrun on the stack-allocated accumulator.

**Fix:** Add overflow detection (`@addWithOverflow` or `if (new_len < sa.len) return error.ChunkFull`).

---

## HIGH

### H1. `prepareVariadicCall` no guard on `stack_top - argc`

**File:** `src/lang/vm.zig:100`

Subtracts `argc` from `stack_top` without validation. If `argc > stack_top`, the subtraction wraps before any error is returned.

**Fix:** Guard with `if (argc > stack_top) return error.StackUnderflow`.

### H2. `@intCast(args.len)` truncation in public API

**File:** `src/lang/vm.zig:2651,2665`

`callGlobal` and `callFunction` call `@intCast(args.len)` to convert `usize` to `u8`. If `args.len > 255`, this panics (debug) or wraps (release), causing incorrect call setup.

**Fix:** Validate `args.len <= 255` before the cast.

### H3. `@intCast(ret_count)` truncation in panic unwind

**File:** `src/lang/vm.zig:2605`

`const n: u8 = @intCast(ret_count)` — if `ret_count > 255`, this panics or truncates.

**Fix:** Cap or validate `ret_count`.

### H4. `cast_int` range-check boundary is off by one f64 ULP

**File:** `src/lang/vm.zig:1696-1699`

`maxInt(i64) = 9_223_372_036_854_775_807` is not exactly representable in f64. `@floatFromInt(maxInt(i64))` rounds up to `2^63`. The check rejects `n >= 2^63` instead of `n >= maxInt(i64)`, allowing values in `[maxInt(i64), 2^63)` to pass through. These values cannot roundtrip through `valueAsInt`.

**Fix:** Use exact comparison: `if (@as(f64, @floatFromInt(n)) != n) ...`

### H5. `cloneValue` drops `variant_value.shared_values` and `arm_fields`

**File:** `src/lang/native/core.zig:619`

When cloning a `variant_value`, only `typ`, `tag`, `ordinal`, and `payload` are copied. `shared_values` and `arm_fields` are silently dropped, causing data loss.

**Fix:** Clone shared_values and arm_fields arrays.

### H6. Non-string assertion message silently loses data

**File:** `src/lang/vm.zig:2385`

```zig
vmState().pending_panic_message = vms.asStringValue(msg_val) catch "AssertionFailed";
```

If `msg_val` is not a string, `asStringValue` returns `error.TypeError` and the catch replaces it with a generic `"AssertionFailed"`, silently discarding the original message.

**Fix:** Convert non-string values to their string representation.

### H7. `chunk.reset()` does not clear peephole state

**File:** `src/lang/chunk.zig:39-41`

`reset()` only clears `code_len` and `const_count`. It does not clear `pending_col`, `last_const_code_pos`, `last_const_idx`, `last_get_local_code_pos`, or `last_triple_eq_pos`. Stale peephole tracker values persist across compilations.

**Fix:** Reset all state fields.

### H8. `emit2`/`emitOpConst` sets peephole tracker before fallible operation

**File:** `src/lang/chunk.zig:70-76,86-95`

Peephole state is updated before calling fallible `emitByte`/`emitConstIdx`. If the emit fails, the tracker is orphaned (pointing to a position where no instruction was written). While compilation aborts on error, the inconsistent state could interfere with error recovery.

**Fix:** Move peephole state updates after the fallible operations, or undo them on failure.

---

## MEDIUM

### M1. `chunk.reset()` does not clear all state

Same issue as H7 but with lower practical impact since compilation aborts on error.

### M2. `iterator.array` and `iterator.map` not GC-traced

**File:** `src/lang/vm_gc.zig:74-76`

The GC traces `it.source` (the source object) but not `it.array` or `it.map` slices. Currently safe because these slices alias the source object's backing memory, but this is a fragile invariant not documented in the GC code. Refactoring could break this assumption silently.

**Fix:** Trace `it.array` and `it.map` elements explicitly.

### M3. `set_named_predicate` stores any object as predicate without validation

**File:** `src/lang/vm.zig:2366`

The `set_named_predicate` opcode stores `pred.object` as the predicate on the named type without checking it's callable. The error is only caught later when the predicate is invoked, producing a misleading error.

**Fix:** Validate `pred.object.*` is `.function` or `.closure` before assigning.

### M4. No parse error recovery

**File:** `src/lang/compiler.zig`

The parser has zero error recovery — any syntax error immediately aborts the entire compilation. No token skipping, no error continuation, no partial AST. A single parse error in a large module discards all compilation work.

**Fix:** Implement error recovery with token skipping to synchronization points.

### M5. Circular cross-type struct references not detected

**File:** `src/lang/compiler_decls.zig:632-637`

Direct self-reference (struct A has a field of type A) is blocked, but circular cross-type references (A → B → A) are not detected. This causes infinite recursion at runtime.

**Fix:** Add cycle detection in struct type resolution.

### M6. `consume()` does not allow backtracking

**File:** `src/lang/compiler.zig:702-711`

When `consume()` fails, the lexer may be past the problematic token. No backtracking mechanism exists. If error recovery were added, the lexer state would be out of sync.

**Fix:** Save/restore lexer position around speculative parsing.

### M7. `repl_expr_pop_pos` underflow risk

**File:** `src/lang/compiler_stmts.zig:1159`

`c.repl_expr_pop_pos = chunk.codeLen() - 1` — if `codeLen()` returns 0, this wraps to `usize::MAX`, and the subsequent write at `compiler.zig:146` writes to an out-of-bounds address.

**Fix:** Guard with `if (chunk.codeLen() > 0)`.

### M8. Peephole `set_global_loop` fusion uses heuristic byte check

**File:** `src/lang/chunk.zig:300-310`

The fusion only checks the first byte of a 5-byte sequence matches `set_global`. Data bytes of a preceding multi-byte instruction could coincidentally have this opcode value at the check offset, causing incorrect fusion.

**Fix:** Verify all 5 bytes form a valid `set_global` instruction.

### M9. `asArraySlice`/`asMapSlice` use `unreachable` for unexpected types

**File:** `src/lang/vm_state.zig:302-307,325-331`

Both functions use `else => unreachable` instead of returning an error. All current callers guard the call with a type check, but a future caller that forgets will get UB.

**Fix:** Return `error.TypeError` instead of `unreachable`.

### M10. `wrapCycleValue` loses precision for large integer ranges

**File:** `src/lang/vm_types.zig:230-235`

`span = max - min + 1.0` — when `max - min > 2^53`, `+ 1.0` is a no-op. `fmod` on large f64 values also loses precision.

**Fix:** Use integer arithmetic for integer ranges.

### M11. `applyNamedTypeFn` succ/pred stagnation at large values

**File:** `src/lang/vm_types.zig:317-331`

`n + 1.0` where `n >= 2^53` rounds back to `n`. For cycle types, `wrapCycleValue` receives the unchanged value, causing incorrect wrapping. For non-cycle types, the range check may fire incorrectly.

**Fix:** Use integer arithmetic when values are integers.

---

## LOW

### L1. Module-level errors leave state in `.loading`

**File:** `src/lang/module_compile.zig:133-138,157-189`

When `compileBegunModule` fails, the module's state remains `.loading`. A subsequent import attempt triggers a misleading `error.ImportCycle` instead of reporting the original error.

### L2. Host modules bypass export validation

**File:** `src/lang/module_compile.zig:117-118`

Host module names are resolved directly without checking that the requested field exists. Field validation is deferred to runtime, masking missing-export errors.

### L3. String pool overflow returns wrong error type

**File:** `src/lang/lexer.zig:136-141,177`

When the 128KB string pool overflows, `outByte` returns `false` and the caller treats this as an unterminated string error — a misleading diagnosis.

### L4. `emitLoop` does not clear all peephole trackers

**File:** `src/lang/chunk.zig:304`

`emitLoop` clears `last_const_code_pos` but not `last_get_local_code_pos` or `last_triple_eq_pos`. While safe currently, a future change that emits a `get_local` after a loop could produce stale matches.

### L5. Triple-fusion peephole only works for `const_eq`/`const_sub`

**File:** `src/lang/chunk.zig:119-123`

`const_add` and `const_lt` are not eligible for triple fusion with `get_local`, even though the infrastructure exists. The quad fusion for `const_lt` works around this with direct byte inspection, creating inconsistency.

### L6. `opInvokeMethod` named-value branch validates arity but not recv_idx

**File:** `src/lang/vm.zig:1019`

`stack_top = recv_idx` — validates `argc != 1` but does not validate `recv_idx` is non-negative.

### L7. `asStringValue` silently caught in assertion messages

**File:** `src/lang/vm.zig:2385`

See H6 — non-string assertion messages degrade silently.

### L8. No parse recursion limit

**File:** `src/lang/compiler_expr.zig:246`

`parsePrecedence` is recursive for infix expressions. Deeply nested expressions could cause C stack overflow. No explicit recursion limit.

### L9. `parseFloat` handles `-` edge case correctly (defense-in-depth)

**File:** `src/lang/common.zig:24`

The function guards `if (i >= s.len or ...)` on line 25. Safe currently.

### L10. `fileExists` race condition

**File:** `src/lang/module_compile.zig:380-387`

Between the file existence check and the actual read in `loadSource`, the file could be deleted or modified. Minor — inherent to the two-step pattern.

---

## SUMMARY BY SEVERITY

| Level | Count | Key areas |
|-------|-------|-----------|
| CRITICAL | 9 | GC missing traces, stack underflow, bitwise precision, infinite loop, UB on large floats |
| HIGH | 8 | Stack guard missing, truncation, precision boundary, clone data loss, assertion message loss, peephole state |
| MEDIUM | 11 | GC transitive fragility, no error recovery, circular refs, unvalidated storage, peephole heuristics |
| LOW | 10 | Module state corruption, string pool error, recursion limit, race conditions |

### Recurring patterns

1. **`stack_top - N` without guard** — At least 6 locations across vm.zig
2. **`frame.base - 1` without guard** — 3 return paths vs 1 correctly guarded path
3. **`f64` as universal number** — Bitwise ops, range iterators, valueAsInt, wrapCycleValue, cast_int all lose precision for values >= 2^53
4. **Missing GC traces** — variant_value fields (critical), iterator slices (medium)
5. **Stale peephole state** — chunk.reset(), emitLoop, emit2 all have partial cleanup
6. **No parser recovery** — Any parse error kills the entire compilation; no error continuation
