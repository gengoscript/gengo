# Gengoscript Changelog

## Unreleased

### Language (unreleased)

- **`??` null-coalescing operator** — `a ?? b` returns `a` if it is not `null`, otherwise evaluates and returns `b`. Short-circuits (right-hand side is skipped when the left-hand side is non-null). Right-associative: `a ?? b ?? c` is `a ?? (b ?? c)`.
- **Generic struct and variant types** — `type Stack[T] struct { items []T }` and `type Result[T, E] variant { ok(value T), err(e E) }`. Instantiate by supplying concrete type arguments: `Stack[int]{ items: [] }`, `Result[int, string].ok{ value: 42 }`. Type parameters are substituted at compile time; each instantiation is a distinct concrete type. Nested generic fields (e.g. `Stack[T]` inside `Wrapper[T]`) resolve correctly when the outer type is instantiated.
- **Generic functions** — `func map_array[T, U](xs []T, f func(T) U) []U`. Type arguments may be omitted and are inferred from the call context: `map_array(nums, fn)`. Explicit type arguments are also accepted and their count is validated: `map_array[int, string](nums, fn)`. Type parameters are erased at runtime (treated as `any`).
- **Generic constraints** — Type parameters may carry built-in constraints, written as a second identifier after the type parameter name: `func sort[T ordered](xs []T)`. Constraints are enforced at explicit call sites. Three built-in constraints are supported: `numeric` (int, float, decimal, rune, and named subtypes), `ordered` (numeric + string and named string subtypes), and `comparable` (any type).
- **Generic type aliases** — `type IntStack Stack[int]` declares a named alias for a concrete generic instantiation. The alias is fully transparent: it may be used anywhere the underlying type may be used, including struct literals, function parameter types, and `.type` comparisons.
- **Named error types** — `type NotFound error` declares a named error type. Named errors are ordinary `error` values and can be distinguished by `.type`: `e.type == NotFound`, `switch e.type { case NotFound { ... } }`.
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
- **`clamp` — a third named-type range mode** — `type Percent int clamp 0..100` saturates an out-of-bounds value to the nearest bound instead of raising a range error (`range`) or wrapping (`cycle`). Works on `int`/`float`/`decimal`/`rune` bases, is inherited by subtypes, and composes with `predicate` (clamping runs first; the predicate then checks the clamped result). `default` is still validated strictly against the range regardless of mode.
- **Limited operator overloading via reserved dunder methods** — a struct (or non-conflicting-base named) type may declare `__add__`/`__sub__`/`__mul__`/`__div__`/`__rem__`/`__neg__`/`__eq__`/`__compare__` as ordinary methods; `a + b` desugars to `a.__add__(b)` when the compiler can resolve `a`'s static type at compile time, and falls back to a runtime lookup inside type-erased generic function bodies. `__compare__` backs all four ordering operators at once (Kotlin's `compareTo` trick); `!=` is derived from `__eq__`. No asymmetric operand form — the parameter type must be exactly the receiver's own type. A named type may only declare a dunder for an operator its base doesn't already implement (declaring `__add__` on an `int`-based type is a compile error). A type declaring `__compare__`/`__eq__` also satisfies the `ordered`/`comparable` generic constraints.

### Standard Library (unreleased)

- **`cap:env`** — New capability module for process environment access. `env.get(name)` returns `string|null`; `env.list()` returns `[string]string`. Requires the host to enable the `env` capability; a script importing `cap:env` without host permission fails at compile time.
- **`std.Arg`** — Built-in variant covering all primitive scalar types (`Int`, `Float`, `Decimal`, `Rune`, `Bool`, `Str`, `Err`). Use it to write type-safe heterogeneous variadic functions without exposing `any`.

### Tooling (unreleased)

- **`gengo --test --profile`** — reports each `test` block's instruction count and peak heap bytes/stack depth/live object count, plus a final peak-across-all-blocks summary line, so integrators can size `engine_init_with_config`'s resource ceilings from measured workload data instead of guessing. Does not affect pass/fail behavior or the exit code; does cost real speed (forces per-instruction accounting on for the run), so it's a diagnostic flag, not something to leave on by default.
- **`gengo --emit-gbc path` / running a `.gbc` directly** — an early GBC (Gengo Bytecode Cache) implementation: `--emit-gbc` compiles a script and writes a `.gbc` artifact instead of running it; a `.gbc` file passed as the script argument (recognized by magic bytes) loads and runs directly, skipping parsing and compilation. Covers plain and generic functions (real parameter/return types, so interface conformance checks keep working on a loaded function; a generic function's type parameters erase to `any` on the wire, matching their own runtime semantics — constraint checking is unaffected, since it runs at each call site's own compile time against the caller's concrete type arguments, not by inspecting a loaded callee's stored types), `std`/native calls, and struct, named-type, `variant`, `interface`, `enum`, and task/actor declarations (including range/cycle/clamp-constrained named types, a named type's `default` value and `scale`, a module/type-scope `predicate`, variants with shared fields and record/single-payload/no-payload arms, enums with explicit representation values, auto-incremented ordinals, and enum subtypes, and spawning/sending/receiving through a task type loaded from a `.gbc` — running one now correctly drives the same task scheduler a normally-compiled program uses, not a one-shot run with no scheduler at all); a predicate declared inside a function body and closures with real captures stored as constants aren't supported yet — `--emit-gbc` reports these clearly rather than producing a broken artifact. See `dev-docs/design/gbc-spec.md` and GitHub issue #5 for the full format and remaining scope; the CLI does not yet check a `.gbc`'s recorded source hash against the current source before running it, so regenerate one by hand when its source changes.

### Fixes (unreleased)

- **Named-return of a boxed named type** — a function with a named return of a named type over a non-scalar base (e.g. `type Tag string`, used as `func f() (result Tag)`) panicked with `NotAFunction` when returning a value explicitly (`return Tag(s)`). Named returns of scalar/enum-based named types (`type Meters int`) were unaffected.
- Struct and enum variable declarations following a `std` import no longer trigger a spurious "unknown field in std" compile error.
- Arity mismatch errors now show `expected 1-2 argument(s)` when a function has defaults, and no longer include a stray leading comma in the function signature.
- Unknown `std.*` namespace fields now suggest the closest matching name in the error message.
- **Named-type range and predicate validation at call boundaries** — a dynamically-typed value (from `std.json.parse`, a host embedding call, or any other erased/`any` source) arriving at a function parameter or return value declared as a named range or predicate type is now actually validated against that type's constraint. Previously the validation error was silently discarded and the raw, unchecked value was passed through — `Port(99999)` panicked correctly when constructed directly, but a script or host could smuggle `99999` past a `Port int range 1..65535` parameter without it ever panicking.
- **`allow_io` defaults to `false`** — scripts can no longer write to `std.io` unless the host explicitly enables it. Hosts that relied on the previous default-allow behaviour must set `allow_io = true` in their config.
- **Wire depth limit** — `ValueWire` serialization in both directions is now bounded to 64 nesting levels. Exceeding the limit returns `HostValueTooDeep` instead of overflowing the host call stack. An oversized `len` field now returns `HostValueTooLarge`.
- **`else if` chain depth limit** — the compiler now rejects `else if` chains exceeding 256 levels with `NestingTooDeep` instead of risking a host stack overflow.
- **Integer default parameters parse exactly** — integer default values in function parameters are now parsed as `i64` without an intermediate `f64` round-trip. Integers larger than 2^53 in default params previously lost precision silently.
- **`string.split_n` empty separator** — with an empty separator, `split_n` now splits at UTF-8 codepoint boundaries, consistent with `string.split(s, "")`. Code relying on byte-level splitting with an empty separator must switch to `std.bytes` operations.
- **`string.repeat` / `bytes.repeat` size cap** — both functions now return `RangeError` if the result would exceed 64 MB.
- **`io.printf` / `fmt.format` / `fmt.stringify` size cap** — all three now return `RangeError` if the formatted output exceeds 64 MB.
- **`regexp` functions: input size cap** — all five regexp functions now return `RangeError` for input strings larger than 1 MB. Patterns with more than 200 levels of group nesting treat the input as non-matching.
- **`time.format` output cap** — `.format(fmt)` now returns `NoSpaceLeft` when the expanded format string exceeds 512 bytes.
- **`time.add_date` overflow guard** — `.add_date(years, months, days)` now returns `RangeError` when any component delta causes an i32 overflow.
- **`std.core.deep_equal` works for large maps** — previously panicked with `OutOfMemory` for maps with more than 128 entries. Now works for any size.
- **Import sandbox for package-style imports** — the path-traversal check now runs before any filesystem probe for all import kinds, including bare (package-style) imports.
- **GBC named-return count guard** — `.gbc` files with `named_return_count > 64` now return `error.MalformedSection` from the reader instead of silently writing out of bounds.
- **Variant type field count enforced** — constructing or loading a variant type with more than 255 combined fields is now a runtime or reader error rather than silent memory corruption.

---

## v0.5.0 — 2026-06-15

### Language (v0.5.0)

- **Boolean-only conditions** — `if`, `not`, `and`, `or`, and template `{{if}}` now require actual `bool` values. Non-boolean values (non-zero integers, non-null strings, etc.) that were previously treated as truthy/falsy now produce a runtime `TypeError`. Use `std.conv.to_bool` for explicit conversion.
- **Type names cannot be shadowed** — No binding form may use a type name: variables, functions, parameters, loop variables, and named returns all reject primitive type names and every declared type.
- **Subtypes of any scalar named type** — `subtype Child Parent` now accepts any scalar named parent (`bool`, `string`, `decimal` join `int`/`float`/`rune`). `range`/`cycle` constraints still require a numeric parent.
- **Named string concatenation** — `+` on two values of the same named string type preserves the named type.
- **Predicate custom messages** — A predicate may declare a custom failure message: `predicate func(x) { ... } message "must be positive"`.
- **Predicate inheritance** — Subtypes inherit the parent’s predicate. A subtype with its own predicate must satisfy both.
- **Bare type parameters in interface specs** — Interface method parameters can be written as bare types, Go-style: `add(float) float`.
- **Enum subtype validation** — `subtype Bogus Days { tuesday }` with a member the parent does not have is now a compile error instead of compiling silently.
- **Unicode identifiers** — Identifiers may contain Unicode letters and decimal digits, following the same rules as Go.

### Standard Library (v0.5.0)

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

### Fixes (v0.5.0)

- **Strict int/float comparison** — Ordering comparisons now follow the same strictness as arithmetic: `1.5 > 1` is a `TypeError`, matching `1.5 + 1`.
- **Nominal type strictness** — Named-type values no longer mix with bare base-type values in arithmetic, comparison, or compound assignment.
- **Expression recursion limit** — Deeply nested expressions now fail compilation with `ExpressionTooDeep` (limit 256) instead of risking a host stack overflow.
- **Module load failure** — A failed module is now marked `.failed` instead of staying in `.loading`, so subsequent imports report the original error instead of a misleading `ImportCycle`.
- **Host module exports** — Accessing a non-existent field on a host module now produces a compile-time error instead of surfacing at call time.
- **String pool exhaustion** — When the 128KB string pool overflows, the lexer reports `"string pool exhausted (max 128KB)"` instead of `"unterminated string"`.

---

For the full internal development log, see the root [`CHANGELOG.md`](https://github.com/gengoscript/gengo/blob/main/CHANGELOG.md).
