# gengo Language (Current Behavior)

This document defines the current language behavior implemented by gengo.
It is intentionally versioned by implementation reality.

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

- Breaking changes are expected while the language surface is still being defined.

## 2. Modules and Builtins

- `import("std")` returns a standard-library namespace object with nested namespaces.
- Relative source imports are supported, for example `import("./math")`.
- Source modules resolve in this order:
  - exact path
  - path plus `.gengo`
  - path plus `/mod.gengo`
- Source modules return struct-backed namespace objects containing `pub` exports.
- Field accesses on imported module objects are validated at compile time; accessing a name that is not exported raises a `CompileError`.
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

### Number Literals
- Decimal integer: `42`, `-17`
- Decimal float: `3.14`, `-0.5`
- Scientific notation: `1.5e3` (= 1500.0), `2.5e-1`, `1.5E+2`
- Digit separators: `1_000_000`, `999_99_9999` — underscores are ignored and may appear anywhere in the digit sequence

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
| `T.succ(v)` | Named value immediately after `v` in sequence | range or cycle |
| `T.pred(v)` | Named value immediately before `v` in sequence | range or cycle |

`succ` and `pred` are called on the **type**, not the value: `Month.succ(m)`, not `m.succ()`.
For range types, `succ` at `T.last` and `pred` at `T.first` raise `RangeError`.
For cycle types, `succ`/`pred` wrap around.

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
- `arr.first` — the index of the first element, always `0`
- `arr.last` — the index of the last element (`len - 1`); raises `IndexOutOfBounds` on an empty array
- Use `arr[arr.first]` and `arr[arr.last]` to read the first or last element.

### Maps
- Literal supports identifier keys and expression keys:
  - `{a: 1}` is shorthand for `{"a": 1}`
  - `{ "x": 2 }` also supported
- Index read supported: `m[key]`
- Missing key read returns `null`.
- Index write updates existing keys or inserts a new key if no existing entry matches.
- `m.len` — number of entries (equivalent to `std.core.len(m)`).
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
  - infinite loop: `for { ... }` — runs until `break`
  - condition style: `for cond { ... }`
  - C-style: `for init; cond; post { ... }`
  - value iteration: `for x in seq { ... }` — works for arrays, maps, and strings
  - indexed/keyed iteration: `for i, v in seq { ... }` — second form with two variables:
    - **array**: `i` is the 0-based numeric index, `v` is the element
    - **map**: `i` is the string key, `v` is the value
    - **string**: `i` is the rune index, `v` is the rune as a single-character string
- `break` and `continue` supported inside loops.
- `return` supported inside functions.
- `defer expr` — schedules `expr` to execute when the enclosing function exits, whether by normal return or panic unwind.
  - Multiple defers run in LIFO order (last declared, first executed).
  - The expression is evaluated at the `defer` statement; a closure `defer` captures the environment at call time.
  - Common patterns:
    - `defer std.io.println("done")` — deferred expression call
    - `defer (func() { std.io.println(x) })()` — deferred inline closure (captures `x` by reference)
  - Deferred closures can read and mutate named return values (see Named return values below).
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
- Method declarations: `func (recv TypeName) method(args...) returnType { ... }`
  - Allowed on any user-defined named type: structs, named scalars, enums, variants.
  - Not allowed on interface types or base types directly.
  - Registered globally as `TypeName.method`; called via `value.method(args)`.
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
- **Named return values**: return slots can be given names and types in the signature.
  - Syntax: `func f() (result int) { ... }` or multiple: `func f() (a int, b string) { ... }`
  - Named returns are pre-declared as local variables, zero-initialised before the body runs.
  - A bare `return` (no arguments) returns the current values of all named slots.
  - `return expr` still works — it assigns to the first named slot and returns.
  - **Defers can read and mutate named return values** — the named slots remain live through
    the defer phase, so a deferred closure can observe or change the final return value:
    ```gengo
    func double() (result int) {
        result = 10
        defer (func() { result = result * 2 })()
        return result  // defer runs after return: caller receives 20
    }
    ```
  - Multiple defers run LIFO and each sees the value left by the previous defer:
    ```gengo
    func compute() (result int) {
        result = 1
        defer (func() { result = result + 100 })()  // runs third  → 160
        defer (func() { result = result * 10 })()   // runs second → 60
        defer (func() { result = result + 5 })()    // runs first  → 6
        return result
    }
    // compute() == 160
    ```

## 9. Standard Library (`std`)

### std.io

- `std.io.println(...args)` — prints values and a trailing newline; returns `null`
- `std.io.print(...args)` — prints values without a trailing newline; returns `null`
- `std.io.printf(fmt, ...args)` — formatted print; verbs: `%v %s %d %f %t %%`; raises `ArityMismatch` or `TypeError` on bad input
- `std.io.sprintf(fmt, ...args)` — same as `printf` but returns the formatted string

### std.core

- `std.core.len(x)` — rune/element count for string, array, map, or struct instance
- `std.core.bytelen(s)` — raw UTF-8 byte length of a string
- `std.core.append(arr, ...items)` — returns a new array with items appended
- `std.core.contains(arr, value)` — `true` if `value` is in array `arr`; raises `TypeError` if not array
- `std.core.remove(arr, index)` — returns new array with element at `index` removed; raises `IndexOutOfBounds` or `TypeError`
- `std.core.delete(m, key)` — removes `key` from map in place; returns removed value or `null`
- `std.core.has(m, key)` — `true` if `key` exists in map; unambiguous when `null` is a valid value
- `std.core.keys(m)` — array of all map keys
- `std.core.values(m)` — array of all map values
- `std.core.error(msg)` — creates an `error` value from string `msg`
- `std.core.is_error(v)` — `true` if `v` is an error value
- `std.core.recover()` — inside a `defer` during panic unwind: returns the panic payload and marks it recovered; returns `null` otherwise
- `std.core.type_of(v)` — runtime type name: `"int"`, `"float"`, `"string"`, `"null"`, or a declared type name
- `std.core.is_int(v)`, `std.core.is_float(v)`, `std.core.is_string(v)`, `std.core.is_array(v)`, `std.core.is_map(v)`, `std.core.is_struct(v)`, `std.core.is_null(v)` — runtime type predicates
- `std.core.deep_equal(a, b)` — structural equality for arrays, maps, structs, named values, variants, strings, and scalars
- `std.core.clone(v)` — deep clone
- `std.core.gc()` — trigger mark-sweep GC; returns `null`
- `std.core.gc_live_objects()` — current live heap object count
- `std.core.gc_stats()` — map with `heap_used_bytes`, `heap_size_bytes`, `live_objects`

### std.string

- `std.string.split(s, sep)` — split by separator; empty `sep` splits into individual UTF-8 characters
- `std.string.split_once(s, sep)` — returns `(head, tail)` at first occurrence; `(null, null)` if absent
- `std.string.join(arr, sep)` — join string array with separator
- `std.string.contains(s, sub)` — substring presence; empty `sub` always `true`
- `std.string.contains_any(s, chars)` — `true` if any character in `chars` appears in `s`
- `std.string.starts_with(s, prefix)` — prefix check
- `std.string.ends_with(s, suffix)` — suffix check
- `std.string.index_of(s, sub)` — rune index of first occurrence, or `-1`
- `std.string.last_index_of(s, sub)` — rune index of last occurrence, or `-1`
- `std.string.count(s, sub)` — count of non-overlapping occurrences of `sub` in `s`
- `std.string.replace(s, old, new)` — replace all non-overlapping occurrences
- `std.string.trim(s)` — strip leading and trailing ASCII whitespace
- `std.string.trim_left(s, cutset)` — strip leading bytes that appear in `cutset`
- `std.string.trim_right(s, cutset)` — strip trailing bytes that appear in `cutset`
- `std.string.trim_prefix(s, prefix)` — remove `prefix` if present; return `s` unchanged otherwise
- `std.string.trim_suffix(s, suffix)` — remove `suffix` if present; return `s` unchanged otherwise
- `std.string.split_n(s, sep, n)` — split into at most `n` parts; last part contains the remainder
- `std.string.fields(s)` — split on any whitespace, collapsing runs; returns array of non-empty tokens
- `std.string.upper(s)` — ASCII uppercase
- `std.string.lower(s)` — ASCII lowercase
- `std.string.equal_fold(s, t)` — case-insensitive equality (ASCII)
- `std.string.repeat(s, n)` — repeat `s` exactly `n` times; raises `RangeError` when `n < 0`
- `std.string.pad_left(s, n, pad)` — left-pad `s` to length `n` using string `pad`
- `std.string.pad_right(s, n, pad)` — right-pad `s` to length `n` using string `pad`
- `std.string.builder()` — mutable accumulator with `.write(s)`, `.str()`, `.reset()`; avoids O(n²) from repeated concatenation

### std.math

**Rounding**
- `std.math.floor(x)` — round toward −∞
- `std.math.ceil(x)` — round toward +∞
- `std.math.round(x)` — nearest integer, half away from zero
- `std.math.trunc(x)` — round toward zero (drop fractional part)

**Roots and powers**
- `std.math.sqrt(x)`, `std.math.cbrt(x)` — square root, cube root
- `std.math.pow(base, exp)` — `base ** exp` (also available as the `**` operator)
- `std.math.exp(x)`, `std.math.exp2(x)` — *e*^x and 2^x
- `std.math.hypot(p, q)` — sqrt(p² + q²) without overflow

**Logarithms**
- `std.math.log(x)` — natural log (base *e*)
- `std.math.log2(x)` — base-2 log
- `std.math.log10(x)` — base-10 log

**Trigonometry**
- `std.math.sin(x)`, `std.math.cos(x)`, `std.math.tan(x)` — trig; argument in radians
- `std.math.asin(x)`, `std.math.acos(x)`, `std.math.atan(x)` — inverse trig; result in radians
- `std.math.atan2(y, x)` — angle of vector (x, y); result in radians

**Hyperbolic**
- `std.math.sinh(x)`, `std.math.cosh(x)`, `std.math.tanh(x)`

**Misc**
- `std.math.abs(x)` — absolute value
- `std.math.min(a, b)`, `std.math.max(a, b)` — minimum / maximum
- `std.math.clamp(v, min, max)` — constrain `v` to `[min, max]`
- `std.math.sign(x)` — `-1`, `0`, or `1`
- `std.math.mod(x, y)` — floating-point remainder (IEEE 754)
- `std.math.nan()` — IEEE 754 NaN value
- `std.math.is_nan(x)` — `true` if `x` is NaN
- `std.math.is_inf(x, sign)` — `true` if `x` is infinite; `sign > 0` tests +∞, `sign < 0` tests −∞, `sign == 0` tests either

**Constants**
- `std.math.pi` — π
- `std.math.e` — Euler's number
- `std.math.inf` — positive infinity

### std.rand

- `std.rand.float()` — uniform float in `[0.0, 1.0)`
- `std.rand.intn(n)` — uniform int in `[0, n)`; raises `RangeError` if `n ≤ 0`
- `std.rand.between(lo, hi)` — uniform int in `[lo, hi]` inclusive; raises `RangeError` if `lo > hi`
- `std.rand.choice(arr)` — random element from array; raises `RangeError` on empty array
- `std.rand.perm(n)` — array containing a random permutation of `[0, n)`
- `std.rand.norm_float()` — sample from standard normal distribution (mean 0, stddev 1)
- `std.rand.seed(n)` — seed the global PRNG for reproducible sequences

### std.conv

- `std.conv.to_int(x)` — number/boolean/string → integer (truncate semantics); raises `TypeError` on invalid input
- `std.conv.to_float(x)` — number/boolean/string → float; raises `TypeError` on invalid input
- `std.conv.to_bool(x)` — truthy conversion to boolean
- `std.conv.to_string(x)` — number/boolean/null/string/error → string; raises `TypeError` on unsupported input

### std.json

- `std.json.parse(s)` — parse JSON string; returns array/map/number/string/boolean/null
- `std.json.stringify(v)` — serialize value to compact JSON string
- `std.json.indent(s, indent)` — pretty-print JSON `s` with the given indent string (`"\t"`, `" "`, `"  "` etc.)
- `std.json.valid(s)` — `true` if `s` is valid JSON

### std.time

All times are opaque `Time` objects. Internal representation is milliseconds since the Unix epoch (UTC).

**Construction**
- `std.time.now()` — current time
- `std.time.from_unix(sec)` — from Unix seconds (integer)
- `std.time.from_unix_ms(ms)` — from Unix milliseconds (integer)
- `std.time.parse(s, fmt)` — parse string with format; raises `ParseError` on mismatch
- `std.time.since(t)` — milliseconds elapsed since `t` (equivalent to `std.time.now().sub(t)`)
- `std.time.until(t)` — milliseconds until `t`
- `std.time.parse_duration(s)` — parse a duration string into milliseconds; matches Go's `time.ParseDuration` — optional leading `+`/`-`, each component is `<number><unit>`, fractions allowed (`.5s`, `1.5h`), bare `"0"` valid; units: `ns`, `us`/`µs`/`μs`, `ms`, `s`, `m`, `h`

**Methods on Time values**
- `t.unix()` — Unix timestamp in seconds
- `t.unix_ms()` — Unix timestamp in milliseconds
- `t.parts()` — map with `year`, `month` (1–12), `day` (1–31), `hour` (0–23), `min` (0–59), `sec` (0–59), `ms` (0–999), `weekday` (0=Sunday … 6=Saturday)
- `t.format(fmt)` — format as string using strftime-style directives
- `t.add_ms(n)`, `t.add_s(n)`, `t.add_m(n)`, `t.add_h(n)` — add milliseconds / seconds / minutes / hours
- `t.add_date(years, months, days)` — add calendar units (handles month-length and leap-year rules)
- `t.sub(other)` — difference in milliseconds
- `t.before(other)`, `t.after(other)`, `t.equal(other)` — comparison
- `t.is_zero()` — `true` if the time is the zero value (Unix epoch)
- `t.since()` — milliseconds elapsed since `t`
- `t.until()` — milliseconds until `t`

### std.regexp

- `std.regexp.match(pattern, s)` — `true` if `s` contains a match for `pattern`
- `std.regexp.find(pattern, s)` — first match as a map `{text, begin, end}`, or `null`
- `std.regexp.find_all(pattern, s)` — array of all matches, each a map `{text, begin, end}`
- `std.regexp.replace(pattern, s, repl)` — replace all matches with `repl`
- `std.regexp.split(pattern, s)` — split `s` by pattern; returns array of strings
- `std.regexp.compile(pattern)` — returns a `Regexp` object for repeated use; raises on invalid pattern
  - `r.match(s)`, `r.find(s)`, `r.find_all(s)`, `r.replace(s, repl)`, `r.split(s)` — same semantics as above

### std.template

- `std.template.parse(tmpl)` — compile a template string; raises on invalid syntax
- `std.template.render(tmpl, data)` — render template with data map; returns string
- `std.template.execute(tmpl, data)` — alias for `render`
- `std.template.valid(tmpl)` — `true` if the template string parses without error
- `std.template.add_func(tmpl, name, fn)` — register a custom function callable from within the template

### std.hex

- `std.hex.encode(s)` — encode string to lowercase hex
- `std.hex.decode(s)` — decode hex string; raises on invalid input

### std.base64

- `std.base64.encode(s)` — standard Base64 encode
- `std.base64.decode(s)` — standard Base64 decode; raises on invalid input
- `std.base64.url_encode(s)` — URL-safe Base64 encode (uses `-_` instead of `+/`)
- `std.base64.url_decode(s)` — URL-safe Base64 decode

### std.sort

All sort functions return a **new** array; the original is not modified.

- `std.sort.asc(arr)` — sort ascending (numbers by value, strings lexicographically)
- `std.sort.desc(arr)` — sort descending
- `std.sort.by(arr, fn)` — sort by comparator `fn(a, b)`: negative means `a` before `b`, positive means `b` before `a`, zero means equal; a boolean return value is also accepted (`true` = `a` before `b`)

### std.array

All functions return a **new** array; the original is not modified.

- `std.array.filter(arr, fn)` — elements where `fn(v)` is truthy
- `std.array.map(arr, fn)` — transform each element with `fn(v)`
- `std.array.reduce(arr, fn, init)` — fold left: `fn(acc, v)` starting from `init`
- `std.array.slice(arr, from, to)` — sub-array `[from, to)` (exclusive end); raises `IndexOutOfBounds` on invalid range
- `std.array.zip(a, b)` — array of two-element arrays `[a[i], b[i]]`; truncates to the shorter input
- `std.array.flat(arr)` — one-level flatten: array elements that are arrays are inlined; non-array elements are kept as-is
- `std.array.find(arr, fn)` — first element where `fn(v)` is truthy, or `null`
- `std.array.find_index(arr, fn)` — index of first match, or `-1`
- `std.array.all(arr, fn)` — `true` if `fn(v)` is truthy for every element
- `std.array.any(arr, fn)` — `true` if `fn(v)` is truthy for at least one element
- `std.array.chunk(arr, size)` — split into sub-arrays of length `size` (last chunk may be shorter); raises `RangeError` if `size ≤ 0`

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

### Predicate Subtypes

Named types may include a predicate body that is evaluated at construction time:

```gengo
type Port int predicate func(x) { return x >= 1 && x <= 65535 }
p := Port(80)    // ok
p2 := Port(0)    // PredicateViolation
```

- The predicate function takes one parameter (the raw value) and must return `boolean`.
- If the predicate returns `false`, construction raises `PredicateViolation`.
- Predicates may be combined with `range` constraints; both are checked.
- The body compiles as a closure and may capture variables from the enclosing scope:

```gengo
min_val := 10
max_val := 20
type Bounded int predicate func(x) { return x >= min_val && x <= max_val }
```

## 13. Enums

- Declaration:
  - `type Status enum { pending, approved, denied }`
- Qualified member access:
  - `Status.pending`
  - `Status.approved`
- Unqualified member names are not implicitly global.
- Enum values are nominal; different enum types are not interchangeable.

### Enum Subtypes

`subtype` constrains the member set of an existing enum:

```gengo
type Days enum { Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday }
subtype Weekend_Days Days { Saturday, Sunday }
```

- Members must be a strict subset of the parent enum's members.
- Subtype values are equal to their parent equivalents: `Weekend_Days.Saturday == Days.Saturday`.
- Type attributes (`name`, `first`, `last`, `values`) work on enum subtypes.
- A subtype value is accepted anywhere its parent type is expected.

## 14. Variant Types

Variant types define a closed set of tagged alternatives, each optionally carrying a payload.

### Declaration

```gengo
type Result variant {
    ok(value int),
    err(msg string),
    pending
}
```

- Arms with a single payload use `tag(field Type)` syntax.
- Arms without a payload are bare names.

### Construction

```gengo
r1 := Result.ok(42)
r2 := Result.err("not found")
r3 := Result.pending
```

Payload arms are called as constructors; no-payload arms are accessed directly.

### Pattern Matching

Variant values are matched with `switch`:

```gengo
switch r1 {
    case .ok(v)  { std.io.println("ok:", v) }
    case .err(m) { std.io.println("err:", m) }
    case .pending { std.io.println("pending") }
}
```

- Each `case` arm binds the payload to a local variable when present.
- `default {}` handles any unmatched arm.
- Exhaustive matching is not enforced at compile time; a missing arm at runtime is a `TypeError`.

### Multi-field Arms

An arm can carry a struct-like record of named fields using `{ }` syntax:

```gengo
type Shape variant {
    circle { radius float },
    rect   { width float, height float },
    point
}
```

Construction supplies all fields in a struct literal:

```gengo
s := Shape.circle { radius: 5.0 }
r := Shape.rect { width: 10.0, height: 20.0 }
```

In a match arm, the payload struct is bound to a variable and accessed via dot:

```gengo
switch s {
    case .circle(f) { std.io.println(f.radius) }
    case .rect(f)   { std.io.println(f.width, f.height) }
    case .point     { std.io.println("point") }
}
```

### Variant Records (Shared Fields)

A variant may declare bare fields directly in its body alongside arm declarations. These **shared fields** are present on every value of the type and are accessible without a match:

```gengo
type Shape variant {
    x float,
    y float,
    circle { radius float },
    rect   { width float, height float },
    point
}
```

Shared fields and arm declarations may appear in any order. Construction supplies all fields — shared and arm-specific — in one struct literal:

```gengo
s := Shape.circle { x: 1.0, y: 2.0, radius: 5.0 }
p := Shape.point  { x: 3.0, y: 4.0 }
```

Shared fields are accessible directly on any value, no match required:

```gengo
draw_at(s.x, s.y)
```

They remain accessible inside match arms alongside arm-specific fields:

```gengo
switch s {
    case .circle(f) { std.io.println("r=", f.radius, "at", s.x, s.y) }
    case .rect(f)   { std.io.println("rect at", s.x, s.y) }
    case .point     { std.io.println("point at", s.x, s.y) }
}
```

Shared field names and arm field names must not overlap within the same type — a duplicate name is a compile error.

### Type Attributes

| Attribute | Returns |
|---|---|
| `T.name` | `string` — the type name |

### Methods

Methods may be declared on variant types using standard receiver syntax:

```gengo
func (r Result) ok_value() int {
    switch r {
        case .ok(v) { return v }
        default { return 0 }
    }
}
```

### As Function Parameters

Variant types are accepted as typed function parameters and return types:

```gengo
func describe(r Result) string {
    switch r {
        case .ok(v)  { return std.conv.to_string(v) }
        case .err(m) { return m }
        case .pending { return "pending" }
    }
    return ""
}
