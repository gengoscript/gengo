# Gengo VM Architecture

This document describes the bytecode virtual machine at a conceptual level: what the machine looks like, what its moving parts are, how they interact, and what invariants must hold at every point. It is the reference for VM changes, the hardening work, and onboarding new contributors to the runtime.

---

## 1. Overview

Gengo uses a **stack-based bytecode VM**. The compiler emits a flat array of bytes (the chunk) plus a pool of constants. The VM maintains an operand stack and a call-frame stack, reads one opcode at a time, and executes it.

The execution model is deliberately simple:

- No registers; all operands are pushed and popped from the stack.
- All heap memory goes through one allocator; the GC is a stop-the-world mark-and-sweep over that allocator.
- All name resolution (globals, struct fields) goes through explicit opcodes; there is no implicit environment chain at runtime.
- Closures capture upvalues through heap-allocated cell objects; the capture protocol is explicit and visible in the bytecode.

The source files for the components described here:

| Component | File |
|---|---|
| Value and Object types | `src/lang/value.zig` |
| Opcodes | `src/lang/op.zig` |
| Bytecode emitter (core ops only, plus constant folding) | `src/lang/chunk.zig` |
| Load-time fusion pass (core → fused/specialized ops) | `src/lang/fusion_pass.zig` |
| Fused → core defusion (reverse direction) | `src/lang/vm_defuse.zig` |
| VM state (stack, frames, etc.) | `src/lang/vm_state.zig` |
| Dispatch loop and op handlers | `src/lang/vm.zig` |
| GC | `src/lang/vm_gc.zig` |
| Heap allocator | `src/runtime/heap.zig` |
| Globals table | `src/lang/globals.zig` |

---

## 2. Value Representation

Every slot on the operand stack holds a `Value`. A `Value` is a tagged union with nine variants:

```
Value = int       f64         integer arithmetic (stored as double for uniformity)
      | float     f64         floating-point
      | decimal   i64         fixed-point (scale is stored in the named-type object, not here)
      | rune      u21         Unicode code point
      | boolean   bool
      | string    []const u8  STATIC BYTES ONLY — see the invariant below
      | error_value []const u8 same static-bytes rule
      | object    *Object     pointer into the GC object pool
      | null
```

**The `.string` invariant** — this is the most important rule in the entire value system:

> `.string` MUST only ever point at bytes with lifetime longer than any GC cycle: compile-time string literals, lexer-interned identifiers stored in the bump allocator, or entries in the chunk constant pool. It MUST NOT point at heap-managed backing bytes.

Any string whose bytes are heap-managed must be represented as an `object` pointing to a `.dyn_string` (owned bytes) or `.string_view` (borrowed view with a source pointer). Violating the `.string` invariant causes use-after-free or aliasing bugs when the GC sweeps the backing memory.

### 2.1 Object Types

An `Object` is a heap-allocated Zig union. There are currently 25 tags:

**Collections**

| Tag | Payload | Notes |
|---|---|---|
| `array` | `[]Value` | Static slice; length is fixed after creation. |
| `array_managed` | `[]Value` | Managed (GC-tracked) slice; GC frees the backing memory. |
| `map` | `[]MapEntry` | Ordered key-value pairs, static slice. |
| `map_managed` | `[]MapEntry` | Same with managed backing. |
| `map_hashed` | `MapHashedObj` | Open-addressed hash table; promoted from linear when the map grows. |

**Strings**

| Tag | Payload | Notes |
|---|---|---|
| `dyn_string` | `[]u8` | Owns heap-managed bytes. The GC frees the backing when the object dies. |
| `string_view` | `StringViewObj` | Borrows a sub-slice of a `dyn_string`. Holds a `source: *Object` pointer to keep the backing alive. The GC traces `source`. |
| `string_builder` | `StringBuilderObj` | Mutable buffer for incremental string construction (`std.string.builder`). |

**Functions and closures**

| Tag | Payload | Notes |
|---|---|---|
| `function` | `FuncObj` | Bytecode function: IP, arity, capture slots, optional type annotations. |
| `closure` | `ClosureObj` | Function + captured upvalue cells (`[]*Object`). |
| `cell` | `CellObj` | One `Value` stored on the heap so multiple closures can share it. |
| `native_function` | `NativeFuncObj` | Built-in Zig function, identified by a small integer ID. |
| `host_module_function` | `HostModuleFuncObj` | Function registered by the host embedder (WASM only). |

**Type objects** (live in globals, written once at script init)

`struct_type`, `interface_type`, `named_type`, `enum_type`, `variant_type`

**Value wrappers** (heap-allocated per construction)

`named_value`, `enum_value`, `struct_instance`, `variant_value`, `variant_ctor`, `named_type_fn`

**Utilities**

`iterator` — produced by `iter_init`, consumed by `iter_next1`/`iter_next2`.

---

## 3. The Chunk

A **chunk** is the unit of compiled code. One chunk covers one top-level script (or module). It has two arrays that are active during compilation:

```
code:   [MaxCode]u8        (1 MiB max) — raw bytecode bytes
consts: [MaxConst]Value    (4096 max)  — constant pool
```

Each byte position in `code` also has parallel `lines` and `cols` entries (both `u16`) for source-location reporting.

### 3.1 Constant Pool

Constants are `Value`s stored at compile time: string literals, integer and float literals, field name strings (for `get_field`/`set_field`/`invoke_method`), global name strings (for `get_global`/`def_global`), and type name strings (for `assert_interface`/`assert_struct`).

Constants are referenced by **u16 index** and encoded big-endian in the bytecode as two consecutive bytes.

### 3.2 Instruction Encoding

Instructions are variable-width. The first byte is the opcode. Subsequent bytes are operands whose types and widths are fixed by the opcode. Examples:

| Opcode | Width | Encoding |
|---|---|---|
| `null_val`, `add`, `halt` | 1 byte | op only |
| `get_local slot` | 2 bytes | op, slot |
| `constant idx` | 3 bytes | op, idx_hi, idx_lo |
| `get_global name_idx ic_slot` | 5 bytes | op, name_hi, name_lo, ic_hi, ic_lo |
| `get_field name_idx ic_type ic_fidx` | 6 bytes | op, name_hi, name_lo, ic_type_hi, ic_type_lo, ic_fidx |
| `get_local_get_field slot name ic` | 8 bytes | fused form; see §6 |

Jump offsets are **u32 big-endian relative offsets** in the chunk. Forward jumps (`jump`, `jump_if_false`, `jif_pop`) add the encoded offset to the IP after the instruction; backward jumps (`loop`, `set_global_loop`) subtract it. This keeps patching simple while still allowing chunks up to the full 1 MiB code limit.

---

## 4. Runtime State

The VM state lives in a `State` struct (`vm_state.zig`). All active-state switching is done by calling `setActive(*State)` on each component (chunk, heap, globals, vm_state) before running.

### 4.1 Operand Stack

```
stack:     []Value   (pre-allocated to max_stack at init)
stack_top: usize     (index of the next free slot; TOS is stack[stack_top - 1])
```

`vmPush(v)` writes `v` to `stack[stack_top]` and increments `stack_top`. `vmPop()` decrements `stack_top` and returns the value. Stack underflow and overflow are checked on every push/pop.

### 4.2 Call Frames

```
frames:    []Frame   (pre-allocated to max_frames at init)
frame_top: usize     (index of the next free frame slot)
```

A `Frame` captures the call site and the local-variable base:

```
Frame = {
    ret_ip:           usize      -- IP to restore on ret
    base:             usize      -- stack index of first local (arg 0)
    closure:          ?*Object   -- owning closure, or null for plain functions
    func_obj:         *Object    -- the function object (for type checking on ret)
    defer_base:       usize      -- defer_stack depth at call time
    has_typed_returns: bool
}
```

**Local variable `slot` in the active frame** is `stack[base + slot]`.

At the top level (no active frame, `frame_top == 0`), there are no locals. Top-level variables are globals.

### 4.3 Instruction Pointer

`ip: usize` — byte offset into the active chunk's code array. Each opcode handler advances `ip` by reading operand bytes with `vmByte()` (reads one byte and increments `ip`), `vmShort()` (reads big-endian u16), or `vmU32()` (reads big-endian u32).

### 4.4 Globals

The globals table (`globals.zig`) is a separate open-addressed hash table:

```
TableSize: 4096 slots (power of two)
MaxGlobals: 2048 entries (load factor ≤ 0.5)
```

Each entry stores a name (`[]const u8`) and a `Value`. Lookup is by string key with linear probing. `def_global` writes once at script init; `get_global`/`set_global` read and write during execution. See §7 for inline-cache acceleration.

### 4.5 Temp Roots

```
temp_roots:    [128]Value
temp_root_top: usize
```

Any in-flight `Value` that is not yet reachable from the stack or globals must be pushed here before any GC-triggering allocation. See §8 for details.

### 4.6 Defer and Panic State

```
defer_stack:  []Value    -- deferred callables pushed by defer_call
defer_top:    usize

is_panicking: bool
panic_value:  Value      -- value passed to panic()
recovered:    bool       -- set by std.core.recover()
panic_frames: []PanicFrame -- source locations for the panic traceback
```

---

## 5. Dispatch Loop

The main loop in `vm.zig` (`runInner`) reads one byte, switches on it, and executes the handler. The loop exits on `halt` or any unhandled error.

```zig
while (true) {
    const op_byte = try vmByte();
    vmperf.countOp(op_byte);
    switch (@as(Op, @enumFromInt(op_byte))) {
        .constant => { ... },
        .add      => { ... },
        // ... all opcodes
        .halt => break,
    }
}
```

All opcode handlers are plain Zig functions or inline code. The opcode byte is consumed before the handler runs; operand bytes are consumed by the handler itself.

### 5.1 Opcode Categories

**Stack manipulation**: `constant`, `null_val`, `true_val`, `false_val`, `dup`, `dup2`, `pop`

**Global access**: `def_global`, `get_global`, `set_global`

**Local access**: `get_local`, `set_local`

**Upvalue access**: `get_upvalue`, `set_upvalue`, `close_upvalue`

**Arithmetic and logic**: `add`, `sub`, `mul`, `div`, `mod`, `pow`, `neg`, `not`, `eq`, `gt`, `lt`, `bit_and`, `bit_or`, `bit_xor`, `bit_not`, `shl`, `shr`

**Type operations**: `cast_int/float/decimal/bool/string/rune`, `assert_type`, `assert_interface`, `assert_struct`, `type_name`

**Containers**: `build_array`, `build_map`, `build_struct_instance`, `get_index`, `set_index`, `get_slice`

**Field access**: `get_field`, `set_field`, `invoke_method`

**Iteration**: `iter_init`, `iter_next1`, `iter_next2`

**Control flow**: `jump`, `jump_if_false`, `jif_pop`, `loop`

**Closures**: `make_closure`

**Calls and returns**: `call`, `defer_call`, `defer_invoke_method`, `ret`, `repl_print`, `halt`

**Named types and variants**: `set_named_predicate`, `validate_type_default`, `variant_check`, `variant_payload`

**Assertions**: `op_assert`, `op_assert_msg`, `op_trap_check`

**Fused opcodes**: see §6.

### 5.2 TOS Caching (Tier 2, ratified 2026-07-19)

A **lazy one-slot top-of-stack cache** is threaded through `runInner` as a local `TosState{ v: Value, full: bool }`. The logical operand stack is conceptually `(memory stack) ++ (ts.v when ts.full)` — when `full`, the true top-of-stack value lives in `ts.v` (register-resident, not on the memory stack) instead of having been pushed and immediately popped again by the next instruction.

**Scope, deliberately narrow**: only three ops are converted to read/write the cache — `add_ret`, `ret_const`, `get_local_ret` (the `ret` family). `tosConverted(op)` is the single switch that decides this. Every other opcode runs unconverted and is guaranteed to see a fully materialized memory stack: the dispatch loop spills the cache (`tosSpill`, pushing `ts.v` back to memory if `full`) immediately before running any unconverted handler. Calls, GC-allocating paths, panics, and host-boundary returns therefore never have to reason about cache coverage — the cache is invisible to everything except the three converted ops.

**Why it's worth a dedicated cache slot for just the `ret` family**: profiling showed `doReturn`'s `movups` (the value copy from register to the frame's stack slot) accounted for 60% of its own samples — a pure store→load round trip for a value that the very next instruction (the caller resuming) would immediately load again. Caching the return value in a register-resident local instead of memory deletes that round trip for the hot path where a function's last statement is `return <expr>`.

**Measured result** (`branch spike/tos-caching`, commit `53fcc56`): fib 0.31s → 0.29s (-6%), `loop_sum` at exact parity (as expected — no `ret`-family instruction is on that benchmark's hot path). Full suite, differential, and both fuzz lanes green.

**Ratified decision**: Tier 2 (this mechanism, extended incrementally) is adopted; the full sweep beyond the `ret` family is **demand-driven**, not scheduled — extend it only if a real embedded workload shows call-dominated cost. A register-VM rewrite (Tier 3, Lua-parity territory) was declined absent a Lua-parity requirement: even a fully swept Tier 2 lands at roughly 3× Lua's per-instruction cost (a fundamentally different ISA is what closes that gap, not more caching within the stack ISA), and Gengo's target workloads (policy/validation/embedded rules) are not call-dense enough for that gap to matter in practice. This also unblocked GBC: Tier 3 would have meant deciding on a new instruction set before freezing a wire format; declining it let the wire format (§6.3) ratify without waiting on a performance-tier decision.

**Three binding implementation constraints**, found during the spike and worth preserving for anyone converting further ops:

1. **No `errdefer` in the dispatch function.** An `errdefer` that spills the cache on every `try`-edge was measured at +80% icache bloat on `loop_sum` (roughly 160 dispatch arms each gaining a spill pad). Error-path spilling is instead handled by narrow, explicit `catch` blocks only on the converted branch — every other branch already spills before running its handler, so unconverted ops never need an error-path spill at all.
2. **`ts` must be a register-promotable local, not a pointer parameter.** Passing it by pointer defeats the point of the cache — LLVM can only keep a plain local resident across the dispatch loop, not something reached through a pointer.
3. **The spill helper needs `exec_call_modifier`** (the same wasm/native dispatch-modifier split used throughout `runInner`) to behave consistently across targets — see §5's note on `exec_call_modifier` in the main dispatch loop.

Converted ops stay on `effectCheckExempt`'s list (§ handler code), so the Debug-mode `stackEffect` net-effect assertion — which walks the *unconverted* handler path — is unaffected by cache state.

---

## 6. The Fusion Pass

The compiler's `chunk.zig` emitter is a plain single-pass code generator: it
emits only **core ops** and never tracks or rewrites already-emitted bytes
(the one exception is constant folding — see §6.4). Every compile path
(`Runtime.compileOnly`, `compileProgram`, the REPL's `runIncremental`) then
runs the compiled chunk through `fusion_pass.fuse()`, a separate rewrite
pass that turns core-op bytecode into the VM's fused/specialized
instruction set before the verifier's final check and first execution.

This split — plain emission, then a dedicated rewrite pass — exists so
there is exactly **one** fusion implementation shared by fresh compiles and
(eventually) loads from the bytecode cache, instead of an emission-time
peephole and a separate load-time pass that could silently disagree. Prior
to 2026-07-19 the emitter carried its own peephole optimizer with 16
tracked positions and per-boundary invalidation logic; that machinery is
gone (`4ea7207`) now that the pass is load-bearing everywhere.

Fused instructions reduce dispatch count. They do not change observable
semantics: `vm_defuse.zig` expands any fused chunk back to core ops, and
the differential in `chaos_spec_test.zig` ("spec pass cases refuse
differential") proves compile → defuse → fuse → run reproduces the
original output for the entire spec corpus.

### 6.1 How the Pass Works

`fusion_pass.zig` treats every fusion as a rewrite of **adjacent
instructions** — a pair, or (for `local_add_local`/`local_add_field`/
`field_add_const`) a fixed 4-instruction window — with a single legality
rule: **the second instruction of the pair/window must not be a branch
target.** Function
entry points and module boundaries count as targets too, alongside jump
destinations. This one rule replaces the emitter's nine separate
invalidation blocks, because "is this position jumped to?" is exactly the
condition under which fusing across it would be unsound (something could
resume execution mid-fused-instruction).

The pass runs its pair/window rewrite to a fixpoint: each iteration can
fuse instructions that the previous iteration just made adjacent (e.g. a
triple forms, then a quad forms on top of the triple, then a quint on top
of that). A round-count safety valve stops runaway iteration; in practice
the fixpoint is reached in about 4 stages for the deepest chains (the
for-loop header quint, the recursive-call hexa-fusion chain).

### 6.2 Fusion Table

The mnemonic-level catalog of fused opcodes, their byte widths, and their
constituent core-op sequences is `docs/opcodes.md` — that is the single
source of truth (kept in sync with `op.zig`) and is not duplicated here.
As of 2026-07-19 the pass covers every fusion the old emitter peephole
covered, including the call-fusion chain
(`get_local_const_sub_call[_tail]`, `call_global_local_sub_const[_tail]`),
the for-loop header quint (`get_local_const_lt_jif_pop_jump`), and the
4-wide window fusions (`local_add_local`, `local_add_field`). A third
4-wide window fusion, `field_add_const` (`field = field + const`, e.g.
`c.tx_id = c.tx_id + 1`), was added 2026-07-20 — found independently in
two real embedder codebases as a transaction/packet-ID counter idiom
(issue #207). Unlike the other two, it delegates its read and write to
`opGetLocalGetField`/`opSetField` verbatim rather than reimplementing
their logic inline, since `set_field`'s type-coercion/const-field/
named-type/map-value-type handling is too complex to safely re-derive.

Several fused handlers include an integer fast-path: when both operands
are `.int`, the VM performs the addition/subtraction directly rather than
going through the generic `computeAddResult` path that also handles
strings, decimals, named types, and overflow.

### 6.3 Encoding Contract for Fused Opcodes

Each fused opcode occupies a fixed number of bytes. The VM handler reads
exactly those bytes. No fused instruction may straddle a jump target — the
pass's legality rule guarantees this at rewrite time, and the verifier
independently enumerates instruction boundaries over the already-fused
chunk, so a violation would be caught rather than silently corrupting
control flow.

A **skip byte** appears in some fused instructions (e.g.,
`get_local_const_add`) as the position that held one of the original
constituent opcodes before fusion. The VM handler reads and discards it.
This keeps the encoding width predictable and leaves room for an inline
cache slot at a fixed offset within the fused instruction.

Fused values are **frozen today, exactly like core ops** — see
`docs/opcodes.md`'s stability note. The GBC checklist below ratifies a
future where they become private and freely renumberable, but that only
takes effect once the bytecode cache ships a wire format that serializes
the defused (core-ops-only) form exclusively; no such loader exists yet.

### 6.4 Constant Folding Stays at Emission

Constant folding (e.g. `2 + 3` → the constant `5`, adjacent string literal
concatenation) is **not** a fusion and is not part of the pass — it
mutates the constant pool itself, which is wire content under the
bytecode-cache design, so it must happen once, at compile time, before any
chunk is written or cached. The emitter's constant-position trackers
(`last_const_code_pos` and friends) exist solely to support folding and
were deliberately kept when the fusion trackers were deleted.

### 6.5 Opcode Space Policy (ratified 2026-07-20, permanent)

The 0x00–0xBF (core, 192 slots) / 0xC0–0xFF (fused, 64 slots) split is
fixed policy — full rationale and the numeric slot summary live in
`docs/opcodes.md` ("Opcode space policy"), not duplicated here. The short
version: core is what GBC's wire format will encode, so a core slot spent
is permanent, while fused ops stay VM-private and renumberable forever
(this pass regenerates them fresh on every load). The reservation is
asymmetric because the cost of running out is asymmetric — core gets the
bigger cushion because its mistakes can't be taken back.

A WASM-style prefix-byte scheme for fused ops (marker opcode + a second
indexed dispatch into the real handler) was built as a working prototype
and measured: 9% slower on `fib_recursive`, 25% slower on `dispatch_loop`
(ReleaseFast, hyperfine). Rejected — the extra fetch + second dispatch
costs the most on exactly the instructions fusion targets (hot loop
back-edges). Do not re-propose a prefix or a u16 opcode field without new
measured data; if the 64 fused slots ever run out, the answer is
build/link-time-selected fused-op-set profiles, not a wire-format change.

---

## 7. Inline Caches

`get_global` and `get_field` have **inline caches** (ICs) baked into the instruction stream. The IC bytes start cold (all 0xFF) and are patched on the first successful resolution.

### 7.1 `get_global`

```
[get_global][name_hi][name_lo][ic_hi][ic_lo]    5 bytes
```

- Cold: `ic_hi:ic_lo = 0xFFFF`. Handler does a full hash-table lookup by name string, then patches the IC with the resolved slot index.
- Warm: `ic_hi:ic_lo` holds the slot index. Handler reads `globals.getAt(ic_slot)` directly — no string lookup.

### 7.2 `get_field`

```
[get_field][name_hi][name_lo][ic_type_hi][ic_type_lo]    5 bytes  (struct field)
```

- `ic_type` holds the heap object-pool index of the struct type last seen at this call site.
- If the receiver's type matches `ic_type`, the field is read by cached field index rather than by name scan.
- The fused `get_local_get_field` form appends one more IC byte for the field index directly.

IC mispredictions fall back to the cold path and re-patch. ICs are monomorphic: one type per call site.

---

## 8. Garbage Collector

### 8.1 Heap Layout

The heap has two regions:

**Object pool** — a fixed-size array of `Object` values with a free-list. Each `Object` slot is tracked by two parallel boolean arrays: `obj_live` and `obj_marked`. Allocation pops from the free-list; sweep iterates the live array and returns dead objects to the free-list.

**Managed memory** — a bump allocator backed by a single contiguous region, organized into **size classes** (16 B, 32 B, 64 B, ..., up to 2 MiB). Freed blocks are returned to per-class free lists. A live managed block is reachable only through an `Object` that owns it; the GC frees the managed block when the owning object dies.

### 8.2 Collection Triggers

Collection is triggered in `vmAllocObject()` and `vmAllocManagedSlice()`:

- When live object count reaches `next_gc_objects` (adaptive: `live * 2 + step`).
- When heap bytes used reaches `next_gc_heap_bytes` (adaptive: scales with heap fill level).
- In gc-stress mode: on every allocation.

### 8.3 Root Set

The mark phase roots from:

1. **Operand stack** (`stack[0..stack_top]`)
2. **Globals table** (all live entries)
3. **std_module** (the stdlib namespace object, held separately)
4. **Temp roots** (`temp_roots[0..temp_root_top]`)
5. **Chunk constant pool** (all constants)
6. **Defer stack** (`defer_stack[0..defer_top]`)

### 8.4 Mark Phase

The mark phase is **iterative** using a static worklist (`mark_worklist` array). Each object is marked before being enqueued, so no object is enqueued twice.

`drainMarkQueue()` processes the worklist: each dequeued object traces its children (array elements, map entries, closure upvalues, etc.) and enqueues any unmarked live children.

The `string_view` object traces its `source: *Object` pointer so that the backing `dyn_string` stays alive as long as any view into it is reachable.

### 8.5 Sweep Phase

`heap.sweepObjects()` iterates the live array and returns every unmarked live object to the free-list. Managed-memory blocks owned by dead objects are freed back to the appropriate size-class free list.

### 8.6 Temp Root Discipline

Any `*Object` or `Value` that is in flight (allocated but not yet reachable from the stack or globals) must be pinned in `temp_roots` before any allocation that could trigger GC. Failure to do so is a rooting-window bug: GC may collect the object mid-computation.

```
pushTempRoot(v)   -- add v to temp_roots
popTempRoot()     -- remove most-recently-pushed root
```

The temp root stack depth must be balanced across every code path: every `pushTempRoot` must have a matching `popTempRoot` on every exit, including error exits.

---

## 9. Call and Return Protocol

### 9.1 Call

Before `call argc` executes, the stack must look like:

```
... [func_value] [arg_0] [arg_1] ... [arg_{argc-1}]
                 ^--- stack_top - argc - 1 (func slot)
```

`performCall(argc)`:
1. Reads `func_value = stack[stack_top - argc - 1]`.
2. Dispatches on the object type:
   - **function/closure**: creates a `Frame`, sets `ip = f.ip`. Args are already at `stack[base..base+arity]`.
   - **native_function**: calls `callNative(nf, argc)` which pops args, calls the Zig function, and pushes the result.
   - **named_type**: constructs a named-type value (consumes one arg, pushes the wrapped value).
   - **variant_ctor**: constructs a variant value.
3. For bytecode functions, the existing stack slots become locals in the new frame. The func_value slot becomes the first out-of-frame slot; after `ret`, the return value is written there and `stack_top` is set to `func_slot + 1`.

### 9.2 Return

`ret` (and its fused forms `ret_const`, `get_local_ret`, `add_ret`):

1. Pops the current frame (`frame_top -= 1`).
2. Restores `ip = frame.ret_ip`.
3. Writes the return value to `stack[frame.base - 1]` (the slot that held the function before the call).
4. Sets `stack_top = frame.base` (discards all locals and the function slot, leaving only the return value at TOS).
5. Runs any pending deferred callables from `defer_stack[frame.defer_base..defer_top]`.

### 9.3 Tail Call

`tryTailCall(argc)` fires before `performCall` when certain conditions hold (calling a plain function and the current frame has no deferred calls and no typed return). It reuses the current frame instead of allocating a new one, enabling constant-space recursion.

---

## 10. Closures and Upvalues

When a function captures a local variable from an enclosing scope, the variable is stored in a `cell` object on the heap. Both the enclosing scope and the closure hold a pointer to the same cell.

`close_upvalue slot` — emitted when a captured local goes out of scope. It copies the current stack value into `cell.value` and updates the stack slot to hold the cell object. From this point, all reads/writes to that slot go through the cell.

`get_upvalue idx` / `set_upvalue idx` — read and write through `closure.upvalues[idx].cell.value`.

---

## 11. Panic and Recover

A script-level panic (`panic(msg)` or type/arithmetic errors) sets `is_panicking = true` and records the panic value in `panic_value`. The dispatch loop unwinds: `ret` opcodes and defer chains run normally, but the panic propagates upward until:

- `std.core.recover()` is called in a defer — sets `recovered = true`, clearing the panic.
- The top-level frame is reached — the engine reports the panic to the host.

The panic frame list (`panic_frames`) accumulates source locations as the stack unwinds, producing the traceback.

---

## 12. Key Invariants Summary

These are the properties that must hold at every point during execution:

1. **`.string` points only at immortal bytes.** All heap-backed text is `.dyn_string` or `.string_view`.

2. **Any in-flight object must be reachable from roots.** Between allocating an object and writing it to the stack or a stable location, it must be in `temp_roots`.

3. **`string_view.source` must be a live `dyn_string`.** The GC maintains this by tracing `source`; code must not construct a view whose source has been freed.

4. **`frame.base` + `local_slot` must be within `stack[0..stack_top]`.** Every `get_local`/`set_local` checks this.

5. **The temp-root stack must be balanced.** Every `pushTempRoot` has a matching `popTempRoot` on all exit paths.

6. **The defer stack must be balanced.** `frame.defer_base` marks where this frame's defers begin; `ret` runs exactly `defer_stack[defer_base..defer_top]`.

7. **Fused instructions are semantically equivalent to their constituent instructions.** The peephole may not change observable behaviour, including error conditions, side effects, and return values.

8. **Constant pool indices in bytecode are in range.** `constant idx` with `idx >= const_count` is a malformed instruction; the verifier (once present) must reject it.

9. **Jump targets land on instruction starts.** A jump to the middle of a multi-byte instruction is a malformed chunk.

10. **The GC mark phase visits every edge.** Any `Object` field holding a `*Object` or containing a `Value` that may be `.object` must be traced in `drainMarkQueue`. Missing an edge causes use-after-free.

---

## 13. Active-State Model

Each logical component has a global active state pointer and a `setActive(*State)` function:

| Component | State type | Set by |
|---|---|---|
| `chunk.zig` | `chunk.State` | `chunk.setActive` |
| `heap.zig` | `heap.State` | `heap.setActive` |
| `globals.zig` | `globals.State` | `globals.setActive` |
| `vm_state.zig` | `vm_state.State` | `vm_state.setActive` |

The engine wrapper (`src/engine.zig`) switches all four before every `run()` call so that each engine handle has its own isolated state. This is how multiple engine instances coexist in the same process.

The current model is **single-active**: only one runtime instance executes at a time within a thread. Reentrancy (calling back into the VM from a host callback while the VM is running) is not safe in the current design. See issue #172 for the architectural path toward explicit context pointers.
