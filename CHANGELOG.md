# Gengoscript Changelog

This changelog tracks notable language/runtime changes by implementation date.

## 2026-06-12 (v0.5.0-dev)

### Breaking — Boolean-Only Conditions (Go-Style)

`if`, `!`, `||`, `&&`, and template `{{if}}` now require actual `bool` values.
Non-boolean values that were previously treated as truthy/falsy (non-zero
integers, non-null strings, etc.) now produce a runtime `TypeError`. This
eliminates a class of subtle bugs where a non-boolean expression slips into a
condition. Use `std.conv.to_bool` for explicit conversion. See issue #109.

Positions affected:
- VM opcodes: `.jif_pop`, `.jump_if_false`, `.not`
- Template: `{{if}}` condition
- Array stdlib: `filter`, `find`, `findIndex`, `all`, `any` predicate return
- Sort stdlib: custom comparator fallback (non-int, non-float return)

The internal `isTruthy()` function on `Value` has been replaced with
`asBool()` that returns `TypeError` for non-boolean values. The errors name
the offending type and the remedy (`condition must be bool, got int; use a
comparison or std.conv.to_bool`; `predicate must return bool, got null`).
Fail tests: spec fail/196–199.

Named types over `bool` participate in conditions through their base
(`type Flag bool` makes `if Flag(true) { }` valid), the same way named
ints participate in arithmetic (spec 194). Generalising `subtype` beyond
numeric parents is tracked as #113.

`std.conv.to_bool` is the one explicit conversion and now treats heap-backed
strings like literals (`to_bool("")` and `to_bool(trim(" "))` are both
`false`) and converts named values through their underlying value
(spec 193).

### Fix — REPL Named Types Persistence Across Lines

`type`, `subtype`, `struct`, `interface`, and `variant` type declarations now
persist across `runIncremental` calls. Previously the `TypeRegistry` was reset
on each call, causing type annotations, `subtype`, and `var x TypeName` to fail
on subsequent REPL lines. Now the `Runtime` stores type names in the same
pattern as `repl_const_names`, and pre-populates the registry before
compilation while skipping `registry.reset()` in REPL mode. The persisted
name buffer is compacted per line with overlap-safe copies so earlier type
names survive later declarations. See issue #112.

### Fix — Diagnostics: Misleading Errors from Module Load, Host Imports, String Pool

Three misleading error scenarios are now fixed (see issue #98):

1. **Module load failure** — When a module's compilation fails, its record is
   now marked `.failed` instead of staying in `.loading`. A subsequent import
   of the same module re-reports the original compile error instead of a
   misleading `ImportCycle` error.
2. **Host module exports** — Accessing a non-existent field on a host module
   (e.g. `db.nonexistent()`) now produces a compile-time error instead of
   surfacing only at call time.
3. **Lexer string pool exhaustion** — When the 128KB string pool overflows,
   the lexer now reports `"string pool exhausted (max 128KB)"` instead of the
   misleading `"unterminated string"` error.

### Improved — Named String Types Concatenate

`+` on two values of the same named string type (or subtype) now works and
keeps the named type: `Html("<p>") + Html("</p>")` is an `Html`. Mixing
different named types or a named type with a bare string remains a
`TypeError`. See issue #110. Spec 192, fail/201–202.

### Fix — Regexp Character Class Leading Dash

A `-` at the start of a character class (`[-:]`) is now a literal dash, as
in every mainstream engine; previously the class silently matched nothing.
See issue #111. Spec 190.

### Fix — Named Types, Enums, and Variants Satisfy Interfaces

`matchesInterfaceType` only recognised struct instances; named values, enum
values, and variant values with matching methods now satisfy interface
checks too. Spec 191, fail/200.

## 2026-06-12 — v0.4.1

### Fixed — Cross-Platform Release Builds

v0.4.0 shipped no binaries: the release workflow failed to cross-compile.

- **macOS** — `timeval.usec` is `c_int` on Darwin but `i64` on Linux; the
  `cap:net` deadline code now casts to the platform's field types.
- **Windows** — `cap:fs` read/exists used `std.posix.openat` (absent on
  Windows) since the post-v0.3.1 perf rewrite (#73); on Windows they fall
  back to the `std.Io` implementation that v0.3.1 shipped.

No language or runtime behavior changes on Linux. Released from the
`release/0.4` branch (v0.4.0 content plus the build fixes).

## 2026-06-12

### Infrastructure — Versioning Discipline

The engine now carries a single source-of-truth version string (`0.4.0` in
`build.zig`) that is embedded in all artifacts:

- **CLI** — `--version` flag prints `Gengoscript v0.4.0` and exits.
- **C API** — `gengo_engine_version()` returns the bare, machine-parseable
  version string (`"0.4.0"`); display branding is left to the caller.
- **TS SDK** — `package.json` version is kept in sync with the engine.
- **README** — Status section documents pre-1.0 stability policy.
- **CONTRIBUTING** — Documents the versioning and tagging workflow.

Every breaking change from now on is tagged, documented in the changelog, and
never happens silently. See issue #106.

## 2026-06-11

### Breaking — Strict int/float Comparison

Ordering comparisons now follow the same strictness as arithmetic: `1.5 > 1`
is a `TypeError`, matching `1.5 + 1`. Previously comparison silently allowed
the mix while arithmetic rejected it. Equality (`==`) is unchanged and still
evaluates to `false` across types. (Precedent: Ada and Go forbid mixed typed
values in both arithmetic and comparison; their leniency exists only for
adaptable literals, which Gengoscript does not currently have.)

### Improved — Runtime Errors Explain Themselves

Type and range errors from arithmetic, comparison, unary negation, and
named-type construction now carry messages naming the operand types and the
remedy (`cannot mix Age and int; wrap the int with Age(...) or unwrap the
named value with int(...)`; `Age: -1 is outside 0..200`). The REPL prints
the same `--> repl:line:col` location block as file mode, and embedding
hosts receive the messages through the existing error buffers.

### Breaking — Strict Nominal Types in Arithmetic and Comparison

Named-type values no longer mix with bare base-type values in arithmetic,
comparison, or compound assignment. `Severity(4) >= 3` is now a runtime
`TypeError`; write `Severity(4) >= Severity(3)` or unwrap explicitly with
`int(s) >= 3`. Mixing two different named types was already rejected; this
closes the named+base loophole so a named value's domain guarantees cannot
be bypassed mid-expression. Fail tests: spec fail/189–191.

### Fix — Expression Recursion Depth Limit

Deeply nested expressions now fail compilation with `ExpressionTooDeep`
(limit 256) instead of risking a host stack overflow (#99).

### Fix — By-Value `api.Runtime.init` Allocates Heap Backing

`api.Runtime.init(config)` previously skipped heap initialisation on native
targets, so the first `run()` panicked; it now routes through
`initWithConfig` like the in-place initialiser (#100).

### Fix — Peephole Fusion Across Patched Jump Targets (BadConstantIndex)

Short-circuit boolean expressions whose operands compare a local against a
constant could panic at runtime with `BadConstantIndex` (e.g.
`if a == "x" || a == "y"` when the first comparison is true). The `||` / `&&`
short-circuit jump is patched to land at the current end of code; pending
peephole state survived the patch, so a following `jif_pop` quad-fused into
the instruction at the jump target, leaving the jump pointing at operand
bytes. `patchJump` now clears all fusion trackers — a patched jump target is
an instruction boundary. Regression test: spec 186.

### New Example — Mosquitto ACL Plugin

`examples/mosquitto-acl/`: a Mosquitto v5 broker plugin (C) that delegates
ACL and basic-auth decisions to a Gengoscript policy script via the C engine API.
Fail-closed, per-call instruction budget, SIGHUP policy reload.

## 2026-06-09

### Fix — NaN/Inf Rejection in VM Arithmetic and Comparisons

Non-finite float values now produce a runtime error at the point of use rather than propagating silently or causing undefined behaviour in debug builds.

- **Arithmetic**: `pushNumericResultWithCarrier` rejects non-finite results with `TypeError`. Integer overflow in decimal add/sub/mul now uses `@addWithOverflow`/`@subWithOverflow`/`@mulWithOverflow`; `minInt(i64) / -1` is guarded. String concatenation length overflow is detected via wrapping arithmetic.
- **Comparisons**: `gt`, `lt`, `const_lt`, and `get_local_const_lt_jif_pop` all guard against NaN/Inf operands (`TypeError`).
- **Decimal construction**: constructing a decimal named type from a float that is non-finite or out of `i64` range now returns `TypeError` instead of invoking undefined behaviour via `@intFromFloat`.
- **`succ`/`pred`**: stagnation check (`result == n`) catches Inf and values too large for f64 to increment; returns `RangeError`.
- **`int()` cast**: NaN and out-of-range floats return `RangeError` (consistent with other range-overflow paths).
- **`defer_call`**: stack underflow guard added.
- Conformance tests added: spec 165–171 (NaN/Inf failure cases), 172 (NaN detection), 173 (decimal overflow).

### Fix — Compiler Safety Guards

- `arity + named_return_count > MaxLocals` now returns `TooManyLocals` instead of silent miscount.
- Assignment path `step_count` (a `u8`) guarded against paths longer than 255 segments.
- `repl_expr_pop_pos` assignment guarded against `codeLen() == 0` underflow.

### ABI Change — Column Counters Widened to `u32`

`CompileError.col` and `RuntimeError.col` in `api.zig` (and the corresponding fields in `Compiler`, `Session`, `Runtime`, and `Engine`) have been widened from `u16` to `u32`. This prevents a debug-mode panic on source lines longer than 65 535 characters.

**Hosts must recompile against updated headers.** Any host reading `col` from a `CompileError` or `RuntimeError` struct compiled against the old layout will get incorrect values.

---

## 2026-06-08

### Embedding — Per-instance Resource Limits (#57)

`engine_init_with_config` now accepts an `InstanceConfig` struct (56 bytes, all `i64`/`u8`) that sets per-engine heap and execution limits, overriding preset defaults for that instance. Fields: `heap_size_bytes`, `max_objects`, `max_stack`, `max_frames`, `max_defers`, `max_ops` (`-1` = preset default), `allow_io`. See `docs/engine-api.md` for the full layout.

### Embedding — Custom Allocator in Engine Config (#71)

`api.Config` gains an `allocator` field (`std.mem.Allocator`, default `page_allocator`). The allocator is used for all per-instance backing memory and must remain valid until `rt.deinit()` is called. `Runtime.deinit()` added; required when using a non-default allocator.

### Embedding — ValueWire Exhaustive Mapping (#70)

`engine_call` / `engine_run` return values no longer silently drop non-primitive types. New mappings:

| Gengoscript type | Wire tag |
|---|---|
| `struct` | `5` (`map`) — field names as keys |
| `rune` | `1` (`number`) — Unicode code point |
| named/enum value | unwrapped to underlying wire type |
| `error` value | `1` (`number`), payload `-2` |

### Performance — `cap:fs` Cold-start (#73)

`fs.read` and `fs.exists` now use `std.posix.openat` + read loop directly instead of `std.Io.Threaded`. Eliminated ~900 ms startup cost from thread-pool and io_uring initialisation. Measured: ~2 ms per call.

### Fix — `engine_last_error` on Init Failure (#74)

`engine_init_with_config` returning `-3` (config ceiling exceeded) now writes a descriptive message to a module-level buffer (`g_init_error`). `engine_last_error(0, ...)` reads from this buffer when the handle is invalid, so callers can retrieve the failure reason without a valid engine handle.

### Fix — `cap:http` Availability

`cap:http` is now importable from Gengoscript scripts and dispatches to the host HTTP handler. Added conformance spec tests with a mock handler. HTTP calls still incur ~900 ms cold-start on the native CLI due to `std.Io.Threaded` in the HTTP implementation (tracked in issue #72).

### Fix — Template GC Safety

Three GC use-after-free bugs in template rendering corrected: `tplValToDynStr` result rooted across `tplAppendToBuilder`; template object and range array rooted across GC during rendering; `tplBuildObj` ops/args/jmp rooted before any allocation.

### Fix — Zig 0.16.0 Alignment Syntax

`heap.init` uses `.@"16"` alignment tag to satisfy the `?mem.Alignment` enum requirement in Zig 0.16.0 (`alignedAlloc(u8, .@"16", size)` instead of `alignedAlloc(u8, 16, size)`).

---

## 2026-06-07

- **Variant records**: variant types may now declare bare shared fields alongside arm declarations. Shared fields are unconditionally accessible on any value of the type without a match. Construction supplies shared and arm-specific fields together in one struct literal.
- **Multi-field variant arms**: variant arms may now use `{ field Type, ... }` syntax to carry a struct-like record payload. The payload struct is bound in pattern matching and accessed via dot.
- **fix**: predicate closure no longer collected by GC in long loops (`NotAFunction: inside predicate for X`). The `named_type` GC mark path now traces the predicate field.

## 2026-06-06

### Language — Predicate Subtypes

Named types may include a predicate body that is evaluated at construction time:

```gengo
type Port int predicate func(x) { return x >= 1 && x <= 65535 }
p := Port(80)    // ok
p2 := Port(0)    // PredicateViolation
```

- The predicate function takes the raw value and must return `boolean`.
- Construction raises `PredicateViolation` if the predicate returns `false`.
- The body compiles as a closure and may capture variables from the enclosing scope.

### Language — `std.string.contains` + `std.core.contains` TypeError

- `std.string.contains(s, sub)` — new function; returns `true` if `sub` appears anywhere in `s`.
- `std.core.contains(arr, value)` now raises `TypeError` when the first argument is not an array.

### Embedding — Host ABI v2

Extended host ABI with five new call IDs for `std.conv.*` and `std.core.bytelen`:

| ID | Name |
|----|------|
| `5` | `core_bytelen` |
| `6` | `conv_to_int` |
| `7` | `conv_to_float` |
| `8` | `conv_to_bool` |
| `9` | `conv_to_string` |

ABI version bumped to `2`. Capability bits `3`–`7` guard the new calls; the VM falls back to embedded implementations when a capability bit is absent.

### Embedding — Host-Defined Module Registration

Host code can register named modules that Gengoscript scripts import by name:

```c
gengo_host_module_func_def_t funcs[] = {
    { .name_ptr = (uintptr_t)"add", .name_len = 3, .arity = 2 },
};
engine_register_module(handle, "mylib", 5, funcs, 1);
```

Scripts import with the `host:` prefix: `mylib := import("host:mylib")`. Calls are dispatched via the host's `nativeCallRaw` implementation.

New engine exports: `engine_register_module`, `engine_set_write_fn`, `engine_last_error_line`, `engine_last_error_col`.

### Embedding — ValueWire Arrays and Maps

Two new `ValueWire` tags:

| Tag | Name | `payload` | `len` |
|-----|------|-----------|-------|
| `4` | `array` | pointer to element sequence in engine memory | element count |
| `5` | `map` | pointer to interleaved key/value pairs in engine memory | pair count |

### Embedding — Native Shared Library (`libgengo-engine`)

New build targets produce a native shared library with the same API as `gengo-engine.wasm`:

```bash
zig build -Dpreset=dev engine-native          # debug build
zig build -Dpreset=dev engine-native-release  # optimised build
```

Output: `zig-out/lib/libgengo-engine.so` (Linux), `.dylib` (macOS), `.dll` (Windows).

The C header `gengo-engine.h` documents the full API. All pointer parameters use `uintptr_t` so the API is correct on 64-bit hosts as well as 32-bit WASM.

`engine_set_write_fn` must be called to receive output; the native target has no WASM import shim to capture writes.

### Embedding — TypeScript SDK

`sdk/typescript/` — a TypeScript wrapper for `gengo-engine.wasm` with a typed `GVal` encoding/decoding layer and a high-level `GengoEngine` class.

### REPL Improvements

- **Auto-print** — top-level expression results are automatically printed in the interactive session.
- **Typed redeclaration detection** — redeclaring a typed global with a conflicting type is now a compile error.
- **Error display** — compile errors show the source line with a caret pointing at the bad token.

Invoke the REPL by running `gengo` with no arguments on an interactive terminal.

### Platform — Windows Native CLI

The native CLI now builds and runs on Windows without libc (`no-libc` mode). Release CI re-enabled for `x86_64-windows`.

### Removed — `std.time.sleep`

`std.time.sleep` was removed from the standard library.

---

## 2026-06-05

### Language — Compile-time Field Validation on Imported Modules

The compiler now validates field accesses on imported module namespaces at compile time. Accessing a name that is not exported by the module raises a `CompileError` instead of silently producing `null` at runtime.

### Runtime — Typed Array Element Enforcement

Variable declarations typed as `[T]` (e.g., `items [int] = ...`) now enforce element types on every assignment, not only at initial construction.

### VM / GC Bug Fixes

- GC marking: verify that an iterator's source object is live before tracing its children (#28).
- GC: retry closure upvalue bump allocation after triggering a collection (#27).
- `for-in break`: correctly clean up the iteration stack frame to avoid a stack leak (#29).
- `cast_int` from float: bounds-check before truncating to prevent integer wrap-around (#30).
- Rune cache: fix overflow flag and validity ordering for strings near the cache boundary (#31).
- Defer + panic: release temp GC roots when `retSlowPath` fails mid-defer execution (#32).

---

## 2026-06-04

### Language — Tail-Call Optimization

Self-recursive and mutually recursive tail calls are now compiled into back-edge jumps rather than new call frames. Deep recursion (tested at 10 000 levels) no longer overflows the call stack.

### Standard Library — `std.regexp`

Regular expression matching with a backtracking NFA engine:

```gengo
std := import("std")
assert(std.regexp.match("^hello", "hello world"))
found := std.regexp.find("world", "hello world")  // "world"
all   := std.regexp.find_all("a", "banana")        // ["a", "a", "a"]
r     := std.regexp.replace("world", "hello world", "there")
parts := std.regexp.split(",", "a,b,c")            // ["a", "b", "c"]
```

`std.regexp.compile(pattern)` returns a reusable compiled regexp object that also supports method-call syntax (`re.match(s)`, `re.find(s)`, etc.).

Errors: `InvalidRegexp` on a malformed pattern.

Supported syntax: `.` `*` `+` `?` `^` `$` `|` `()` `[...]` `[^...]` character classes and ranges, `\d` `\D` `\w` `\W` `\s` `\S` shorthands.

### Standard Library — `std.io.sprintf`

`std.io.sprintf(fmt, ...args)` — like `std.io.printf` but returns the formatted string instead of printing it.

Additional verb: `%x` / `%X` — hexadecimal integer.

---

## 2026-06-03

### Build — Native Zig Test/Bench Runners

Replaced all shell-script test/bench harnesses with native Zig executables built and run directly by `build.zig`:

- `src/test_runner.zig` — unified runner for conformance, benchmarks, and parity tests
- `src/bench_perf_runner.zig` — perf-counter benchmark runner

Removed:
- `tests/run_conformance.sh`
- `tests/run_bench.sh`
- `tests/run_host_parity.sh`
- `scripts/perf/run.sh`

No `WASMTIME_BIN` environment variable is required. The `-Dwasmtime=` build option (default `wasmtime`) is passed directly to the native runners.

## 2026-06-01

### Language — Zig-style `\\` Multiline Strings

Multiline string literals now use `\\` prefix on each line, identical to Zig.

- Content after `\\` is taken **literally** — no escape processing.
- Each line contributes its content plus a trailing newline (including the last line).
- Consecutive `\\` lines at any indentation are joined into a single string value.
- A blank line or any non-`\\` line terminates the literal.

```gengo
msg :=
    \\Hello, world!
    \\Escape seqs like \n and \t are NOT processed.
    \\Quotes like "this" need no backslash.

std.io.print(msg)
```

The old continuation-marker multiline syntax (repeating the opening quote at the
same indentation column) has been removed. Single-line `"..."` and `'...'`
strings are unchanged; they now reject embedded newlines rather than silently
treating them as a continuation attempt.

**New:** `std.io.print(...args)` — prints without a trailing newline, useful
when printing `\\` multiline strings that already end with `\n`.

### VM — Monomorphic Inline Caches for Struct Access

Three self-patching call-site caches eliminate the dominant hot-path costs for
struct-heavy code.

**`get_field` / `set_field` opcodes** replace `constant(name) + get_index` /
`constant(name) + set_index` for all dot-access (`.field`) reads and writes.
Each instruction embeds a 2-byte type-pool index and 1-byte field index as a
cold slot (0xFFFF / 0xFF). The first execution does a `findFieldIndex` linear
scan and writes the results back into the live bytecode. Every subsequent call
to the same struct type reads the cached slot index directly — O(1) instead of
O(fields).

**`invoke_method` IC** — four bytes appended after `argc` (ic_type:u16,
ic_func:u16) cache the struct type and resolved function object pool indices.
On a hit the function value is fetched directly, skipping the
`"TypeName.method"` string construction and `globals.get()` hash lookup.

All non-struct access paths (maps, enum types, named types, variant types) fall
through to the existing logic; the IC bytes are simply read and discarded.

Compiler: `infixExpr`, `deferStmt`, `emitAssignTargetPath`, and
`propertyAssignStmt` updated. `propertyAssignStmt` refactored to track last
step kind; compound assignment (`+=` etc.) on a dot field now emits
`dup + get_field + expr + op + set_field` instead of `dup2 + get_index + …`.

## 2026-05-31 (6)

### VM — Iterative GC Marking

Replaced the recursive `markObject` traversal with an explicit worklist-based marking phase. A file-local `mark_worklist[MaxObjects]` array holds pending objects; each object is marked *before* being queued, so it can never appear twice. The previous recursion depth was proportional to the live-object graph depth (worst case MaxObjects = 2048 frames), which could overflow the native stack in WASM for pathological inputs. The new approach processes all reachable objects in bounded O(live_objects) iterations with no recursion.

### VM — `std.string.builder`

New `std.string.builder()` native that creates a mutable string accumulator backed by the managed heap's size-class allocator. Internal buffer doubles (via the next size class) each time the content overflows capacity, giving O(total_bytes) total work for N appends versus O(N²) for repeated `s = s + piece` concatenation.

```gengo
std := import("std")
b := std.string.builder()
b.write("hello")
b.write(", world")
std.io.println(b.str())   // "hello, world"
b.reset()
b.write("again")
std.io.println(b.str())   // "again"
```

Methods: `.write(s string)`, `.str() string`, `.reset()`.

### Compiler/VM — Constant pool expanded to 512 (u16 indices)

Constant indices are now encoded as 2-byte big-endian `u16` values instead of 1 byte. The pool limit rises from 256 to 512 unique constants per compilation unit. String constants continue to be deduplicated, so the effective headroom for large scripts is significantly higher. All opcode sequences that reference the constant pool (`constant`, `def_global`, `get_global`, `set_global`, `make_closure`, `invoke_method`, `defer_invoke_method`, `variant_check`) now consume one extra byte per reference.

## 2026-05-31 (5)

### Type System — Subtype Declarations (Stage 3)

Subtypes create a constrained view of an existing named scalar type with an explicit, tracked ancestry relationship.

**Declaration syntax:**
```gengo
type Percent int range 0..100
subtype FailingGrade Percent range 0..59
subtype PassingGrade Percent range 60..100
```

The `range` clause is optional; if omitted the subtype inherits the parent's range. The subtype's range must lie within the parent's range (compile-time `RangeError` if violated).

**Widening (implicit, safe):** A subtype value is accepted anywhere its parent (or any ancestor) type is expected:
```gengo
func showPercent(v Percent) { std.io.println(v) }
showPercent(FailingGrade(40))  // OK: FailingGrade widens to Percent
```

**Narrowing (explicit, range-checked):** Assigning a parent value to a subtype variable requires an explicit constructor call:
```gengo
base Percent = Percent(30)
narrow FailingGrade = FailingGrade(base)  // range-checked at runtime
```

**Arithmetic with subtypes:**
- `T_sub op T_sub → T_sub`, range-checked against the subtype's range
- `T_sub op T_parent → T_parent`, range-checked against the parent's range
- `T_parent op T_sub → T_parent`, same
- `T_sub op T_sibling → TypeError` (siblings of the same parent do not implicitly unify)

**Comparison with subtypes:**
- `T_sub cmp T_parent → bool` and `T_parent cmp T_sub → bool` are allowed
- `T_sub cmp T_sibling → TypeError`

**Type attributes** (`T.name`, `T.first`, `T.last`) work on subtypes and reflect the subtype's own name and range.

## 2026-05-31 (4)

### Type System — Variants + Pattern-Matching Switch (Stage 5)

**Variant type declarations:**
```gengo
type Decision variant {
    allow,
    deny(reason string),
    review(reason string)
}
```
Each arm may have zero or one payload (optionally with a field name for documentation). Multiple fields can be composed via a struct payload.

**Construction:**
- Payload-less arm: `Decision.allow` — returns a variant value directly
- Payload arm: `Decision.deny("msg")` — calls the arm constructor with the payload; type-checked at construction

**Pattern-matching switch** with `.arm_name` patterns:
```gengo
switch d {
    case .allow { std.io.println("allowed") }
    case .deny(reason) { std.io.println("denied:", reason) }
    default { }
}
```
The `.` prefix signals a variant arm pattern. Inside a function, the binding variable (`reason`) is a scoped local; at global scope it becomes a global.

**Type annotations:** `func handle(d Decision)` enforces that arguments are `Decision` variant values.

**Type attribute:** `Decision.name` returns the type name string.

**printValue:** variant values print as `TypeName.tag` or `TypeName.tag(payload)`.

**New opcodes:** `variant_check` (pop dup'd value, push bool matching arm tag), `variant_payload` (pop variant value, push payload).

## 2026-05-31 (3)

### Type System — Type Attributes (Stage 4)

Type objects now expose read-only attributes via `.name` property access.

**Named scalar types** (`type T int/float/... [range lo..hi]`):
- `T.name` → string name of the type
- `T.first` → named value `T(min)` — requires a range constraint, TypeError otherwise
- `T.last` → named value `T(max)` — same

`T.first` and `T.last` return proper named values so they can be used directly wherever a `T` is expected, including comparisons and return statements:
```gengo
func clampMonth(n int) Month {
    if n < Month.first { return Month.first }
    if n > Month.last { return Month.last }
    return Month(n)
}
```

**Enum types** (`type T enum { a, b, ... }`):
- `T.name` → string name of the type
- `T.first` → first enum value (ordinal 0)
- `T.last` → last enum value
- `T.values` → `array` of all enum values in declaration order

## 2026-05-31 (2)

### Type System — Typed Collections (Stage 2)

**Type annotations:**
- `array[T]` — typed array annotation; any array whose elements all satisfy `T`
- `map[K, V]` — typed map annotation; any map whose keys satisfy `K` and values satisfy `V`
- Unparametrized `array` and `map` continue to work as before (accept any element types)

**Named collection types:**
- `type Users array[User]` — nominal array type; only `Users([...])` produces a `Users` value
- `type Index map[string, User]` — nominal map type; same pattern
- Construction validates all elements/keys/values against the declared constraints

**Enforcement points:**
- Function parameters: `func f(ps array[Point])` rejects arrays with non-Point elements
- Struct fields: `type Batch struct { users Users, }` rejects non-Users values at assignment
- `std.core.append`: element type is checked when appending to a named array; named type is preserved in the return value
- Index assignment (`users[0] = x`): element type is checked on named array types
- Map insertion (`idx["k"] = v`): key and value types are checked on named map types

**All std.core collection functions** (`len`, `append`, `contains`, `remove`, `has`, `delete`, `keys`, `values`) transparently handle named collection types by unboxing.

## 2026-05-31

### Type System — Named Scalar Operator Enforcement (Stage 1)

Named scalar types now form proper nominal domains inside expressions, not just at
variable/field/parameter boundaries.

**Arithmetic rules:**
- `T op T → T`, result range-checked against the named type constraints
- `T op base → T`, result range-checked
- `base op T → T`, result range-checked
- `T op U → TypeError` when T and U are different named types

**Comparison rules:**
- `T cmp T → bool`
- `T cmp base → bool` (compares underlying value; e.g. `Age(20) == 20` is `true`)
- `base cmp T → bool`
- `T cmp U → TypeError` when T and U are different named types

**Unary operators:**
- `-T → T`, range-checked (e.g. `-Age(5)` is `RangeError` if range is `0..100`)
- `~T → T`, range-checked

**Explicit conversion remains the sanctioned escape hatch:**
- `int(age) + int(score)` is always allowed; the cast strips the named domain

## 2026-05-30

### Language
- Removed `var` keyword. Mutable typed declarations now use bare space syntax: `x int = 10`.
- Made function parameter types mandatory. Untyped params (`func f(x)`) are now a compile error.
  - Use `any` to explicitly accept any type: `func f(x any)`.
- `any` is now a first-class predeclared type equivalent to an empty interface. Every value satisfies it.
- Fixed GC corruption in `build_array`, `build_map`, and `build_tuple`: objects are now initialised to a valid empty state immediately after allocation, before any subsequent allocation that could trigger collection.

### Type Syntax (space everywhere, colon removed)
- All type annotations now use space syntax uniformly:
  - Struct fields: `type S struct { x int, y int }` (colon form `x: int` removed)
  - Function params: `func f(a int, b int)` (colon form `a: int` removed)
  - Typed variable declarations: `x int = 10` (colon form `x: int = 10` removed)
  - Single return: `func f(a int) int`
  - Multi-return: `func f() (result float, err ?error)` (parens required for 2+ returns)

## 2026-05-28

### Runtime / VM
- Added runtime instruction budget guard:
  - CLI flag `--max-ops <N>`
  - runtime error `InstructionBudgetExceeded` when budget is exhausted.
- Added `Runtime`-level isolation validation with interleaved multi-runtime mutable-call checks.
- Migrated runtime state ownership to per-instance activation model across:
  - `chunk`
  - `globals`
  - `heap`
  - `vm`
- Removed snapshot/restore-based runtime copy-back path and switched to active-state pointer activation.
- Added host-facing embedding layer:
  - `runtime/api.zig`
  - typed run/call result contracts for compile/runtime errors.
- Added embedding API validation runner (`embedding_runner.zig`) and hooked it into `zig build test`.

### Language
- Added `const` immutable bindings while keeping `:=` as first-class mutable declaration syntax.
- Added const binding enforcement (`AssignToConst`) for reassignment, compound assign, inc/dec, and direct multi-assign targets.
- Added declaration-side variadics (`...args`) with typed variadic argument enforcement.
- Added `std.io.printf(fmt, ...args)` with `%v`, `%s`, `%d`, `%f`, `%t`, and `%%`.
- Added Ada-inspired nominal scalar and range types:
  - `type Name Base`
  - `type Name int range a..b`
- Added runtime named-type constructors and range checks (`RangeError` on violation).
- Added enums:
  - `type Status enum { ... }`
  - qualified member access (`Status.pending`)
  - unqualified enum members no longer implicit globals.

### Benchmarks
- Added runtime call overhead benchmark:
  - `examples/bench/008_runtime_call_overhead.gengo`

## 2026-05-27

### Language
- Added multiline string literals for both escaped (`"`) and raw (`'`) modes.
- Added explicit multiline continuation marker behavior based on opening-quote indentation column.
- Added function parameter annotation support in both forms:
  - `param: Type`
  - `param Type`
- Added anonymous-function typed-parameter parser regression coverage (`t.value` selector case).
- Added `std.conv` namespace:
  - `to_int`
  - `to_float`
  - `to_bool`
  - `to_string`
- Switched string semantics to UTF-8 rune-oriented behavior:
  - `std.core.len` counts runes
  - string index/slice operate on rune positions
  - string iteration yields runes and rune indexes
- Added `std.core.bytelen` for raw UTF-8 byte length.
- Added first-class `rune` scalar and rune literals using backticks (single code point).
- Added rune/number numeric operator compatibility and cast coverage.

### Runtime / VM
- Added first-class `error` value helpers:
  - `std.core.error(msg)`
  - `std.core.is_error(v)`
- Added map/array/tuple multi-assignment and multi-return destructuring support.
- Added `switch` support (`case`/`default`, no fallthrough).
- Added GC-managed dynamic strings and managed collection storage paths.
- Added mark-sweep GC improvements:
  - proactive object threshold collection
  - heap-pressure-triggered collection
  - temp GC roots for in-flight allocations during native/build paths
  - stale/non-live object guard during mark traversal
- Added `std.core.gc_stats()` with:
  - `heap_used_bytes`
  - `heap_size_bytes`
  - `live_objects`
- Enabled host-backend parity for VM-local natives (`core.error`, `core.is_error`, `core.gc*`, `conv.*`) by executing them in guest VM.

### Limits / Memory
- Increased runtime heap arena default to `512 KiB`.
- Fixed managed block free behavior for dynamic-string class-sized blocks.
- Added build-time runtime limit presets:
  - `runtime/config_dev.zig`
  - `runtime/config_tiny.zig`
  - `runtime/config_stress.zig`
  - Make targets: `config-*`, `wasi-tiny`, `wasi-stress`

### Conformance
- Expanded spec coverage across:
  - struct contracts and methods
  - closures/upvalues
  - iteration forms
  - multi-return and path assignment
  - GC stress and dynamic string churn
  - multiline string pass/fail cases
- Added benchmark suite harness:
  - `examples/bench/*` with checked outputs
  - `tests/run_bench.sh`
  - Make targets: `bench`, `bench-tiny`, `bench-stress`
  - bench `.policy` support (`ALLOW_OOM`) for expected low-memory outcomes
  - `GENGO_BENCH_STATS=1` mode for elapsed/ops reporting
- Added backend parity harness:
  - `examples/parity/*`
  - `tests/run_host_parity.sh`
  - Make target: `parity`
- Added host-backend graceful fallback when host import is unavailable.

### Planning
- Added Host ABI parity roadmap document: `archive/host-abi-v2-plan.md`.

## 2026-05-26

### Language Foundation
- Established `std`-only import policy (`import("std")`).
- Added named function declaration sugar (`func name(...) { ... }`).
- Added strong struct contracts with typed/nullable/union fields.
