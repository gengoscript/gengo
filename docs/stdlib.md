# gengo Standard Library Reference

## Import

```gengo
std := import("std")
```

`std` is always available via `import("std")`. Relative source imports are separate and return struct-backed module objects.

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
