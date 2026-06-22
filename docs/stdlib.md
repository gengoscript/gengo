# Gengoscript Standard Library Reference

This page is the reference for the built-in `std` module and its namespaces.

For the language rules around imports, values, and types, see `language.md`.

## Import

```gengo
std := import("std")
```

`std` is always available via `import("std")` and is exposed as a struct-backed namespace object. Relative source imports use the same namespace model.

The entries below describe the public library surface. This page is intentionally reference-shaped: look up a function here once you already know which part of `std` you need.

## std.io

### `std.io.println(...args)`
- Prints arguments followed by a newline.
- Returns `null`.

### `std.io.print(...args)`
- Prints arguments without a trailing newline.
- Returns `null`.

### `std.io.printf(fmt, ...args)`
- `fmt` is a string with Go-style format verbs.
- Errors: `ArityMismatch` when placeholder count and args differ; `TypeError` when arg type does not match verb.
- To get the formatted string instead of printing it, use `std.fmt.format`.

### `std.io.eprint(...args)`
- Like `std.io.print` but writes to stderr.
- Returns `null`.

### `std.io.eprintf(fmt, ...args)`
- Like `std.io.printf` but writes to stderr.
- Returns `null`.

### `std.io.eprintln(...args)`
- Like `std.io.println` but writes to stderr.
- Returns `null`.

### `std.io.read()`
- Reads up to 4096 bytes from stdin in a single call.
- Returns the bytes as a string, or `null` on EOF.

### `std.io.readline()`
- Reads one line from stdin (up to 4096 bytes), stripping the trailing `\n` / `\r\n`.
- Returns the line as a string, or `null` on EOF.

### Format verbs

| Verb | Meaning |
|------|---------|
| `%v` | Default format (same as the `print` family) |
| `%s` | String; precision trims to N runes (`%.3s`) |
| `%q` | Quoted string with Go-style escape sequences |
| `%d` | Decimal integer |
| `%b` | Binary integer |
| `%o` | Octal integer |
| `%x` | Hexadecimal (lowercase) |
| `%X` | Hexadecimal (uppercase) |
| `%f` | Floating-point, decimal notation (default precision 6) |
| `%e` | Scientific notation, lowercase exponent |
| `%E` | Scientific notation, uppercase exponent |
| `%g` | `%e` for large exponents, `%f` otherwise |
| `%G` | Like `%g` with uppercase exponent |
| `%t` | Boolean (`true` / `false`) |
| `%c` | Integer as Unicode code point |
| `%%` | Literal `%` |

**Flags** (between `%` and the verb):

| Flag | Meaning |
|------|---------|
| `-` | Left-align within field width |
| `0` | Zero-pad numeric fields |
| `+` | Always print sign for numeric values |
| ` ` | Space before positive numbers |
| `#` | Alternate form: `0x` / `0X` / `0` / `0b` prefix for `%x`/`%X`/`%o`/`%b` |

**Width and precision**: `%8d` (minimum width 8), `%.2f` (2 decimal places), `%8.3f` (both).

## std.fmt

### `std.fmt.format(fmt, ...args)`
- Returns the formatted string. `fmt` uses the same Go-style verbs as `std.io.printf`.
- Errors: `ArityMismatch` when placeholder count and args differ; `TypeError` when arg type does not match verb.

### `std.fmt.stringify(v)`
- Returns `v` rendered as a string, exactly as `std.io.println` would display it.
- Works for any value: scalars, arrays, maps, structs, variants, named types.
- Returns `""` for a `null` argument.

## std.core

### `std.core.len(x)`
- String: rune count (Unicode code points)
- Array/map/struct instance: element/field count
- Errors: `TypeError` on unsupported input

### `std.core.bytelen(s)`
- String: UTF-8 byte count
- Errors: `TypeError` on unsupported input

### `std.core.append(arr, ...items)`
- Returns new array with appended items
- Errors: `TypeError` if first arg is not array

### `std.core.error(msg)`
- Creates first-class error value
- `msg` must be string

### `std.core.is_error(v)`
- Returns `true` iff `v` is an error value

### `std.core.recover()`
- Called inside a `defer` function during a panic unwind
- Returns the panic payload (an `error` value) and marks the panic as recovered
- Returns `null` if not unwinding or if already recovered

### `std.core.type_of(v)`
- Returns stable runtime type name
- Plain scalars report names like `int`, `float`, `bool`, `string`, `error`, `null`
- Named values and struct instances report their declared type name

### `std.core.is_int(v)`
- `true` for integral numbers and named integer values

### `std.core.is_float(v)`
- `true` for non-integral numbers and named float values

### `std.core.is_string(v)`
- `true` for strings and named string values

### `std.core.is_array(v)`
- `true` for arrays and named array values

### `std.core.is_map(v)`
- `true` for maps and named map values

### `std.core.is_struct(v)`
- `true` for struct instances

### `std.core.is_null(v)`
- `true` only for `null`

### `std.core.deep_equal(a, b)`
- Structural equality for arrays, maps, struct instances, named values, variants, strings, and scalars
- Map comparison is by key/value content, not insertion order

### `std.core.clone(v)`
- Deep clone for arrays, maps, struct instances, named values, variants, and strings
- Immutable scalar values are returned unchanged

### `std.core.gc()`
- Triggers GC
- Returns `null`

### `std.core.gc_live_objects()`
- Returns current live object count (number)

### `std.core.gc_stats()`
- Returns map with keys:
  - `heap_used_bytes`
  - `heap_size_bytes`
  - `live_objects`

### `std.core.gc_stats_ext()`
- Returns extended GC stats with keys: `heap_used_bytes`, `heap_size_bytes`, `live_objects`, `gc_runs`, `gc_time_ns`, `alloc_object_calls`, `alloc_managed_slice_calls`, `alloc_managed_bytes_calls`

### `std.core.keys(map)`
- Returns array of all keys in a map
- Errors: `TypeError` on non-map

### `std.core.values(map)`
- Returns array of all values in a map
- Errors: `TypeError` on non-map

### `std.core.has(map, key)`
- Returns `true` iff `key` exists in `map`
- Errors: `TypeError` on non-map

### `std.core.delete(map, key)`
- Removes `key` from `map`; returns the removed value or `null`
- Errors: `TypeError` on non-map

### `std.core.contains(arr, needle)`
- Returns `true` iff `arr` contains `needle` (uses `deep_equal`)
- Errors: `TypeError` on non-array

### `std.core.remove(arr, index)`
- Returns a new array with the element at `index` removed
- Errors: `TypeError` on non-array, `IndexOutOfBounds`

## std.conv

### `std.conv.to_int(x)`
- Converts number/rune/boolean/string to integer-number (truncate)
- Errors: `TypeError` on invalid conversion

### `std.conv.to_float(x)`
- Converts number/rune/boolean/string to float-number
- Errors: `TypeError` on invalid conversion

### `std.conv.to_bool(x)`
- Explicit conversion to boolean: `false`, `null`, `0`, and `""` convert to
  `false`; everything else converts to `true`
- This is the only truthiness in the language — `if`/`not`/`and`/`or` and
  template `{{if}}` require an actual `bool`

### `std.conv.to_string(x)`
- Converts number/rune/boolean/null/string/error to string
- Errors: `TypeError` on unsupported input

## std.string

### `std.string.split(s, sep)`
- Splits `s` by `sep`
- Empty `sep` splits into UTF-8 runes

### `std.string.join(arr, sep)`
- Joins array of strings with separator `sep`

### `std.string.trim(s)`
- Trims leading and trailing ASCII whitespace

### `std.string.upper(s)`
- Uppercases ASCII letters

### `std.string.lower(s)`
- Lowercases ASCII letters

### `std.string.starts_with(s, prefix)`
- Returns `true` iff `s` begins with `prefix`

### `std.string.ends_with(s, suffix)`
- Returns `true` iff `s` ends with `suffix`

### `std.string.index_of(s, sub)`
- Returns rune index of first occurrence, or `-1`

### `std.string.last_index_of(s, sub)`
- Returns rune index of last occurrence, or `-1`

### `std.string.replace(s, old, new)`
- Replaces all non-overlapping occurrences of `old` with `new`
- Empty `old` returns `s` unchanged

### `std.string.repeat(s, n)`
- Returns `s` repeated `n` times
- `n < 0` raises `RangeError`

### `std.string.split_once(s, sep)`
- Returns a 2-element array `[head, tail]` split on the first occurrence of `sep`
- Returns `[null, null]` if `sep` is not present

### `std.string.contains(s, sub)`
- Returns `true` if `sub` appears anywhere in `s`, else `false`
- Empty `sub` always returns `true`

### `std.string.builder()`
- Creates mutable string builder with `.write`, `.str`, and `.reset`

### `std.string.count(s, sub)`
- Counts non-overlapping occurrences of `sub` in `s`

### `std.string.fields(s)`
- Splits `s` by ASCII whitespace (spaces, tabs, newlines) into an array

### `std.string.pad_left(s, width, pad)` / `std.string.pad_right(s, width, pad)`
- Pads `s` to `width` using `pad` (first rune only) on the left or right

### `std.string.equal_fold(a, b)`
- Case-insensitive equality for ASCII strings

### `std.string.contains_any(s, chars)`
- Returns `true` if any rune in `chars` appears in `s`

### `std.string.trim_left(s, chars)` / `std.string.trim_right(s, chars)`
- Trims leading or trailing bytes that appear in `chars` (single-byte characters only; multi-byte runes in `chars` are not recognised)

### `std.string.trim_prefix(s, prefix)` / `std.string.trim_suffix(s, suffix)`
- Removes `prefix` or `suffix` if present; returns `s` unchanged otherwise

### `std.string.split_n(s, sep, n)`
- Splits `s` by `sep` into at most `n` substrings; final element contains the rest

## std.array

### `std.array.filter(arr, pred)`
- Returns array of elements where `pred(element)` is `true`

### `std.array.map(arr, fn)`
- Returns array of `fn(element)` for each element

### `std.array.reduce(arr, fn, init)`
- Folds `arr` left-to-right: `fn(init, arr[0])`, then `fn(result, arr[1])`, etc.

### `std.array.slice(arr, start, end)`
- Returns sub-array from `start` (inclusive) to `end` (exclusive)

### `std.array.zip(a, b)`
- Returns array of pairs `[a[0], b[0]], [a[1], b[1]], …`

### `std.array.flat(arr)`
- Flattens one level of nesting: `[[1,2],[3]]` → `[1,2,3]`

### `std.array.find(arr, pred)`
- Returns first element where `pred(element)` is `true`, or `null`

### `std.array.find_index(arr, pred)`
- Returns index of first element where `pred(element)` is `true`, or `-1`

### `std.array.all(arr, pred)`
- Returns `true` if `pred(element)` is `true` for every element

### `std.array.any(arr, pred)`
- Returns `true` if `pred(element)` is `true` for at least one element

### `std.array.chunk(arr, size)`
- Splits `arr` into sub-arrays of length `size`; last chunk may be shorter
- Errors: `RangeError` if `size <= 0`

## std.sort

### `std.sort.asc(arr)`
- Returns a new array sorted in ascending order (int, float, or string elements); the original is unchanged

### `std.sort.desc(arr)`
- Returns a new array sorted in descending order; the original is unchanged

### `std.sort.by(arr, key_fn)`
- Returns a new array sorted by the value returned by `key_fn(element)` for each element; the original is unchanged

## std.math

### `std.math.abs(x)`
- Absolute value of `x`

### `std.math.sqrt(x)`
- Square root of `x`

### `std.math.floor(x)` / `std.math.ceil(x)` / `std.math.round(x)`
- Floor, ceiling, nearest integer (half-away-from-zero)

### `std.math.sin(x)` / `std.math.cos(x)` / `std.math.tan(x)`
- Trigonometric functions; argument in radians

### `std.math.log(x)` / `std.math.log2(x)` / `std.math.log10(x)`
- Natural, base-2, and base-10 logarithms

### `std.math.pow(base, exp)`
- `base` raised to the power `exp`

### `std.math.min(a, b)` / `std.math.max(a, b)`
- Minimum / maximum of two numbers

### `std.math.pi`
- π ≈ 3.14159265358979… (constant)

### `std.math.e`
- Euler's number ≈ 2.71828182845904… (constant)

### `std.math.phi`
- Golden ratio ≈ 1.618033988749895… (constant)

### `std.math.inf`
- Positive infinity (constant)

### `std.math.nan()`
- Returns NaN

### `std.math.is_nan(x)`
- Returns `true` if `x` is NaN

### `std.math.is_inf(x, sign)`
- Returns `true` if `x` is infinite; `sign=0` matches any sign, `sign>0` matches positive, `sign<0` matches negative

### `std.math.sign(x)`
- Returns the sign of `x`: `-1`, `0`, or `1`; preserves int type for integer inputs

### `std.math.clamp(v, min, max)`
- Clamps `v` to the `[min, max]` range

### `std.math.trunc(x)`
- Truncates toward zero

### `std.math.exp(x)`
- `e^x`; errors: `RangeError` if result is not finite

### `std.math.exp2(x)`
- `2^x`; errors: `RangeError` if result is not finite

### `std.math.cbrt(x)`
- Cube root

### `std.math.hypot(x, y)`
- Euclidean distance `sqrt(x^2 + y^2)`

### `std.math.mod(x, y)`
- Floating-point modulo (IEEE 754 `fmod`); errors: `DivisionByZero` if `y == 0`
- For integer and named-type modulo, use the `mod` keyword operator instead.

### `std.math.acos(x)` / `std.math.asin(x)` / `std.math.atan(x)` / `std.math.atan2(y, x)`
- Inverse trigonometric functions; errors: `RangeError` on domain error

### `std.math.cosh(x)` / `std.math.sinh(x)` / `std.math.tanh(x)`
- Hyperbolic trigonometric functions; errors: `RangeError` if result is not finite

## std.rand

### `std.rand.float()`
- Uniform float in `[0.0, 1.0)`
- Auto-seeds from OS entropy on first call

### `std.rand.intn(n)`
- Uniform int in `[0, n)`
- Errors: `RangeError` if `n ≤ 0`

### `std.rand.between(lo, hi)`
- Uniform int in `[lo, hi]` inclusive
- Errors: `RangeError` if `lo > hi`

### `std.rand.seed(n)`
- Seeds the global PRNG with `n`
- Useful for reproducible test sequences

### `std.rand.choice(arr)`
- Returns a random element from `arr`
- Errors: `RangeError` on empty array, `TypeError` if not an array

### `std.rand.perm(n)`
- Returns a random permutation of `[0, n)` (Fisher-Yates shuffle)
- Errors: `RangeError` if `n < 0`

### `std.rand.norm_float()`
- Normally-distributed float (Box-Muller transform)

## std.json

### `std.json.parse(s)`
- Parses a JSON string and returns the corresponding gengo value
- JSON null → `null`, booleans → `bool`, numbers → `number`, strings → `string`, arrays → array, objects → map
- Errors: `TypeError` on invalid JSON

### `std.json.parse_value(s)`
- Parses a JSON string and returns a `std.JSONValue` variant value
- Use this when the JSON structure is not known ahead of time; the result can be pattern-matched exhaustively with `switch`
- Errors: `TypeError` on invalid JSON

### `std.json.stringify(v)`
- Serializes a gengo value to a JSON string
- Arrays → JSON arrays, maps → JSON objects (string keys required), scalars → JSON primitives
- Non-serializable values (struct instances, closures, etc.) emit `null`
- Returns `string`

### `std.json.valid(s)`
- Returns `true` if `s` is valid JSON, `false` otherwise

### `std.json.indent(src, indent_str)`
- Parses JSON and re-serialises with the given indentation; `indent_str` may be `"\t"` or 1–8 spaces
- Errors: `TypeError` on invalid JSON

### `std.json.Value` / `std.JSONValue`
- The `JSONValue` variant type; both names refer to the same type object
- Arms:

| Arm | Payload | JSON source |
|---|---|---|
| `.jnull` | — | `null` |
| `.jbool(b)` | `bool` | `true` / `false` |
| `.jint(n)` | `int` | integer numbers |
| `.jfloat(f)` | `float` | fractional numbers |
| `.jstr(s)` | `string` | string values |
| `.jarray(items)` | `[]JSONValue` | arrays |
| `.jobject(m)` | `[string]JSONValue` | objects |

```
doc := std.json.parse_value(src)

switch doc {
    case .jobject as m {
        switch m["name"] {
            case .jstr as s { std.io.println(s) }
        }
    }
    case .jarray as items {
        for item in items {
            switch item {
                case .jint as n   { std.io.println(n) }
                case .jfloat as f { std.io.println(f) }
            }
        }
    }
    case .jnull { std.io.println("null") }
}
```

## std.hex

### `std.hex.encode(data)`
- Encodes a string or array of bytes to a lowercase hex string

### `std.hex.decode(s)`
- Decodes a hex string to a string; errors: `TypeError` on invalid hex

## std.base64

### `std.base64.encode(data)`
- Encodes a string or array of bytes to base64

### `std.base64.decode(s)`
- Decodes a base64 string; errors: `TypeError` on invalid base64

### `std.base64.url_encode(data)` / `std.base64.url_decode(s)`
- URL-safe base64 variant (uses `-` and `_` instead of `+` and `/`)

## std.regexp

Backtracking NFA engine. All functions accept either a pattern string or a compiled regexp object returned by `std.regexp.compile`.

Supported syntax: `.` `*` `+` `?` `^` `$` `|` `()` `[...]` `[^...]` character ranges, `\d` `\D` `\w` `\W` `\s` `\S` shorthands.

Errors: `InvalidRegexp` on a malformed pattern.

### `std.regexp.match(pattern, s)`
- Returns `true` if `pattern` matches anywhere in `s`

### `std.regexp.find(pattern, s)`
- Returns the first matching substring, or `null` if not found

### `std.regexp.find_all(pattern, s)`
- Returns array of all non-overlapping matches

### `std.regexp.replace(pattern, s, repl)`
- Replaces first occurrence of `pattern` in `s` with `repl`; returns new string

### `std.regexp.split(pattern, s)`
- Splits `s` at each match of `pattern`; returns array of strings

### `std.regexp.compile(pattern)`
- Compiles `pattern` into a reusable `std.Regexp` object
- `std.Regexp` is the named type for compiled regular expressions
- The object supports method-call syntax: `re.match(s)`, `re.find(s)`, `re.find_all(s)`, `re.replace(s, repl)`, `re.split(s)`

## std.template

Go-style text templates with `{{` / `}}` delimiters.

### `std.template.render(src, data)`
- Parses and executes `src` against `data` in one call
- Returns the rendered string
- Errors: `InvalidTemplate` on malformed template, `TypeError` on type mismatch

### `std.template.parse(src)`
- Compiles `src` into a reusable `Template` object
- Errors: `InvalidTemplate` on malformed template

### `Template.execute(data)`
- Executes a compiled template against `data`
- Returns the rendered string

### `std.template.valid(src)`
- Returns `true` if `src` is a well-formed template, `false` otherwise

### `std.template.add_func(tmpl, name, fn)`
- Registers a named function on a compiled template for use in `{{call_fn}}` tags
- Returns `null`

### Syntax

| Tag | Description |
|-----|-------------|
| `{{.field}}` | Field/key access on current context |
| `{{.a.b}}` | Chained field access |
| `{{.}}` | Current context value |
| `{{if .expr}}…{{end}}` | Conditional block |
| `{{if .expr}}…{{else}}…{{end}}` | Conditional with else |
| `{{with .expr}}…{{end}}` | Scoped context block |
| `{{/* comment */}}` | Comment (emits nothing) |

`range` iterates over arrays: `{{range .items}}…{{end}}` binds each element as `.` in turn. An optional `{{else}}` block runs when the array is empty.

## std.Time / std.time

`std.Time` is a named type over `int`. Raw value is milliseconds since Unix epoch, UTC. All arithmetic and comparison operators work through the underlying `int`.

### `std.time` — constructors and utilities

| Function | Returns | Notes |
|---|---|---|
| `std.time.now()` | `std.Time` | Current wall time |
| `std.time.from_unix(sec)` | `std.Time` | Integer seconds → Time |
| `std.time.from_unix_ms(ms)` | `std.Time` | Integer milliseconds → Time |
| `std.time.parse(str, fmt)` | `std.Time` | Errors: `TypeError`/`RangeError` on bad input |

**Duration constants** (plain `int`, milliseconds):
`std.time.ms` `std.time.second` `std.time.minute` `std.time.hour` `std.time.day`

### Methods on `std.Time`

| Method | Returns | Notes |
|---|---|---|
| `.unix()` | `int` | Whole seconds since epoch |
| `.unix_ms()` | `int` | Same as raw value |
| `.parts()` | `map` | Keys: `year month day hour min sec ms weekday` (0=Sunday) |
| `.format(fmt)` | `string` | |
| `.add_ms(n)` | `std.Time` | |
| `.add_s(n)` | `std.Time` | |
| `.add_m(n)` | `std.Time` | |
| `.add_h(n)` | `std.Time` | |
| `.sub(t2)` | `int` | ms difference, may be negative |
| `.before(t2)` | `bool` | |
| `.after(t2)` | `bool` | |
| `.equal(t2)` | `bool` | |
| `.is_zero()` | `bool` | |
| `.since(t2)` | `int` | Milliseconds elapsed since `t2` (may be negative) |
| `.until(t2)` | `int` | Milliseconds until `t2` (may be negative) |
| `.add_date(years, months, days, ms)` | `std.Time` | Adds calendar units |
| `.iso_week()` | `map` | Keys: `year`, `week`, `day` (ISO 8601 week date) |

### `std.time.parse_duration(s)`
- Parses a duration string like `"1h30m"`, `"2.5s"`, `"100ms"` into milliseconds
- Returns `float`

### Format verbs

| Verb | Output | Verb | Output |
|---|---|---|---|
| `%Y` | year (4 digits) | `%H` | hour `00`–`23` |
| `%m` | month `01`–`12` | `%M` | minute `00`–`59` |
| `%d` | day `01`–`31` | `%S` | second `00`–`59` |
| `%L` | millisecond `000`–`999` | `%A` | weekday name |
| `%a` | short weekday | `%B` | month name |
| `%b` | short month | `%%` | literal `%` |

`parse` accepts: `%Y %m %d %H %M %S` only. All times are UTC.
