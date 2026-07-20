# Contradictions and ambiguities

Audience: maintainers and security reviewers. These are recorded rather than
silently normalized in public prose.

| Topic | Evidence | Classification | Public position and recommended resolution |
|---|---|---|---|
| Decimal wire scale | Named decimal values retain scale internally (`decimalRawAndScale`), while `ValueWire` has only a decimal flag and raw `i64`; the C header says “×1000”. | Implementation/API defect | The ABI loses named-type scale. Document raw carrier semantics and add a scale field or a dedicated decimal wire tag in ABI v3. |
| TypeScript decimal support | SDK `GVal` represents only JavaScript `number`; its wire encoder has no decimal flag. | SDK limitation | Decimal values are not lossless in TypeScript. Add a BigInt/raw/scale representation before claiming decimal support. |
| Standalone `decimal` declaration | `var d decimal` fails with `UnknownType`, while named decimal declarations such as `type Money decimal 2` pass decimal conformance tests. | Documentation/implementation ambiguity | Public language documentation describes decimals only as named fixed-point types. Decide whether a standalone `decimal` variable type is supported, then add a conformance test and align the lexer/compiler and reference. |
| Callable rune conversion | The compiler reserves `rune` as a type name but `rune(...)` resolves as an undefined variable; typed `var r rune = 229` works. | Documentation/implementation ambiguity | Do not document `rune(...)` as a conversion. Decide whether to expose it as a constructor/cast, then add conformance coverage. |
| Generic constraint inference | Explicit generic arguments are passed through `checkTypeArgConstraints`; inferred calls do not invoke it. `tests/spec/322_generic_constraint_inference_gap.gengo` accepts inferred `bool` for `T: numeric`. | Implementation defect / known limitation | Prominently document the gap. Enforce constraints after inference and turn the regression test into a failure expectation when resolved. |
| Variant-switch scope | The former language guide said only function-local variant switches were exhaustive. The compiler applies its exhaustiveness check at top level as well; `tests/spec/fail/323_variant_top_level_non_exhaustive.gengo` locks this down. | Resolved documentation defect | The language reference now states that every identifiable variant switch requires unguarded coverage or `default`, regardless of scope. |
| Opcode page | The former public opcode page describes VM fusion and internal numeric slots. | Documentation architecture defect | Moved to `dev-docs/opcodes.md`; it is contributor material, not public language semantics. |
| Capability inventory | `cap:env` is compiled and documented in changelog/stdlib, but the old security and Zig embedding lists omitted it. | Documentation defect | The authoritative matrix includes `env`; availability still depends on build and host configuration. |

No language semantics were changed as part of this documentation work.
