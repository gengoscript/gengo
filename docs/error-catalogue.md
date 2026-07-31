# Error Catalogue

Error names are current implementation names, not a stable string-based API;
hosts should use the structured error interfaces described in `engine-api.md`
and `host-abi.md`.

## Failure Classes

| Class | When it occurs | Can script code recover? |
|---|---|---|
| Compile error | Parsing, import resolution, declaration checks, or static type checks before execution. | No. Fix the source or host configuration. |
| Runtime panic | An executing operation fails, a `trap` result is non-null, or a VM resource budget is exhausted. | Usually yes, from a deferred function using `std.core.recover()`. |
| `error` value | Script or capability code returns `std.core.error(...)` or another error value. | It is ordinary data; check and propagate it explicitly. |
| Host/engine result | A C, Zig, WASM, or SDK call reports failure. | The host reads structured diagnostics and chooses its own recovery. |

An unrecovered runtime panic terminates the current script run. A successful
`recover()` stops that panic unwind, but does not resume the expression that
failed; control continues according to the recovered function's return path.

## Common Compile Errors

| Error | Meaning | Typical correction |
|---|---|---|
| `NestingTooDeep` | An `else if` chain exceeds 256 levels. | Refactor deeply nested conditionals into a `switch`, a helper function, or a data-driven lookup. |
| `InvalidChar`, `BadEscape`, `UnterminatedString`, `BadNumber` | Source text contains an invalid character, literal escape, unfinished string, or malformed number. | Correct the literal or source encoding. |
| `UnexpectedToken`, `ExpectedExpression`, `ExpectedTypeName` | The source does not match the expected syntax. | Check the diagnostic line/column and surrounding delimiter or keyword. |
| `UndefinedVariable`, `NotDefined` | A referenced binding is not visible at that point. | Declare it first, import the correct module, or correct its spelling. |
| `UnknownType`, `UnknownStructType`, `UnknownTypeName` | A type name cannot be resolved. | Use a declared/imported type and the required module qualifier. |
| `DuplicateLocal`, `DuplicateGlobal`, `DuplicateExport`, `DuplicateTypeName` | A scope or module declares the same name twice. | Rename or remove one declaration. |
| `AssignToConst` | Code assigns to a `const` or named function binding. | Assign through a mutable variable instead. |
| `ImportNotFound`, `ImportOutsideRoot`, `ImportCycle`, `UnsupportedImportModule` | A source import cannot be resolved, is outside permitted roots, forms a cycle, or uses an unsupported namespace. | Correct the path, add a host-approved module root, remove the cycle, or use `cap:`/`host:` as appropriate. |
| `CapabilityNotEnabled` | The script imports a capability not enabled by the host. | Enable only the intended capability, or remove the import. |
| `ConstraintViolation`, `WrongTypeArgCount` | Explicit generic arguments do not meet a constraint or have the wrong count. | Correct the explicit arguments. See `known-limitations.md` for inferred constraint checking. |
| `NonExhaustiveSwitch` | A variant switch lacks an unguarded arm or `default`. | Cover every variant arm or add `default`. |

## Common Runtime Panics

| Error | Meaning | Avoidance or handling |
|---|---|---|
| `TypeError`, `TypeMismatch`, `ArityMismatch` | A dynamic value or call does not satisfy the required type or argument count. | Validate dynamic input; use typed declarations and direct function calls where possible. |
| `NotAFunction`, `UnknownMethod`, `UnknownField` | Code calls a non-callable value or accesses a missing member. | Check the receiver/value shape before dynamic access. |
| `IndexOutOfBounds`, `RangeError` | An array/string index, slice, or byte-decoding range is invalid; also raised by stdlib functions when an output would exceed a size cap. | Validate bounds and input length. |
| `DivisionByZero` | Integer division or remainder has a zero divisor. | Check the divisor before the operation. |
| `PredicateFailed` | A named predicate type rejects a value. | Validate input before constructing the constrained value. |
| `AssertionFailed` | `assert` received `false`. | Use it for test/invariant failures; recover only when the caller has a meaningful policy. |
| `TrapFired` | A `trap` binding received a non-null value. | Handle the returned error/value before binding it to `trap`, or recover in a deferred function. |
| `NoSpaceLeft` | A formatting or time-format operation ran out of its output buffer. For example, `std.Time.format` raises this when the expanded format string exceeds 512 bytes. | Shorten the format string or switch to a different formatting path. |
| `HostValueTooDeep` | A `ValueWire` value being serialized to or deserialized from the host boundary exceeds 64 nesting levels. | Flatten deeply nested return values before returning them from a script or from a host callback. |
| `HostValueTooLarge` | A `ValueWire` value's `len` field (string, array, or map) exceeds the u32 maximum. | Enforce size limits on collections before passing them across the host boundary. |
| `InstructionBudgetExceeded` | The configured VM operation budget was used. | Set an appropriate limit; simplify or split work. Host callback time needs separate host limits. |
| `OutOfMemory`, `StackOverflow`, `CallStackOverflow`, `DeferStackOverflow` | A configured heap, VM stack, call-frame, or defer limit was reached. | Increase a deliberate host limit or bound script data/recursion. |
| `FfiLoadFailed` | `ffi.load()` could not open the requested shared library. | Check the path and that the library is loadable in the host process. |
| `FfiSymbolNotFound` | `lib.declare()` could not find the requested symbol in the loaded library. | Check the symbol name and that it is exported with default visibility. |

Capability operations can instead return an ordinary error value, particularly
for expected I/O, HTTP, and socket failures. Consult `capabilities.md` for
each operation's return convention; do not treat every non-success as a
panic.

## Reading Diagnostics

The CLI prints compile diagnostics with a source location and runtime panics
with the failure location; a runtime stack trace may follow. The C/native API,
WASM API, and TypeScript SDK expose structured diagnostics instead of asking a
host to parse CLI text. A host should retain diagnostic text only for the
lifetime stated by its API reference, then copy it if it must be preserved.

See also: `language.md`, `cli.md`, `capabilities.md`, `engine-api.md`, and
`known-limitations.md`.
