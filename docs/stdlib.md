# gengo Standard Library Reference

## Import

```gengo
std := import("std")
```

`std` is always available via `import("std")` and is exposed as a struct-backed namespace object. Relative source imports use the same namespace model.

## std.io

### `std.io.println(...args)`
- Prints arguments followed by a newline.
- Returns `null`.

### `std.io.print(...args)`
- Prints arguments without a trailing newline.
- Returns `null`.

### `std.io.printf(fmt, ...args)`
- `fmt` is string.
- Supported verbs: `%v`, `%s`, `%d`, `%f`, `%t`, `%%`.
- Errors:
  - `ArityMismatch` when placeholder count and args differ
  - `TypeError` when arg type does not match verb

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

## std.conv

### `std.conv.to_int(x)`
- Converts number/rune/boolean/string to integer-number (truncate)
- Errors: `TypeError` on invalid conversion

### `std.conv.to_float(x)`
- Converts number/rune/boolean/string to float-number
- Errors: `TypeError` on invalid conversion

### `std.conv.to_bool(x)`
- Truthy conversion to boolean

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
- Returns `(head, tail)` split on the first occurrence of `sep`
- Returns `(null, null)` if `sep` is not present

### `std.string.builder()`
- Creates mutable string builder with `.write`, `.str`, and `.reset`

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

## std.json

### `std.json.parse(s)`
- Parses a JSON string and returns the corresponding gengo value
- JSON null → `null`, booleans → `bool`, numbers → `number`, strings → `string`, arrays → array, objects → map
- Errors: `TypeError` on invalid JSON

### `std.json.stringify(v)`
- Serializes a gengo value to a JSON string
- Arrays → JSON arrays, maps → JSON objects (string keys required), scalars → JSON primitives
- Non-serializable values (struct instances, closures, etc.) emit `null`
- Returns `string`

### `std.json.valid(s)`
- Returns `true` if `s` is valid JSON, `false` otherwise
