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
- `docs/embedding.md`

## 1. Positioning

- `gengo` is a Tengo-inspired language, but compatibility is not guaranteed.
- Breaking changes are expected while the language surface is still being defined.

## 2. Modules and Builtins

- `import("std")` returns a standard-library namespace object with nested namespaces.
- Relative source imports are supported, for example `import("./math")`.
- Source modules resolve in this order:
  - exact path
  - path plus `.gengo`
  - path plus `/mod.gengo`
- Source modules return struct-backed namespace objects containing `pub` exports.
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
- `null`
- `array`
- `map`
- nominal struct types and struct instances
- function values (`func(...) { ... }`)
- native function values (internal, exposed via `std`)
- rune literal (numeric code point) via backtick syntax: `` `x` ``

### String Literals
- Standard escaped strings use double quotes: `"..."`.
  - Supports `\n`, `\t`, `\r`, `\\`, `\"`, `\'`.
  - Must fit on a single line; embedded newlines are a syntax error.
- Raw strings use single quotes: `'...'` (no escape processing; single-line only).
- Multiline raw strings use `\\` prefix on each line (Zig-style):
  - No escape processing — content is taken literally.
  - Each line contributes its content plus a trailing newline (including the last line).
  - Consecutive `\\` lines at any indentation level are joined into one string value.
  - Blank lines or non-`\\` lines terminate the literal.
- Strings are UTF-8 sequences.
  - `std.core.len(s)` counts Unicode code points (runes), not bytes.
  - `s[i]` indexes by rune position.
  - `s[a:b]` slices by rune positions.
  - `for ch in s` and `for i, ch in s` iterate by rune (with `i` as rune index).

Example multiline string:

```gengo
msg :=
    \\Hello, world!
    \\Escape seqs like \n and \t are NOT processed.
    \\Quotes like "this" need no backslash.

std.io.print(msg)
```

### Rune Literals
- Syntax: backtick single-code-point literal, for example:
  - `` `A` ``
  - `` `å` ``
  - `` `🙂` ``
- Semantics:
  - evaluates to `rune` equal to Unicode code point value.
  - literal must contain exactly one code point.

## 4. Variables and Assignment

- Mutable declaration: `name := expr`
- Immutable binding: `const name := expr`
- Typed mutable declaration: `name Type = expr`
- Typed immutable binding: `const name Type = expr`
  - Enforced for `int`, `float`, `bool`, and named types.
- Named types can use other named scalar types as base:
  - `type Integer int range -2147483648 .. 2147483647`
  - `type Age Integer range 0 .. 100`
  - `type Hour int cycle 0 .. 23`
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
  - Named numeric types (`type Age int ...`) participate in numeric compound ops.
  - Result is revalidated against the named type constraints.
- Increment/decrement: `x++`, `x--`
- `const` enforcement:
  - reassignment to const binding is compile error (`AssignToConst`)
  - includes `=`, compound assign, `++/--`, and direct multi-assign targets
  - const is shallow (interior map/array/struct mutations via paths are still allowed)

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

- Cast intrinsics: `int(x)`, `float(x)`, `bool(x)`, `string(x)`
  - numeric/bool casts accept number/rune/boolean and named scalars with compatible underlying values
  - `string(x)` supports string/number/rune/boolean/error/null and named string scalars
  - unsupported source types raise `TypeError`

### Named scalar operator rules

Named scalar types form nominal domains inside expressions:

| Operands | Result |
|---|---|
| `T op T` | `T`, validated by the type's own bounds semantics |
| `T op base` | `T`, validated by the type's own bounds semantics |
| `base op T` | `T`, validated by the type's own bounds semantics |
| `T op U` (different named types) | `TypeError` |
| `-T` | `T`, validated by the type's own bounds semantics |
| `T cmp T` | `bool` |
| `T cmp base` | `bool` (compares underlying value) |
| `T cmp U` (different named types) | `TypeError` |

The explicit escape hatch is a cast: `int(age) + int(score)` is always legal.

### Cyclic named integer types

Named integer types may use `cycle` instead of `range`:

```gengo
type Hour int cycle 0..23
type Step int cycle 1..16
```

- `cycle` is only supported for `int`-based named types.
- Constructors remain strict: `Hour(24)` raises `RangeError`.
- Arithmetic results on values of the cyclic type wrap back into the declared domain.
- `++` and `--` therefore wrap as well.

Examples:

```gengo
h := Hour(23)
std.io.println(h + Hour(1)) // 0
h++
std.io.println(h)           // 0
```

### Subtype declarations

`subtype` creates a constrained view of an existing named scalar type with explicit ancestry tracking:

```gengo
type Percent int range 0..100
subtype FailingGrade Percent range 0..59
subtype PassingGrade Percent range 60..100
```

The `range` clause is optional; if omitted the subtype inherits the parent's full range. The subtype range must lie within the parent's range (compile-time `RangeError` otherwise).

**Widening (implicit):** A subtype is accepted anywhere its parent or any ancestor is expected:
```gengo
func showPercent(v Percent) { std.io.println(v) }
showPercent(FailingGrade(40))  // OK
```

**Narrowing (explicit):** Assigning a parent value into a subtype variable requires the subtype constructor call, which range-checks at runtime:
```gengo
narrow FailingGrade = FailingGrade(Percent(30))  // OK: 30 in 0..59
```

**Subtype arithmetic rules:**

| Operands | Result |
|---|---|
| `T_sub op T_sub` | `T_sub`, range-checked |
| `T_sub op T_parent` | `T_parent`, range-checked against parent |
| `T_parent op T_sub` | `T_parent`, range-checked against parent |
| `T_sub op T_sibling` | `TypeError` |
| `T_sub cmp T_parent` | `bool` |
| `T_sub cmp T_sibling` | `TypeError` |

Siblings (subtypes with the same parent but no ancestry relationship between them) do not implicitly unify — use explicit casts to the common parent type.

### Type attributes

Type objects expose read-only attributes via `.` access:

**Named scalar types:**

| Attribute | Returns | Requires |
|---|---|---|
| `T.name` | `string` — type name | any named type |
| `T.first` | Named value `T(min)` | range constraint |
| `T.last` | Named value `T(max)` | range constraint |

**Enum types:**

| Attribute | Returns |
|---|---|
| `T.name` | `string` — type name |
| `T.first` | First enum value (ordinal 0) |
| `T.last` | Last enum value |
| `T.values` | `array` of all values in declaration order |

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
- Declaration: `type Name struct { field1, field2, ... }`
- Typed fields use space syntax: `type User struct { id int, name string, addr Addr }`
- Nullable types: `?T` (example: `nick ?string`)
- Union types: `A|B` (example: `id int|string`)
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
  - value iteration: `for x in seq { ... }` — works for arrays, maps, and strings
  - indexed/keyed iteration: `for i, v in seq { ... }` — second form with two variables:
    - **array**: `i` is the 0-based numeric index, `v` is the element
    - **map**: `i` is the string key, `v` is the value
    - **string**: `i` is the rune index, `v` is the rune as a single-character string
- `break` and `continue` supported inside loops.
- `return` supported inside functions.
- `assert condition` — panics with `AssertionFailed` if `condition` is false.
- `assert condition, "message"` — panics with the given message string if `condition` is false.
  - The panic value is an `error` value; it can be caught with `std.core.recover()` inside a `defer`.
  - `condition` must evaluate to `boolean`; a non-boolean condition raises `TypeError`.
- `value, trap := expr` — trap binding in multi-return destructure.
  - `trap` is a contextual keyword valid only as a binding target in `:=` destructure.
  - If the corresponding return slot is `null`, execution continues normally (no binding is created).
  - If the corresponding return slot is any non-`null` value, that value becomes the VM panic payload and the unwind path runs (same as `assert`).
  - `trap` introduces no local variable; it is not readable after the line.
  - Recovery uses the same `defer` / `std.core.recover()` mechanism as `assert`.
  - Example:
    ```gengo
    defer func() {
        err := std.core.recover()
        if err != null { std.io.println("caught:", err) }
    }()
    file,   trap := open(path)
    data,   trap := readAll(file)
    config, trap := parseConfig(data)
    ```

## 8. Functions

- Function literal: `func(args...) { ... }`
- Named function declaration sugar: `func name(args...) { ... }`
- Variadic params (declaration-side):
  - `func sum(...xs int) int { ... }`
  - variadic parameter must be last
  - call-site spread (`xs...`) is not supported
- Parameter types are mandatory (space syntax): `func f(x T) { ... }`
  - Use `any` to explicitly opt out of enforcement: `func f(x any) { ... }`
- Parameter types are enforced at call-time; mismatches raise `TypeError`.
- Calls with strict arity checking.
- Return supports multiple values: `return a, b, c`
- Nested functions supported within configured limits.

## 9. Standard Library (`std`)

Current namespace surface:
- `std.io.println(...args)`
  - prints values and newline
  - returns `null`
- `std.io.printf(fmt, ...args)`
  - verbs: `%v`, `%s`, `%d`, `%f`, `%t`, `%%`
  - arity mismatch: `ArityMismatch`
  - verb type mismatch: `TypeError`
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
- `std.core.contains(arr, value)`
  - returns `true` if `value` is present in array `arr`, else `false`
  - raises `TypeError` if `arr` is not an array
- `std.core.remove(arr, index)`
  - returns a new array with the element at `index` removed
  - raises `IndexOutOfBounds` if `index` is out of range
  - raises `TypeError` if `arr` is not an array
- `std.core.delete(m, key)`
  - removes `key` from map `m` in place
  - returns the removed value, or `null` if key was not present
  - raises `TypeError` if `m` is not a map
- `std.core.has(m, key)`
  - returns `true` if `key` exists in map `m`, else `false`
  - unambiguous alternative to `m[key] == null` when `null` is a valid value
  - raises `TypeError` if `m` is not a map
- `std.core.keys(m)`
  - returns an array of all keys in map `m`
  - raises `TypeError` if `m` is not a map
- `std.core.values(m)`
  - returns an array of all values in map `m`
  - raises `TypeError` if `m` is not a map
- `std.core.gc_stats()`
  - returns a map with:
    - `heap_used_bytes`
    - `heap_size_bytes`
    - `live_objects`
- `std.string.split(s, sep)`
  - splits string `s` by separator `sep`; returns array of strings
  - if `sep` is empty, splits into individual UTF-8 characters
- `std.string.join(arr, sep)`
  - concatenates array of strings `arr` with separator `sep` between each
  - raises `TypeError` if `arr` is not an array or any element is not a string
- `std.string.trim(s)`
  - removes leading and trailing ASCII whitespace (space, tab, `\n`, `\r`)
  - returns trimmed string
- `std.string.upper(s)`
  - returns copy of `s` with ASCII letters uppercased; non-ASCII bytes are unchanged
- `std.string.lower(s)`
  - returns copy of `s` with ASCII letters lowercased; non-ASCII bytes are unchanged
- `std.string.starts_with(s, prefix)`
  - returns `true` if `s` begins with `prefix`
- `std.string.ends_with(s, suffix)`
  - returns `true` if `s` ends with `suffix`
- `std.string.index_of(s, sub)`
  - returns rune index of first occurrence of `sub` in `s`, or `-1` if not found
- `std.string.builder()`
  - creates a mutable string accumulator; use `.write(s)`, `.str()`, `.reset()`
  - amortized O(total_bytes) append cost; avoids O(n²) from repeated `s = s + piece`
- `std.math.abs(x)`
  - absolute value of `x`
- `std.math.sqrt(x)`
  - square root of `x`
- `std.math.floor(x)`
  - largest integer not greater than `x`
- `std.math.ceil(x)`
  - smallest integer not less than `x`
- `std.math.round(x)`
  - nearest integer, rounding half away from zero
- `std.math.sin(x)` / `std.math.cos(x)` / `std.math.tan(x)`
  - trigonometric functions; argument in radians
- `std.math.log(x)`
  - natural logarithm (base *e*)
- `std.math.log2(x)`
  - base-2 logarithm
- `std.math.log10(x)`
  - base-10 logarithm
- `std.math.pow(base, exp)`
  - `base` raised to the power `exp`
- `std.math.min(a, b)` / `std.math.max(a, b)`
  - minimum / maximum of two numbers
- `std.math.pi`
  - π ≈ 3.14159265358979… (constant, not a function)
- `std.math.e`
  - Euler's number ≈ 2.71828182845904… (constant, not a function)
- `std.math.inf`
  - positive infinity (constant, not a function)
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
- Runtime execution is instance-scoped:
  - `Runtime` owns separate `chunk`, `globals`, `heap`, and `vm` states.
  - Runtime switching is pointer activation (`setActive`) rather than state snapshot copying.
  - Current model supports isolated instances and interleaved calls, but not concurrent execution of multiple runtimes on different threads.
- Optional runtime instruction budget is available via CLI flag:
  - `--max-ops <N>`
  - Exceeding budget returns runtime error `InstructionBudgetExceeded`.
- Runtime limits are build-time configurable via preset config files:
  - `runtime/config_dev.zig` (default)
  - `runtime/config_tiny.zig`
  - `runtime/config_stress.zig`
- Build/test entrypoints:
  - `zig build -Dpreset=dev wasi`
  - `zig build -Dpreset=tiny wasi`
  - `zig build -Dpreset=stress wasi`
  - `zig build -Dpreset=dev test`
  - `zig build -Dpreset=dev bench`
  - `zig build -Dpreset=dev parity`
- Bench cases may include `.policy` files:
  - `ALLOW_OOM` means runtime `OutOfMemory` is treated as expected for that bench case.
  - if `GENGO_BENCH_STATS=1`, bench runner prints elapsed time and optional ops/sec (when `.ops` file exists).

## 11. Current Known Limits

- Resource limits are fixed-size per active preset (defaults shown):
  - heap arena: `512 KiB`
  - object pool: `2048` objects
  - VM value stack: `512`
  - call frames: `64`
  - input source buffer: `128 KiB`
- Managed allocations use fixed class sizes; one managed block currently cannot exceed `32 KiB` even if total heap has room.
- Source imports require a file-backed runtime entrypoint; pathless embedding calls still only support `std`.

## 12. Named Types and Ranges

- Named scalar types:
  - `type UserId string`
  - `type OrderId string`
- Range subtypes:
  - `type Month int range 1..12`
  - `type Percent float range 0.0..1.0`
- Constructor semantics:
  - `Month(12)` succeeds
  - `Month(13)` raises `RangeError`
- Nominal semantics:
  - named types are not interchangeable, even with same base type
  - explicit constructor is required (`UserId("u-1")`)

## 13. Enums

- Declaration:
  - `type Status enum { pending, approved, denied }`
- Qualified member access:
  - `Status.pending`
  - `Status.approved`
- Unqualified member names are not implicitly global.
- Enum values are nominal; different enum types are not interchangeable.
