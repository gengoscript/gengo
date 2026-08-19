# Known Limitations

This page records current limitations rather than planned behaviour. For
evidence and proposed resolutions, see the contributor-facing
`../dev-docs/documentation-contradictions.md`.

## Language Semantics

| Area | Current behaviour | Practical consequence |
|---|---|---|
| `else if` chain depth | The compiler limits `else if` chains to 256 levels and returns `NestingTooDeep` beyond that. | Refactor very deep chains into a `switch`, a helper function, or a data-driven lookup. |
| Variant type field count | Variant types (all arms combined) are limited to 255 fields. Constructing or loading a variant with more fields is a runtime or GBC-reader error. | Decompose large variants or use nested structs. |
| Inferred generic constraints | Constraints are checked for explicit type arguments but skipped after inferred type arguments. | Write explicit type arguments when a constraint must be enforced. `identity[bool](true)` is rejected for `T numeric`; the inferred form currently succeeds. |
| Standalone `decimal` declarations | `var value decimal` is rejected. Named fixed-point types such as `type Money decimal 2` work. | Use a named decimal type; do not describe bare `decimal` as a supported declaration type. |
| Rune conversion | `rune(...)` is not a callable conversion. | Use a typed `rune` declaration from an integer code point, then `string(r)` where text is required. |
| Module initialization | Dependencies are compiled before an importing source module, but no cross-module observable top-level initialization order is specified. | Keep order-sensitive initialization behind exported functions called by the root script. |
| Map iteration | Entry order is unspecified. Mutating a map's membership during iteration has no language guarantee. | Do not use iteration order for program logic; iterate a copied key list when mutation is needed. |
| Binary strings | `std.bytes` can construct arbitrary bytes, while normal string indexing and iteration require valid UTF-8. | Keep binary data in `std.bytes` operations unless it is known to be valid UTF-8. |

The relevant specifications include
`tests/spec/322_generic_constraint_inference_gap.gengo`,
`tests/spec/252_forward_ref_global.gengo`, and the import-cycle failure suite.

## Host ABI and SDKs

| Area | Current behaviour | Practical consequence |
|---|---|---|
| Decimal wire values | ABI v2 sends an integer carrier with a decimal flag, but does not encode named-decimal scale or type. | A host cannot reconstruct the exact declared decimal scale. Do not use ABI v2 for lossless multi-scale decimal interchange. |
| TypeScript decimals and integers | The SDK represents values as JavaScript `number`; it has no lossless decimal wire form. | Large integers and fixed-point decimals can lose precision. Use string or host-defined representations where exactness matters. |
| ABI stability | The current Host ABI is v2, but the project has no stable cross-version compatibility policy. | Pin a matching engine release and require an exact ABI-version match. |
| Native pointer ownership | Native host buffers follow the lifetime rules in `host-abi.md`; WASM uses linear-memory offsets instead. | Do not share a native pointer rule with a browser/WASM binding. Copy values when retention is required. |

## Tooling

| Area | Current behaviour | Practical consequence |
|---|---|---|
| `--emit-gbc` and generic functions | `--emit-gbc` rejects any script that declares a generic function (`func f[T](...)`), even if it is never called. Generic struct and variant types alone round-trip correctly. | Avoid generic function declarations in scripts intended for GBC output; inline the monomorphic forms instead. |
| `--emit-gbc` and tasks | `--emit-gbc` rejects scripts that declare a `task func` type. There is no `TASK_T` case in the writer's constant-kind handling. | Do not use task/actor declarations in scripts intended for GBC output. |
| `--emit-gbc` and in-body predicates | `--emit-gbc` rejects a predicate declared inside a function body when that predicate closes over the function's own locals. Module-scope predicates work. | Move the predicate to module or type scope. |
| `--emit-gbc` source hash | The artifact records a hash of the source it was compiled from, but the CLI does not yet verify it before running the artifact. | Regenerate the `.gbc` whenever its `.gengo` source changes; do not rely on automatic invalidation. |
| `--emit-gbc` on WASI | `--emit-gbc` is not supported in the WASI build. | Use the native CLI for GBC emission; run the artifact from WASI if needed. |

## Security and Operations

| Area | Current behaviour | Practical consequence |
|---|---|---|
| Operation budgets | The VM budget counts VM instructions, not work performed by host callbacks. | HTTP, filesystem, and custom host callbacks need their own time, size, and allocation limits. |
| Filesystem mounts | Mount-path validation rejects absolute paths and traversal, but cannot itself settle symlink, race, device-file, or quota policy. | Use a virtual or dedicated read-only driver and enforce host-side quotas. |
| Runtime instances | Separate engines have separate VM state but share a process and its native code. | Multiple engines are not an OS sandbox and do not contain memory-unsafe host code. |

## Not Limitations

These behaviours were previously described ambiguously but are now locked down
by tests:

- Variant `switch` exhaustiveness is required both at top level and inside a
  function.
- `cap:env` is a separate capability module, not a `std` namespace.
- Source-import cycles fail at compile time with `ImportCycle`.
- `cap:net` dial policy defaults to deny, not allow, with no rules configured
  — same default as listen (#221).

When a limitation is resolved, update its conformance test, this page, the
feature matrix, and the changelog in the same change.
