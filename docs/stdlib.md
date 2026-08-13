# Gengoscript Standard Library Reference

This page is the reference for the built-in `std` module and its namespaces.

For the language rules around imports, values, and types, see `language.md`.

## Import

```gengo
std := import("std")
```

`std` is always available via `import("std")` and is exposed as a struct-backed namespace object. Relative source imports use the same namespace model.

The entries below describe the public library surface. This page is intentionally reference-shaped: look up a function here once you already know which part of `std` you need.

Where a function is naturally generic, this page uses informal generic-style
signatures like `[T]` or `[K, V]` to show the type relationship between
arguments and results. These are documentation signatures, not callable
syntax on `std` itself.

## Namespace Index

| Namespace | Purpose |
|---|---|
| `std.io`, `std.fmt` | Script output/input and formatted text. |
| `std.core` | Collections, type predicates, errors, cloning, and GC inspection. |
| `std.Arg` | Variant used for heterogeneous scalar arguments. |
| `std.conv` | Explicit value conversions. |
| `std.string`, `std.bytes` | UTF-8 string operations and byte-oriented binary operations. |
| `std.array`, `std.sort` | Array construction and sorting. |
| `std.math`, `std.rand` | Numeric operations and non-cryptographic pseudorandom values. |
| `std.json`, `std.hex`, `std.base64` | Data interchange and text encodings. |
| `std.crypto` | Hashing, HMAC, AEAD encryption, key derivation, and asymmetric cryptography. |
| `std.regexp`, `std.template` | Pattern matching and template rendering. |
| `std.Time`, `std.time` | Time values and time-related helpers. |

Capability modules such as `cap:env` and `cap:fs` are deliberately not part
of `std`; their authority and availability are documented in `capabilities.md`.

## Reference Conventions

Unless an entry says otherwise, values returned by `std` are owned by the
script runtime. A returned array or map is a normal mutable Gengoscript value;
assigning it aliases that collection under the language rules in `language.md`.
An entry that says “Errors” names a runtime panic, not an ordinary returned
`error` value. Check each signature: capability-style `(value, error)` results
are not the general `std` convention. Complexity is omitted where no stable
implementation-independent bound is currently guaranteed.

## std.io

### `std.io.println(...args)`
- Prints arguments followed by a newline.
- Returns `null`.

### `std.io.print(...args)`
- Prints arguments without a trailing newline.
- Returns `null`.

### `std.io.printf(fmt, ...args)`
- `fmt` is a string with Go-style format verbs.
- Errors: `ArityMismatch` when placeholder count and args differ; `TypeError` when arg type does not match verb; `RangeError` when formatted output exceeds 64 MB.
- To get the formatted string instead of printing it, use `std.fmt.format`.

### `std.io.eprint(...args)`
- Like `std.io.print` but writes to stderr.
- Returns `null`.

### `std.io.eprintf(fmt, ...args)`
- Like `std.io.printf` but writes to stderr. The same 64 MB output cap applies.
- Returns `null`.

### `std.io.eprintln(...args)`
- Like `std.io.println` but writes to stderr.
- Returns `null`.

### `std.io.read(max_bytes int)`
- Reads up to `max_bytes` bytes from stdin in a single call (capped at the runtime `max_input_bytes` limit).
- Returns the bytes as a string, or `null` on EOF.

### `std.io.read_all()`
- Reads all of stdin until EOF (capped at the runtime `max_input_bytes` limit).
- Returns the full content as a string, or `null` if nothing was read.

### `std.io.readline()`
- Reads one line from stdin (capped at the runtime `max_input_bytes` limit), stripping the trailing `\n` / `\r\n`.
- Returns the line as a string, or `null` on EOF.

### `std.io` format verbs

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
- Errors: `ArityMismatch` when placeholder count and args differ; `TypeError` when arg type does not match verb; `RangeError` when formatted output exceeds 64 MB.

### `std.fmt.stringify(v)`
- Returns `v` rendered as a string, exactly as `std.io.println` would display it.
- Works for any value: scalars, arrays, maps, structs, variants, named types.
- Returns `""` for a `null` argument.
- Errors: `RangeError` when the rendered string exceeds 64 MB.

## std.core

### `std.core.len(x)`
- String: rune count (Unicode code points)
- Array/map/struct instance: element/field count
- Tuple: element count
- Errors: `TypeError` on unsupported input

### `std.core.bytelen(s)`
- String: UTF-8 byte count
- Errors: `TypeError` on unsupported input

### `std.core.append[T](arr []T, ...items T)`
- Returns new array with appended items
- Errors: `TypeError` if first arg is not array

### `std.core.error(msg)`
- Creates first-class error value
- `msg` must be string

### `std.core.is_error(v)`
- Returns `true` iff `v` is an error value

### `std.core.recover()`
- Called inside a `defer` function during a panic unwind
- Returns the original panic payload and marks the panic as recovered; the
  payload may be an `error` or another non-null value from `trap`
- Returns `null` if not unwinding or if already recovered

### `std.core.type_of(v)`
- Returns a stable type name
- Plain scalars report names like `int`, `float`, `decimal`, `bigint`, `bool`, `string`, `rune`, `error`, `null`
- A statically known named scalar expression returns its declared name, even though its runtime value is the base scalar
- Dynamically typed named scalars report their base runtime type; named runtime values and struct instances report their declared type name
- Anonymous typed arrays and maps report `array` and `map`

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

### `std.core.keys[K, V](map [K]V)`
- Returns array of all keys in a map
- Errors: `TypeError` on non-map

### `std.core.values[K, V](map [K]V)`
- Returns array of all values in a map
- Errors: `TypeError` on non-map

### `std.core.has[K, V](map [K]V, key K)`
- Returns `true` iff `key` exists in `map`
- Errors: `TypeError` on non-map

### `std.core.delete[K, V](map [K]V, key K)`
- Removes `key` from `map`; returns the removed value or `null`
- Errors: `TypeError` on non-map

### `std.core.contains[T](arr []T, needle T)`
- Returns `true` iff `arr` contains `needle` (uses `deep_equal`)
- Errors: `TypeError` on non-array

### `std.core.remove[T](arr []T, index int)`
- Returns a new array with the element at `index` removed
- Errors: `TypeError` on non-array, `IndexOutOfBounds`

## std.Arg

`std.Arg` is a built-in variant that covers all primitive scalar types. It
exists so library authors can write heterogeneous variadic functions without
exposing the unsafe `any` type to callers.

### Arms

| Arm | Payload type |
|-----|-------------|
| `std.Arg.Int(n)` | `int` |
| `std.Arg.Float(f)` | `float` |
| `std.Arg.Decimal(d)` | `decimal` (any scale) |
| `std.Arg.Rune(r)` | `rune` |
| `std.Arg.Bool(b)` | `bool` |
| `std.Arg.Str(s)` | `string` |
| `std.Arg.Err(e)` | `error` |

### Usage

Declare a variadic parameter typed `std.Arg` and switch over the arm to
dispatch on the actual scalar type:

```gengo
func log_args(prefix string, ...args std.Arg) string {
    out := prefix + ":"
    for a in args {
        switch a {
            case .Int   as n { out = out + " int:" + std.conv.to_string(n) }
            case .Str   as s { out = out + " str:" + s }
            case .Bool  as b { out = out + " bool:" + std.conv.to_string(b) }
            case .Float as f { out = out + " float:" + std.conv.to_string(f) }
            case .Rune  as r { out = out + " rune:" + std.conv.to_string(r) }
            case .Err   as e { out = out + " err:" + string(e) }
            case .Decimal as d { out = out + " dec:" + std.conv.to_string(d) }
        }
    }
    return out
}

log_args("x", std.Arg.Int(42), std.Arg.Bool(true), std.Arg.Str("hi"))
```

## std.conv

### `std.conv.to_int(x)`
- Converts number/rune/boolean/string to integer-number (truncate)
- Errors: `TypeError` on invalid conversion

### `std.conv.to_float(x)`
- Converts number/rune/boolean/string to float-number
- Errors: `TypeError` on invalid conversion

### `std.conv.to_bool(x)`
- Explicit conversion to boolean: `false`, `null`, `0`, and `""`
  convert to `false`; everything else converts to `true`
- Named values convert through their underlying value
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
- Errors: `RangeError` if `n < 0` or if the result would exceed 64 MB

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
- Pads to a **byte width** using the bytes in `pad`; a multi-byte `pad` can be
  truncated at the final byte boundary. Do not use these functions when the
  result must preserve UTF-8 rune boundaries.

### `std.string.equal_fold(a, b)`
- Case-insensitive equality for ASCII strings

### `std.string.contains_any(s, chars)`
- Returns `true` if any byte in `chars` appears in `s`; it is not a
  Unicode-rune operation.

### `std.string.trim_left(s, chars)` / `std.string.trim_right(s, chars)`
- Trims leading or trailing bytes that appear in `chars` (single-byte characters only; multi-byte runes in `chars` are not recognised)

### `std.string.trim_prefix(s, prefix)` / `std.string.trim_suffix(s, suffix)`
- Removes `prefix` or `suffix` if present; returns `s` unchanged otherwise

### `std.string.split_n(s, sep, n)`
- Splits `s` by `sep` into at most `n` substrings; final element contains the rest
- With an empty separator, splits at UTF-8 codepoint boundaries (same behaviour as `std.string.split(s, "")`)

## std.array

### `std.array.filter[T](arr []T, pred func(T) bool)`
- Returns array of elements where `pred(element)` is `true`

### `std.array.map[T, U](arr []T, fn func(T) U)`
- Returns array of `fn(element)` for each element

### `std.array.reduce[T, U](arr []T, fn func(U, T) U, init U)`
- Folds `arr` left-to-right: `fn(init, arr[0])`, then `fn(result, arr[1])`, etc.

### `std.array.slice[T](arr []T, start int, end int)`
- Returns sub-array from `start` (inclusive) to `end` (exclusive)

### `std.array.zip[A, B](a []A, b []B)`
- Returns array of pairs `[a[0], b[0]], [a[1], b[1]], …`

### `std.array.flat(arr)`
- Flattens one level of nesting: `[[1,2],[3]]` → `[1,2,3]`

### `std.array.find[T](arr []T, pred func(T) bool)`
- Returns first element where `pred(element)` is `true`, or `null`

### `std.array.find_index[T](arr []T, pred func(T) bool)`
- Returns index of first element where `pred(element)` is `true`, or `-1`

### `std.array.all[T](arr []T, pred func(T) bool)`
- Returns `true` if `pred(element)` is `true` for every element

### `std.array.any[T](arr []T, pred func(T) bool)`
- Returns `true` if `pred(element)` is `true` for at least one element

### `std.array.chunk[T](arr []T, size int)`
- Splits `arr` into sub-arrays of length `size`; last chunk may be shorter
- Errors: `RangeError` if `size <= 0`

## std.sort

### `std.sort.asc[T ordered](arr []T)`
- Returns a new array sorted in ascending order (int, float, or string elements); the original is unchanged

### `std.sort.desc[T ordered](arr []T)`
- Returns a new array sorted in descending order; the original is unchanged

### `std.sort.by[T](arr []T, cmp func(T, T) ...)`
- Returns a new array sorted using a comparator called as `cmp(left, right)`; the original is unchanged
- `cmp` may return a negative / zero / positive `int` or `float`, or a `bool` where `true` means `left < right`

## std.math

### `std.math.abs(x)`
- Absolute value of `x`
- Integer inputs stay `int`; floating inputs stay `float`

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
- When both inputs are `int`, the result stays `int`

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
- JSON null → `null`, booleans → `bool`, strings → `string`, arrays → array, objects → map
- Integer JSON numbers become `int`; non-integral JSON numbers become `float`
- A JSON integer outside `int`'s 64-bit signed range silently becomes a `float` (and, for `std.json.stringify`, prints with the corresponding loss of precision) — there is no automatic promotion to `bigint`
- Errors: `TypeError` on invalid JSON

### `std.json.parse_value(s)`
- Parses a JSON string and returns a `std.JSONValue` variant value
- Use this when the JSON structure is not known ahead of time; the result can be pattern-matched exhaustively with `switch`
- Integer JSON numbers become `.jint`; non-integral JSON numbers become `.jfloat`
- Errors: `TypeError` on invalid JSON

### `std.json.stringify(v)`
- Serializes a gengo value to a JSON string
- Arrays → JSON arrays, maps → JSON objects (string keys required), scalars → JSON primitives
- Named scalar values serialize as their underlying scalar
- Non-serializable values (struct instances, closures, etc.) emit `null`
- Returns `string`

### `std.json.valid(s)`
- Returns `true` if `s` is valid JSON, `false` otherwise

### `std.json.indent(src, indent_str)`
- Parses JSON and re-serialises with the given indentation; `indent_str` must be `"\t"` or exactly 1, 2, 3, 4, or 8 spaces (the underlying widths Zig's JSON stringifier supports — 5, 6, and 7 spaces are not available)
- Errors: `TypeError` on invalid JSON, or on an `indent_str` outside the supported set

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

## std.crypto

Cryptographic hashing, authentication, encryption, and key derivation.
All functions that return raw bytes return them as a **string** (Gengo's byte-string type); use `std.hex.encode` / `std.base64.encode` to convert to text.
Hash and HMAC outputs are returned as lowercase hex strings.

### Hash functions

#### `std.crypto.sha256(data)`
- SHA-256 of `data`; returns a 64-character lowercase hex string.

#### `std.crypto.sha512(data)`
- SHA-512 of `data`; returns a 128-character lowercase hex string.

#### `std.crypto.blake3(data)`
- BLAKE3 of `data`; returns a 64-character lowercase hex string.

#### `std.crypto.md5(data)`
- MD5 of `data`; returns a 32-character lowercase hex string. Use only for legacy compatibility — MD5 is cryptographically broken.

#### `std.crypto.sha1(data)`
- SHA-1 of `data`; returns a 40-character lowercase hex string. Use only for legacy compatibility — SHA-1 is cryptographically weak.

### HMAC

#### `std.crypto.hmac_sha256(key, data)`
- HMAC-SHA256; returns a 64-character lowercase hex string.

#### `std.crypto.hmac_sha512(key, data)`
- HMAC-SHA512; returns a 128-character lowercase hex string.

### Authenticated encryption (AEAD)

All seal functions return ciphertext + authentication tag as a raw byte string.
All open functions return the decrypted plaintext string, or raise `CryptoError` if the tag is invalid.

#### `std.crypto.aes_gcm_seal(key, nonce, plaintext)`
- AES-GCM encryption. `key` must be 16 bytes (AES-128) or 32 bytes (AES-256); `nonce` must be 12 bytes.

#### `std.crypto.aes_gcm_open(key, nonce, ciphertext)`
- AES-GCM decryption. Errors: `CryptoError` on authentication failure, `TypeError` on wrong key/nonce length.

#### `std.crypto.chacha20poly1305_seal(key, nonce, plaintext)`
- ChaCha20-Poly1305 encryption. `key` must be 32 bytes; `nonce` must be 12 bytes.

#### `std.crypto.chacha20poly1305_open(key, nonce, ciphertext)`
- ChaCha20-Poly1305 decryption. Errors: `CryptoError` on authentication failure.

#### `std.crypto.xchacha20poly1305_seal(key, nonce, plaintext)`
- XChaCha20-Poly1305 encryption. `key` must be 32 bytes; `nonce` must be **24 bytes** (vs 12 for ChaCha20-Poly1305). The longer nonce makes it safe to generate randomly.

#### `std.crypto.xchacha20poly1305_open(key, nonce, ciphertext)`
- XChaCha20-Poly1305 decryption. Errors: `CryptoError` on authentication failure.

### Key derivation

#### `std.crypto.hkdf_sha256(ikm, salt, info, length)`
- HKDF-SHA256 (RFC 5869) key derivation. `ikm` is the input key material; `salt` and `info` are optional context strings (pass `""` to omit). `length` is the number of output bytes (integer, max 8160). Returns raw bytes.

#### `std.crypto.argon2id(password, salt, memory_kb, threads, iterations, key_length)`
- Argon2id password hashing / key derivation. `memory_kb`, `threads`, and `iterations` are integers. Returns raw bytes of length `key_length`. Recommended minimum: `memory_kb=65536`, `threads=4`, `iterations=3`.

#### `std.crypto.bcrypt_hash(password, cost)`
- bcrypt password hash. `cost` is the work factor (integer, 4–31; typical production value: 12). Returns a 60-character bcrypt hash string.

#### `std.crypto.bcrypt_verify(hash, password)`
- Verifies `password` against a bcrypt `hash`. Returns `true` or `false`.

### Asymmetric cryptography

#### `std.crypto.ed25519_sign(seed, message)`
- Ed25519 signature. `seed` must be 32 bytes (the private key seed). Returns a 64-byte raw signature string.

#### `std.crypto.ed25519_verify(pubkey, signature, message)`
- Verifies an Ed25519 `signature` over `message` with the given 32-byte `pubkey`. Returns `true` or `false`.

#### `std.crypto.x25519(secret, pubkey)`
- X25519 Diffie-Hellman (RFC 7748). `secret` and `pubkey` must each be 32 bytes. Returns the 32-byte shared secret as a raw byte string.

### Utilities

#### `std.crypto.rand_bytes(n)`
- Returns `n` cryptographically secure random bytes as a raw byte string.

#### `std.crypto.constant_time_equal(a, b)`
- Compares two strings in constant time. Returns `true` if they are identical. Use this to compare MACs or other secrets to avoid timing side-channels.

## std.bytes

Raw byte string construction, decomposition, integer encoding/decoding, and
byte-indexed search. Unlike `std.string`, all positions and lengths here are
**byte offsets**, not rune indices.

**Background**: Gengo strings are UTF-8. A typed rune declaration followed by
`string(r)` for a value above 127 produces a multi-byte UTF-8 sequence, not
the raw byte value. `std.bytes.u8` is the escape hatch: it takes any integer
0–255 and produces a 1-byte binary string.

### `std.bytes.u8(n)`
- Returns a 1-byte binary string containing raw byte `n & 255`
- This is the primitive for building binary data; converting a rune value to
  `string` is **not** equivalent (it produces UTF-8 bytes)

### `std.bytes.pack(bs)`
- Converts an array of integer byte values (0–255 each) to a binary string
- Each element is truncated to its low 8 bits

### `std.bytes.repeat(s, n)`
- Returns `s` repeated `n` times as a single binary string
- Errors: `RangeError` if the result would exceed 64 MB

### `std.bytes.unpack(s)`
- Returns an array of integer byte values (0–255) for each byte in `s`

### `std.bytes.at(s, i)`
- Returns the integer byte value (0–255) at byte offset `i`
- Errors: `RangeError` if `i` is out of bounds

### `std.bytes.slice(s, from, to)`
- Returns the byte substring `s[from:to]` (byte-indexed, not rune-indexed)
- Errors: `RangeError` if indices are out of range

### `std.bytes.len(s)`
- Returns the number of bytes in `s` (same as `std.core.bytelen`)

### Integer encoding

All encoding functions accept any integer and truncate to the appropriate width.

| Function | Width | Byte order |
|---|---|---|
| `std.bytes.u16be(n)` | 2 bytes | big-endian |
| `std.bytes.u32be(n)` | 4 bytes | big-endian |
| `std.bytes.u64be(n)` | 8 bytes | big-endian |
| `std.bytes.u16le(n)` | 2 bytes | little-endian |
| `std.bytes.u32le(n)` | 4 bytes | little-endian |
| `std.bytes.u64le(n)` | 8 bytes | little-endian |

### Float encoding

All float encoding functions accept a `float` or `int` argument and produce IEEE 754 bytes.

| Function | Width | Byte order |
|---|---|---|
| `std.bytes.f32be(n)` | 4 bytes | big-endian |
| `std.bytes.f64be(n)` | 8 bytes | big-endian |
| `std.bytes.f32le(n)` | 4 bytes | little-endian |
| `std.bytes.f64le(n)` | 8 bytes | little-endian |

### Integer decoding

All decoding functions take a binary string `s` and byte offset `i`.
Errors: `RangeError` if there are insufficient bytes at `i`.

| Function | Width | Byte order | Return |
|---|---|---|---|
| `std.bytes.u16be_at(s, i)` | 2 bytes | big-endian | int (0–65535) |
| `std.bytes.u32be_at(s, i)` | 4 bytes | big-endian | int (0–4294967295) |
| `std.bytes.u64be_at(s, i)` | 8 bytes | big-endian | int (i64 bit pattern) |
| `std.bytes.u16le_at(s, i)` | 2 bytes | little-endian | int (0–65535) |
| `std.bytes.u32le_at(s, i)` | 4 bytes | little-endian | int (0–4294967295) |
| `std.bytes.u64le_at(s, i)` | 8 bytes | little-endian | int (i64 bit pattern) |

### Float decoding

All float decoding functions take a binary string `s` and byte offset `i`.
Errors: `RangeError` if there are insufficient bytes at `i`.

| Function | Width | Byte order | Return |
|---|---|---|---|
| `std.bytes.f32be_at(s, i)` | 4 bytes | big-endian | float |
| `std.bytes.f64be_at(s, i)` | 8 bytes | big-endian | float |
| `std.bytes.f32le_at(s, i)` | 4 bytes | little-endian | float |
| `std.bytes.f64le_at(s, i)` | 8 bytes | little-endian | float |

### `std.bytes.index_of(s, sub)`
- Returns the byte offset of the first occurrence of `sub` in `s`, or `-1`

### `std.bytes.contains(s, sub)`
- Returns `true` if `sub` appears anywhere in `s`

### `std.bytes.starts_with(s, prefix)`
- Returns `true` if `s` begins with `prefix`

### `std.bytes.ends_with(s, suffix)`
- Returns `true` if `s` ends with `suffix`

### `std.bytes.count(s, sub)`
- Returns the number of non-overlapping occurrences of `sub` in `s`

### `std.bytes.replace(s, old, new)`
- Returns a copy of `s` with every occurrence of `old` replaced by `new`

### Example

```gengo
std := import("std")
b   := std.bytes

// Build a 4-byte big-endian frame
frame := b.u16be(0xDEAD) + b.u16be(0xBEEF)
std.io.println(std.hex.encode(frame))   // "deadbeef"

// Read it back
std.io.println(b.u16be_at(frame, 0))    // 57005
std.io.println(b.u16be_at(frame, 2))    // 48879

// Pack/unpack round-trip
raw   := b.pack([0x01, 0x80, 0xFF])
parts := b.unpack(raw)
std.io.println(parts[1])                // 128  (not 2 as rune() would give)
```

## std.regexp

Backtracking NFA engine. All functions accept either a pattern string or a compiled regexp object returned by `std.regexp.compile`.

Supported syntax: `.` `*` `+` `?` `^` `$` `|` `()` `[...]` `[^...]` character ranges, `\d` `\D` `\w` `\W` `\s` `\S` shorthands.

Errors: `InvalidRegexp` on a malformed pattern; `RangeError` when the input string `s` exceeds 1 MB.

When a pattern's group alternation nesting exceeds 200 levels, the engine treats the input as not matching rather than erroring.

### `std.regexp.match(pattern, s)`
- Returns `true` if `pattern` matches anywhere in `s`

### `std.regexp.find(pattern, s)`
- Returns the first matching substring, or `null` if not found

### `std.regexp.find_all(pattern, s)`
- Returns array of all non-overlapping matches

### `std.regexp.replace(pattern, s, repl)`
- Replaces every non-overlapping occurrence of `pattern` in `s` with `repl`; returns new string

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

### `std.template.execute(tmpl, data)`
- Executes a compiled template object returned by `std.template.parse`
- Equivalent to `tmpl.execute(data)`
- Returns the rendered string

### `Template.execute(data)`
- Executes a compiled template against `data`
- Returns the rendered string

### `std.template.valid(src)`
- Returns `true` if `src` is a well-formed template, `false` otherwise

### `std.template.add_func(tmpl, name, fn)`
- Registers a named function on a compiled template for use in `{{call_fn}}` tags
- Returns `null`

`Template.add_func(name, fn)` is the equivalent method-call form.

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
| `std.time.since(t)` | `float` | Milliseconds elapsed since `t` (now − t); equivalent to `t.since()` |
| `std.time.until(t)` | `float` | Milliseconds until `t` (t − now); equivalent to `t.until()` |
| `std.time.sleep(ms)` | `null` | Suspends execution for an integer number of milliseconds; operation budget is charged one operation per requested nanosecond before suspension. Only supported at top-level execution (the CLI, or an embedding's `run`/`runPath`/`begin`) — calling it from a function invoked via `engine_call`/`Runtime.call` fails immediately with `SleepNotAllowed` rather than suspending. See `embedding.md`'s "std.time.sleep and Suspension" section for how a host resumes a suspended script. |

**Duration constants** (plain `int`, milliseconds):
`std.time.ms` `std.time.second` `std.time.minute` `std.time.hour` `std.time.day`

### Methods on `std.Time`

| Method | Returns | Notes |
|---|---|---|
| `.unix()` | `int` | Whole seconds since epoch |
| `.unix_ms()` | `float` | Milliseconds since epoch |
| `.parts()` | `map` | Keys: `year month day hour min sec ms weekday` (0=Sunday) |
| `.format(fmt)` | `string` | Errors: `NoSpaceLeft` when the expanded format string exceeds 512 bytes |
| `.add_ms(n)` | `std.Time` | |
| `.add_s(n)` | `std.Time` | |
| `.add_m(n)` | `std.Time` | |
| `.add_h(n)` | `std.Time` | |
| `.sub(t2)` | `float` | ms difference `self − t2`, may be negative |
| `.before(t2)` | `bool` | |
| `.after(t2)` | `bool` | |
| `.equal(t2)` | `bool` | |
| `.is_zero()` | `bool` | |
| `.since()` | `float` | Milliseconds elapsed since this time (now − self) |
| `.until()` | `float` | Milliseconds until this time (self − now) |
| `.add_date(years, months, days)` | `std.Time` | Adds calendar units; errors: `RangeError` if the delta causes an i32 overflow in any component |
| `.iso_week()` | `map` | Keys: `year`, `week` |

### `std.time.parse_duration(s)`
- Parses a duration string like `"1h30m"`, `"2.5s"`, `"100ms"`, `"1us"`, or `"1ns"` into milliseconds
- Supports leading `+`/`-`, compound forms, bare zero, and both `µs` and `μs`
- Returns `float`

### `std.time` format verbs

| Verb | Output | Verb | Output |
|---|---|---|---|
| `%Y` | year (4 digits) | `%H` | hour `00`–`23` |
| `%m` | month `01`–`12` | `%M` | minute `00`–`59` |
| `%d` | day `01`–`31` | `%S` | second `00`–`59` |
| `%L` | millisecond `000`–`999` | `%A` | weekday name |
| `%a` | short weekday | `%B` | month name |
| `%b` | short month | `%%` | literal `%` |

`parse` accepts: `%Y` (4-digit year), `%y` (2-digit year, 2000-based), `%m`, `%d`, `%H`, `%M`, `%S`, `%L` (milliseconds), `%B` (full month name), `%a` (weekday name, consumed but not used), `%W` (week number, consumed but not used). All times are UTC.
