# Gengoscript Changelog

## Unreleased

### Language

- **Generic struct and variant types** — `type Stack[T] struct { items []T }` and `type Result[T, E] variant { ok(value T), err(e E) }`. Instantiate by supplying concrete type arguments: `Stack[int]{ items: [] }`, `Result[int, string].ok{ value: 42 }`. Type parameters are substituted at compile time; each instantiation is a distinct concrete type. Nested generic fields (e.g. `Stack[T]` inside `Wrapper[T]`) resolve correctly when the outer type is instantiated.
- **Generic functions** — `func map_array[T, U](xs []T, f func(T) U) []U`. Call with explicit type arguments: `map_array[int, string](nums, fn)`. Type parameters are erased at runtime (treated as `any`); the type-argument count is validated at the call site. Type inference is not yet supported.
- **Generic type aliases** — `type IntStack Stack[int]` declares a named alias for a concrete generic instantiation. The alias is fully transparent: it may be used anywhere the underlying type may be used, including struct literals, function parameter types, and `.type` comparisons.
- **Named error types** — `type NotFound error` declares a named error variant. Named errors are ordinary `error` values and can be distinguished by `.type`: `e.type == NotFound`, `switch e.type { case NotFound { ... } }`.
- **`when` guards on switch cases** — Both value and variant cases may carry a `when` condition. The guard sees the `as` binding. A failed guard falls through to the next case: `case .ok as v when v > 0 { ... }`.
- **Exhaustiveness checking for variant switch** — A variant `switch` inside a function is now checked at compile time. Every arm must be covered by at least one unguarded case, or the switch must have a `default`. A missing arm is a `NonExhaustiveSwitch` compile error.
- **Default parameter values** — Trailing function parameters may declare a literal default (`func f(a int, b int = 1) int`). Callers may omit any suffix of defaulted parameters.
- **Hex, binary, and octal literals** — `0xFF`, `0b1010_1111`, `0o755`. Digit separators (`_`) work in all bases. Valid in expressions, range bounds, and default values.
- **Enum representation values** — `type Status enum { pending = 0, active = 1, done = 2 }`. Unspecified members auto-increment. `.int` on a value returns its integer representation. `T.from_int(n)` does the reverse lookup, returning `?T`.
- **Enum value properties** — `.name` and `.int` are now first-class field accesses on any enum value.
- **Struct zero-initialisation** — `var p Point` now creates a zero-value struct instance (fields set to `0`, `false`, `""` by their type). Previously it produced `null`.
- **Enum zero-initialisation** — `var s Status` now initialises to the first declared member. Previously it panicked.
- **Range bounds with any numeric base** — `type Port int range 1..0xFFFF` and similar are now valid.
- **Named type bounds** — `T.first` and `T.last` on ranged named types return the boundary as a named-type value.

### Standard Library

- **`std.Arg`** — Built-in variant covering all primitive scalar types (`Int`, `Float`, `Decimal`, `Rune`, `Bool`, `Str`, `Err`). Use it to write type-safe heterogeneous variadic functions without exposing `any`.

### Fixes

- Struct and enum variable declarations following a `std` import no longer trigger a spurious "unknown field in std" compile error.
- Arity mismatch errors now show `expected 1-2 argument(s)` when a function has defaults, and no longer include a stray leading comma in the function signature.
- Unknown `std.*` namespace fields now suggest the closest matching name in the error message.

---

## v0.5.0 — 2026-06-15

### Language

- **Boolean-only conditions** — `if`, `not`, `and`, `or`, and template `{{if}}` now require actual `bool` values. Non-boolean values (non-zero integers, non-null strings, etc.) that were previously treated as truthy/falsy now produce a runtime `TypeError`. Use `std.conv.to_bool` for explicit conversion.
- **Type names cannot be shadowed** — No binding form may use a type name: variables, functions, parameters, loop variables, and named returns all reject primitive type names and every declared type.
- **Subtypes of any scalar named type** — `subtype Child Parent` now accepts any scalar named parent (`bool`, `string`, `decimal` join `int`/`float`/`rune`). `range`/`cycle` constraints still require a numeric parent.
- **Named string concatenation** — `+` on two values of the same named string type preserves the named type.
- **Predicate custom messages** — A predicate may declare a custom failure message: `predicate func(x) { ... } message "must be positive"`.
- **Predicate inheritance** — Subtypes inherit the parent’s predicate. A subtype with its own predicate must satisfy both.
- **Bare type parameters in interface specs** — Interface method parameters can be written as bare types, Go-style: `add(float) float`.
- **Enum subtype validation** — `subtype Bogus Days { tuesday }` with a member the parent does not have is now a compile error instead of compiling silently.
- **Unicode identifiers** — Identifiers may contain Unicode letters and decimal digits, following the same rules as Go.

### Standard Library

- **std.regexp** — Backtracking NFA regexp engine with `.match`, `.find`, `.find_all`, `.replace`, `.split`, and `.compile`.
- **std.string.builder** — Mutable string builder with `.write`, `.str`, and `.reset`.
- **std.array** — `filter`, `map`, `reduce`, `slice`, `zip`, `flat`, `find`, `find_index`, `all`, `any`, `chunk`.
- **std.sort** — `asc`, `desc`, `by`.
- **std.hex** — `encode`, `decode`.
- **std.base64** — `encode`, `decode`, `url_encode`, `url_decode`.
- **std.time** — `parse_duration`, `iso_week`, `add_date`, `since`, `until`.
- **std.string** — `count`, `fields`, `pad_left`, `pad_right`, `equal_fold`, `contains_any`, `trim_left`, `trim_right`, `trim_prefix`, `trim_suffix`, `split_n`.

### Runtime & Embedding

- **Runtime error messages** — Type and range errors now explain what went wrong and how to fix it (e.g. `cannot mix Age and int; wrap the int with Age(...)`).
- **Host module failure modes** — Host module calls that return `unsupported`, `denied`, `bad_args`, or `failed` now raise distinct runtime errors (`HostNativeUnsupported`, `PermissionDenied`, `HostNativeBadArgs`, `HostNativeFailed`).
- **REPL type persistence** — `type`, `subtype`, `struct`, `interface`, and `variant` declarations now persist across REPL lines.
- **Instruction budget** — `max_ops` in `api.Config` enforces a hard limit on VM instructions per run.

### Fixes

- **Strict int/float comparison** — Ordering comparisons now follow the same strictness as arithmetic: `1.5 > 1` is a `TypeError`, matching `1.5 + 1`.
- **Nominal type strictness** — Named-type values no longer mix with bare base-type values in arithmetic, comparison, or compound assignment.
- **Expression recursion limit** — Deeply nested expressions now fail compilation with `ExpressionTooDeep` (limit 256) instead of risking a host stack overflow.
- **Module load failure** — A failed module is now marked `.failed` instead of staying in `.loading`, so subsequent imports report the original error instead of a misleading `ImportCycle`.
- **Host module exports** — Accessing a non-existent field on a host module now produces a compile-time error instead of surfacing at call time.
- **String pool exhaustion** — When the 128KB string pool overflows, the lexer reports `"string pool exhausted (max 128KB)"` instead of `"unterminated string"`.

---

For the full internal development log, see the root [`CHANGELOG.md`](https://github.com/gengoscript/gengo/blob/main/CHANGELOG.md).
