# gengo Language (Current Behavior)

This document defines the current language behavior implemented by gengo.
It is intentionally versioned by implementation reality, not Tengo compatibility.

Companion guides:
- `docs/tutorial-first-script.md`
- `docs/quickstart.md`
- `docs/stdlib.md`
- `docs/testing.md`
- `docs/host-abi.md`
- `docs/host-abi-v2-plan.md`
- `docs/changelog.md`

## 1. Positioning

- `gengo` is a Tengo-inspired language, but compatibility is not guaranteed.
- Breaking changes are expected while the language surface is still being defined.

## 2. Modules and Builtins

- The only supported import module is `"std"`.
- `import("std")` returns a module map with namespaces.
- Builtins must be called via namespace access (dot + call), for example:
  - `std.io.println(...)`
  - `std.core.len(x)`
- Legacy global builtins like `println(...)` and `len(...)` are intentionally not supported.

## 3. Values and Types

Implemented value kinds:
- `number` (floating-point)
- `rune` (Unicode code point scalar)
- `boolean`
- `string`
- `error` (first-class error value)
- `null` (also tokenized as `undefined`)
- `array`
- `map`
- nominal struct types and struct instances
- function values (`func(...) { ... }`)
- native function values (internal, exposed via `std`)
- rune literal (numeric code point) via backtick syntax: `` `x` ``

### String Literals
- Standard escaped strings use double quotes: `"..."`.
- Raw strings use single quotes: `'...'` (no escape processing).
- Multiline strings are supported for both quote styles.
  - Continuation requires the next line to place the matching quote marker at the same indentation column as the opening quote.
  - The continuation marker and host indentation to its left are stripped.
  - Newlines between continuation lines are preserved.
- Strings are UTF-8 sequences.
  - `std.core.len(s)` counts Unicode code points (runes), not bytes.
  - `s[i]` indexes by rune position.
  - `s[a:b]` slices by rune positions.
  - `for ch in s` and `for i, ch in s` iterate by rune (with `i` as rune index).

### Rune Literals
- Syntax: backtick single-code-point literal, for example:
  - `` `A` ``
  - `` `å` ``
  - `` `🙂` ``
- Semantics:
  - evaluates to `rune` equal to Unicode code point value.
  - literal must contain exactly one code point.

## 4. Variables and Assignment

- Declaration: `name := expr`
- Assignment: `name = expr`
- Multi-declaration destructure: `a, b := expr`
- Multi-assignment destructure: `a, b = expr`
  - RHS may be a multi-return function or comma expression list.
  - Arity must match exactly, otherwise `ArityMismatch`.
  - For `=`, each target may be:
    - identifier (`a`)
    - property path (`obj.k.subk`)
    - indexed path with literal index/key (`arr[0]`, `m["k"]`, and mixed chains)
- Compound assignment: `+=`, `-=`, `*=`, `/=`
- Increment/decrement: `x++`, `x--`

## 5. Expressions and Operators

Implemented operators:
- Arithmetic: `+ - * / %`
- Comparison: `== != < <= > >=`
- Logical: `&& || !`
- Unary negation: `-x`
- Property access: `obj.field` (compiled as map-key lookup using string key)
- Index access: `container[index]`
- Slice access:
  - `x[a:b]`
  - `x[:b]`
  - `x[a:]`
  - `x[:]`

- Cast intrinsics: `int(x)`, `float(x)`, `bool(x)`
  - currently accept number/rune/boolean inputs
  - unsupported source types raise `TypeError`

## 6. Collections and Structs

### Arrays
- Literal: `[1, 2, 3]`
- Index read/write supported.
- Slicing supported.

### Maps
- Literal supports identifier keys and expression keys:
  - `{a: 1}` is shorthand for `{"a": 1}`
  - `{ "x": 2 }` also supported
- Index read supported: `m[key]`
- Missing key read returns `null`.
- Index write updates existing keys or inserts a new key if no existing entry matches.
- Field values are dynamic. Reassigning a field to another type can make later nested access fail at runtime (for example, `obj.a = 11` then `obj.a.b` raises `TypeError`).

### Structs
- Declaration: `struct Name { field1, field2, ... }`
- Optional typed fields: `struct User { id: int, name: string, addr: Addr }`
- Nullable types: `?T` (example: `nick: ?string`)
- Union types: `A|B` (example: `id: int|string`)
- Struct type references require prior declaration (no forward/self references).
- Duplicate struct type names are compile errors.
- Construction: `Name{ field1: value1, field2: value2 }`
- Contract rules:
  - unknown fields are errors
  - missing fields are errors
  - duplicate fields are errors
  - typed fields enforce type at construction and assignment
- Field access/write uses dot or index with string keys and must reference declared fields.

## 7. Control Flow

- `if / else if / else`
- `switch` with block-style cases (no fallthrough):
  - `switch expr { case value { ... } default { ... } }`
- `for` loops:
  - condition style: `for cond { ... }`
  - C-style: `for init; cond; post { ... }`
  - sequence/map iteration: `for x in seq { ... }`, `for k, v in seq_or_map { ... }`
- `break` and `continue` supported inside loops.
- `return` supported inside functions.

## 8. Functions

- Function literal: `func(args...) { ... }`
- Named function declaration sugar: `func name(args...) { ... }`
- Parameter annotations currently support both forms:
  - `func f(x: T) { ... }`
  - `func f(x T) { ... }`
- Parameter types are enforced at call-time; mismatches raise `TypeError`.
- Calls with strict arity checking.
- Return supports multiple values: `return a, b, c`
- Nested functions supported within configured limits.

## 9. Standard Library (`std`)

Current module map:
- `std.io.println(...args)`
  - prints values and newline
  - returns `null`
- `std.core.len(x)`
  - supports string, array, map, struct instance
  - returns number length
- `std.core.bytelen(s)`
  - supports string values
  - returns raw UTF-8 byte length
- `std.core.append(arr, ...items)`
  - first argument must be array
  - returns a new array with appended elements
- `std.core.error(msg)`
  - `msg` must be string
  - returns an `error` value (`error(msg)` when printed)
- `std.core.is_error(v)`
  - returns `true` if `v` is an `error` value, else `false`
- `std.core.gc()`
  - triggers mark-sweep collection for heap objects
  - returns `null`
- `std.core.gc_live_objects()`
  - returns current live object count as `number`
  - includes runtime object-backed strings created by operations such as concatenation/slicing/indexing
- `std.core.gc_stats()`
  - returns a map with:
    - `heap_used_bytes`
    - `heap_size_bytes`
    - `live_objects`
- `std.conv.to_int(x)`
  - converts number/boolean/string to integer `number` (truncate semantics)
  - invalid input raises `TypeError`
- `std.conv.to_float(x)`
  - converts number/boolean/string to floating `number`
  - invalid input raises `TypeError`
- `std.conv.to_bool(x)`
  - truthy conversion to boolean
- `std.conv.to_string(x)`
  - converts number/boolean/null/string/error to string
  - unsupported input raises `TypeError`

## 10. Runtime/Backend Notes

- Native functions are dispatched through VM native IDs.
- Two backend modes exist:
  - `embedded` (direct Zig implementation)
  - `host` (external host ABI bridge)
- Host ABI version/capability checks are required in host mode.
- Host-backed natives currently include `io.println`, `core.len`, and `core.append`.
- If host import is unavailable, host backend gracefully falls back to VM-local behavior.
- VM-local natives (`core.error`, `core.is_error`, `core.gc`, `core.gc_live_objects`, `core.gc_stats`, `conv.*`) run identically in embedded and host backends.
- Runtime limits are build-time configurable via preset config files:
  - `runtime/config_dev.zig` (default)
  - `runtime/config_tiny.zig`
  - `runtime/config_stress.zig`
- Make targets:
  - `make config-dev`
  - `make config-tiny`
  - `make config-stress`
  - `make wasi-tiny`
  - `make wasi-stress`
  - `make bench`
  - `make bench-tiny`
  - `make bench-stress`
  - `make parity`
- Bench cases may include `.policy` files:
  - `ALLOW_OOM` means runtime `OutOfMemory` is treated as expected for that bench case.
  - if `GENGO_BENCH_STATS=1`, bench runner prints elapsed time and optional ops/sec (when `.ops` file exists).

## 11. Current Known Limits

- Resource limits are fixed-size per active preset (defaults shown):
  - heap arena: `512 KiB`
  - object pool: `2048` objects
  - VM value stack: `512`
  - call frames: `32`
  - input source buffer: `128 KiB`
- Only `import("std")` is currently supported.
