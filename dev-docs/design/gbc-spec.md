# Gengoscript Bytecode Cache — File Format Specification

**Status:** Draft\
**Version:** 0.14\
**Scope:** GBC artifact only (see §2 for artifact class definitions)

**Revision history**
- 0.14 — `type_param` `FieldTypeAlt` entries (§9.2) now erase to `FT_ANY`
  on the wire instead of being rejected with `error.UnsupportedFieldType`
  — matching the runtime's own type-erasure semantics (a generic
  function's declared parameter is already treated as `any` at every use
  once compiled; representing that on the wire isn't a new, weaker
  behavior). Unblocks `--emit-gbc` for any script declaring a generic
  function, previously rejected outright even when never called (every
  function declaration emits a constant regardless of calls). Constraint
  enforcement is unaffected — `checkTypeArgConstraints` runs at each call
  site's own compile time against the caller's concrete type arguments,
  never by inspecting a callee's stored `param_types`. The erased
  parameter's name (e.g. `"T"`) is not preserved: nothing at runtime
  reads it, and the one compile-time consumer (constraint checking)
  never touches it either. Found and fixed while extending GBC support
  past enums/tasks (#5) toward the last few remaining unsupported
  constant kinds.
- 0.13 — Add a `TASK` `TypeEntry` kind (§8.6, `0x06` — no gap had been
  reserved for it, since task/actor shipped after the initial GBC spec
  pass) registering the task's behavior `FuncObj` through the same
  `SEC_FUNCTIONS` indirection a `NAMED` type's predicate uses, but never
  closure-wrapped: task bodies cannot capture outer locals at all
  (task-actor-design.md §3.3), so there are never any upvalues to carry.
  Found and fixed a real, separate runtime bug while adding this:
  `Runtime.runFromGbc` had no task scheduler loop at all — it predates
  task/actor integration and called the VM once, directly. A task
  spawned from a GBC-loaded program would enqueue but never run; the
  spawning script's own `receive()` would block forever, and the whole
  run would silently return success having executed none of the spawned
  task's body. This was a gap in the loader's *execution* path, not the
  wire format — nothing here changed as a result, but it's recorded
  because it was found and fixed alongside this artifact-class's own
  work and blocked verifying it end-to-end.
- 0.12 — Implement the `ENUM` `TypeEntry` kind (§8.6, `0x03`, reserved
  since the format's early drafts). Also fixed a real gap this section
  had never accounted for: explicit enum representation values
  (`type Status enum { pending = 10, active = 20, done = 30 }`) — the
  spec previously listed only `members`/`parent_name`, so a loader had
  no choice but to fall back to ordinal position, silently producing the
  wrong `.int` for any enum whose values diverge from ordinals. Added
  `has_member_ints`/`member_ints` following the same present-flag
  convention `NAMED`'s own optional fields already use. Verified by
  round-tripping exactly that divergent-values case before trusting the
  field list, not assumed correct because it looked complete.
- 0.11 — §14 is now implemented in the reference engine, not just spec'd:
  `--emit-gbc-module` (writer side, `Runtime.compileModuleOnly` /
  `module_compile.Session.compileModuleRoot`) and `import("./x.gbc")`
  (reader side, `gbc_reader.readIntoSession` spliced in via a new
  `module_compile.Session.linkGbcModule`, dispatched from
  `compileModuleFromPath` whenever a resolved import specifier ends in
  `.gbc`) both work end-to-end, verified by compiling a module artifact,
  importing it from a separate script, and running the combined program —
  both interpreted directly and re-compiled through `--emit-gbc` into one
  flattened, self-contained artifact. One rough edge found during
  implementation, not yet closed: a `ModuleRecord`'s dedup key (used by
  import-cycle detection and by re-resolving an already-loaded import to
  its bound global) is still the importer's local specifier, while the
  compiler's later export/type lookups key off the linked artifact's own
  `module_id` instead (§14.3) — tracked as a second, independent key
  (`link_module_id`) on the same record rather than unifying them. This
  works correctly for the common case (one import per specifier) but means
  importing the exact same `.gbc` via two different local specifiers in
  one compile re-splices it instead of deduplicating, wasting pool space
  rather than misbehaving. Not exercised by any shipped test; flagged here
  so it isn't rediscovered as a surprise.
- 0.10 — Reverse §16 (Non-Goals)'s former "Linking. GBC files are not
  linkable in v1" bullet and add real cross-artifact linking
  as a new §14: an `ENTRY_MODULE` artifact can now be imported directly by
  another compile, without recompiling its source, when the import
  specifier names the `.gbc` artifact explicitly (`import("./mathlib.gbc")`
  — no implicit same-stem-sibling fallback; see §14 for why). This is a
  format-breaking change (`format_major` 1 → 2, §12): `SEC_EXPORTS`
  (§8.5) gains a leading `module_id` field and each `ExportEntry` gains
  `type_kind`/`const_value`, needed so an importer can reconstruct a full
  module symbol table from the artifact alone, without ever constructing a
  live `Compiler` for the dependency. `DEPENDENCY_TABLE` (§8.7) gains
  `kind = 3 (LINKED_ARTIFACT)`, for which `artifact_body_hash` becomes
  mandatory and must match exactly (no recompile-if-stale fallback the way
  `FILE` dependencies get — a corrupted or substituted linked artifact must
  fail loudly, not silently misload). Scope for this revision is
  deliberately narrow: linking is single-level only — a linkable module
  artifact must itself have zero `LINKED_ARTIFACT` dependencies (enforced
  at write time), so a loader never needs to recursively load a `.gbc`
  found while loading another `.gbc`. A module artifact's own file imports
  are still compiled from source into it as today; only the one hop from
  importer to a precompiled dependency is new.
- 0.9 — Implement `FUNC_T` (§9.2, `0x0E`): spec'd since early drafts but the reference writer rejected it with `error.UnsupportedFieldType`, which silently made `--emit-gbc` fail for *every* program, not just ones using function-typed values directly — the engine's own embedded-Gengoscript standard-library helpers (compiled into every chunk regardless of what the user's script imports) include one with a function-typed parameter. Two more implementation-only fixes found alongside it, neither a core format change: (1) a `FunctionEntry.name_constant_idx` naming an as-yet-unwritten `CONST_STRING` is a legitimate forward reference (the writer only guaranteed a match already existed among constants written *before* the function; a function's own bare name — e.g. `count` — is frequently not otherwise present as an independent string constant), so name resolution on load must defer until the whole constant pool exists, not resolve inline per-constant; (2) that deferral must key back to names by constant-pool index (GC-rooted, kept correct across compaction) rather than by directly caching the constructed object pointer, which a later allocation in the same load pass can relocate out from under an uncached copy. Also documents a vendor-range (§7.2, `0x8000`–`0xFFFF`) `SEC_STD_SCRIPT_INFO` section (implementation-specific, not part of this spec) that the reference engine writes so its own std-script bootstrapping metadata survives a round-trip; any loader may ignore it.
- 0.8 — Add an `INTERFACE` `TypeEntry` kind (§8.6, `0x04`, the slot already reserved for it) with a method list reusing `FunctionEntry`'s own param/return/variadic-type shape. Complete `FunctionEntry`'s param/return/variadic `TypeSpec` encoding (§8.3) — always specified, but the writer had deferred it (writing empty placeholders and forcing `has_typed_params`/`has_typed_returns` false on load) until a real consumer needed it; `interfaceMethodMatches` (`vm_types.zig`) compares an interface method's declared param/return types against the *actual* implementing function's types on every conformance check, so a placeholder here would make a real, correctly-typed interface silently fail to match its implementation once loaded from a `.gbc`. Extend the `NAMED` `TypeEntry` (§8.6) with fields it always needed but never had wire slots for: `is_anonymous` (read at runtime for anonymous array/map-typed-local equality), `scale` (decimal fixed-point precision), a predicate reference (resolved through the same `SEC_FUNCTIONS` indirection as a plain function — a captureless predicate, the only kind compiled at module/type scope, needs no upvalue encoding), `predicate_msg`, and `has_default`/`default_val` (always a `float`/`string`/`bool` per the language's own `parseNamedDefault`). All four found via the same "research before implementing" process as prior entries (#5): reading the actual opcode/VM code that consumes each field, not assuming a shape.
- 0.7 — Add a `VARIANT` `TypeEntry` kind (§8.6, `0x03`) with arm records (name, shape — none/single-payload/record — and a record arm's field list) and a type-level shared-field list, extending `TYPE_REF` (§8.2) to cover variant types. Un-reserve the `INT` constant tag (`0x06`, §8.2): promote it from "reserved for a future format version" to actually used now, fixing a real ambiguity bug where a `.int` and a whole-valued `.float` (e.g. `1.0`) were indistinguishable on the wire (both went through `NUMBER` as `f64`, reconstructed by a "no fractional part → int" heuristic) — `.int` values now write through `INT` as a raw `i64`, `.float` always through `NUMBER`, no heuristic. Both found while extending GBC to support variant-type values in the constant pool (#5): the variant work's first round-trip test happened to be the first one to return a whole-valued float constant, surfacing the pre-existing `NUMBER`/`INT` ambiguity that every earlier struct/named-type/function test had accidentally avoided.
- 0.6 — Add `TYPE_REF` constant tag (§8.2) and a `DECIMAL_T` `FieldTypeAlt` tag (§9.2, `0x0F`). `TYPE_REF` mirrors `FUNC_REF`: the constant pool had no way to represent "this slot is a struct or named type," but `def_global` for a `type X struct {...}`/`type X int ...` declaration needs one, and a struct field referencing another type by name needs the referenced type's own constant slot to exist independently of the reference itself. `DECIMAL_T` fixes an omission: the `FieldTypeAlt` table never had a tag for `decimal` at all (every other scalar base — `int`/`float`/`rune_t`/`bool`/`string` — had one), so a struct field or named-collection element declared `decimal` had no way to round-trip. Both found while extending GBC to support struct and (predicate-free) named-type values in the constant pool (#5) — the original milestone deliberately scoped these out and rejected them with `error.UnsupportedConstant`.
- 0.5 — Add `FUNC_REF` constant tag (§8.2): the constant pool previously had no way to represent "this slot is a function," but `make_closure`'s bytecode operand is a constant-pool index that must resolve to one. Found while starting implementation (#5) — the FUNCTIONS section was specified as a self-contained side-table with no stated link back to CONSTANTS, and a real chunk's function objects are referenced by constant-pool index, not looked up by name/position separately. `FUNC_REF` holds a `u32` index into `SEC_FUNCTIONS`; the loader resolves it to a constructed `FuncObj` and installs that into the constant slot before running any code. Also fix an arithmetic error: §6.1's own field table sums to 184 bytes (7×`u16` + 3×`u32` + 6 reserved + `i64` + 4×`hash32` + 2×`u64` = 184), not the 192 stated in three places (the `header_size` field description, the "total defined header size" line, and Phase 1 check #4) — found the same way, by implementing a writer against the table and a reader that rejected its own output. Corrected all three to 184; no field was added or removed.
- 0.1 — Initial draft
- 0.2 — Rename `stdlib_hash` → `module_provider_hash`; add `resolved_id` and `artifact_body_hash` to dependency entries; add `bytecode_length` and `local_count` to function entries; add `Bool` and `Rune` constant tags; rewrite `FieldTypeAlt` as per-tag encodings; fix `options_hash` canonical encoding widths; remove mutual-exclusion rule for `CHECKED_ARITHMETIC`/`OPTIMISED` from format; clarify header-size compatibility (no smaller-than-required); reorder validation phases; note f64 bounds limitation; note script/module philosophy
- 0.4 — Fix "inclusive" wording on half-open range; add `bytes` primitive; wrap domain labels in `str()`; remove `hash32(SHA-256(...))` redundancy; rename `artifact_hash` → `artifact_body_hash` with body-only scope note; add Phase 4 general content-validity check; add §11.2 implementation-defined limits; define `ENTRY_SCRIPT` importability rule
- 0.3 — Fix body-offset bug (`8 + header_size`, not `header_size`); make `artifact_body_hash` advisory with full-validation requirement; clarify `SEC_DEPENDENCY_TABLE` records direct imports only; allow `SEC_EXPORTS` with `export_count = 0` for `ENTRY_MODULE`; make `variadic_type` conditional on `is_variadic` in `FunctionEntry` and `InterfaceMethod`; add `alt_count >= 1` constraint to `TypeSpec`; add `DEBUG_INFO` inverse rule; hash full `u32le(flags)` not `flags_low_byte` in `options_hash`; add future `INT (i64)` constant tag note; add domain separation and length prefixes to `source_graph_hash` and `module_provider_hash` hash inputs

---

## Table of Contents

1. [Purpose and Scope](#1-purpose-and-scope)
2. [Artifact Classes](#2-artifact-classes)
3. [Primitive Encoding](#3-primitive-encoding)
4. [File Structure Overview](#4-file-structure-overview)
5. [Magic Bytes](#5-magic-bytes)
6. [Header](#6-header)
   - 6.1 [Field Definitions](#61-field-definitions)
   - 6.2 [Flags Bitfield](#62-flags-bitfield)
   - 6.3 [Target Identifiers](#63-target-identifiers)
   - 6.4 [Backend Identifiers](#64-backend-identifiers)
   - 6.5 [Entry Kind](#65-entry-kind)
   - 6.6 [Hash Fields](#66-hash-fields)
7. [Body Structure](#7-body-structure)
   - 7.1 [Section Table](#71-section-table)
   - 7.2 [Section Identifiers](#72-section-identifiers)
   - 7.3 [Required vs Optional Sections](#73-required-vs-optional-sections)
8. [Section Formats](#8-section-formats)
   - 8.1 [BYTECODE](#81-bytecode)
   - 8.2 [CONSTANTS](#82-constants)
   - 8.3 [FUNCTIONS](#83-functions)
   - 8.4 [NATIVE\_IMPORTS](#84-native_imports)
   - 8.5 [EXPORTS](#85-exports)
   - 8.6 [TYPES](#86-types)
   - 8.7 [DEPENDENCY\_TABLE](#87-dependency_table)
   - 8.8 [DEBUG\_SPANS (optional)](#88-debug_spans-optional)
   - 8.9 [DEBUG\_NAMES (optional)](#89-debug_names-optional)
9. [Type Encoding](#9-type-encoding)
   - 9.1 [TypeSpec](#91-typespec)
   - 9.2 [FieldTypeAlt](#92-fieldtypealt)
10. [Native Function Resolution](#10-native-function-resolution)
11. [Validation Rules](#11-validation-rules)
    - 11.1 [Validation Phases](#111-validation-phases)
    - 11.2 [Implementation-Defined Limits](#112-implementation-defined-limits)
    - 11.3 [Error Handling](#113-error-handling)
12. [Version Compatibility Policy](#12-version-compatibility-policy)
13. [Dependency and Module Graph Hashing](#13-dependency-and-module-graph-hashing)
14. [Cross-Artifact Linking (v2)](#14-cross-artifact-linking-v2)
15. [Future: GSI Artifact Class](#15-future-gsi-artifact-class)
16. [Non-Goals for GBC v1](#16-non-goals-for-gbc-v1)
17. [Rationale Notes](#17-rationale-notes)

---

## 1. Purpose and Scope

A GBC file is a **compiled module artifact**. It answers one question:

> Can parsing, type-checking, and code generation be skipped for this source input under this runtime?

A GBC file contains the bytecode, constant pool, function table, type metadata, import/export declarations, and optional debug information produced by the Gengoscript compiler. It does not contain live heap state, open resources, or VM execution state.

Loading a valid GBC file into a fresh VM must be equivalent to compiling the original source under the same conditions. No observable behaviour may differ.

### What a GBC file is not

A GBC file is not a **snapshot** of a running VM. Serialising the live object heap, global variable values, open file handles, allocator state, or GC metadata is explicitly out of scope for this format. That is a separate artifact class (§15).

### Script vs module philosophy

The intent is that every Gengoscript source file is module-shaped. An `ENTRY_SCRIPT` artifact is a module that also carries executable top-level code — it is not a fundamentally different kind of entity. The distinction is operational (how the host runs it) rather than structural (what the artifact contains). Future versions of this format should converge `ENTRY_SCRIPT` and `ENTRY_MODULE`: a script is a module with an entrypoint, and a module with public declarations is importable regardless of whether it also has a top-level body.

---

## 2. Artifact Classes

Two artifact classes are defined. Only GBC is specified here.

| Class | Extension | Contents | Status |
|-------|-----------|----------|--------|
| **GBC** | `.gbc` | Bytecode, constants, metadata | This document |
| **GSI** | `.gsi` | GBC content + serialised heap snapshot | Future, not specified |

The class distinction must be enforced at the file level, not inferred from context. A loader that only understands GBC must reject a GSI file with a clear error, not attempt partial loading.

**Design rule:** Do not let snapshot ambitions contaminate the GBC format. If a field or section only makes sense for heap snapshots, it belongs in GSI, not GBC.

---

## 3. Primitive Encoding

All multi-byte integers are **little-endian**. No big-endian variant of this format is defined. A file produced on a big-endian host must byte-swap all multi-byte fields before writing.

| Type | Size | Description |
|------|------|-------------|
| `u8` | 1 byte | Unsigned 8-bit integer |
| `u16` | 2 bytes | Unsigned 16-bit integer, little-endian |
| `u32` | 4 bytes | Unsigned 32-bit integer, little-endian |
| `u64` | 8 bytes | Unsigned 64-bit integer, little-endian |
| `i64` | 8 bytes | Signed 64-bit integer, little-endian, two's complement |
| `f64` | 8 bytes | IEEE 754 double-precision, little-endian |
| `bool8` | 1 byte | `0x00` = false, `0x01` = true; any other value is invalid |
| `str` | variable | `u32` byte-length followed by UTF-8 bytes; no null terminator. UTF-8 validity must be checked on load. |
| `bytes` | variable | `u32` byte-length followed by raw bytes; no encoding requirement. Use for binary blobs (e.g. stdlib binary) where UTF-8 is not guaranteed. |
| `hash32` | 32 bytes | SHA-256 digest |

Arrays are encoded as `u32` element count followed by elements. Optional fields are encoded as `bool8` present-flag followed by value if flag is `0x01`.

**Do not write raw host structs.** Field offsets, padding, and sizes are format-defined. A change to any Zig struct used internally is not a format change unless this document also changes.

---

## 4. File Structure Overview

```
┌─────────────────────────────┐
│  Magic (8 bytes)            │
│  Header (header_size bytes) │
├─────────────────────────────┤
│  Body                       │
│  ┌────────────────────────┐ │
│  │ Section table          │ │
│  ├────────────────────────┤ │
│  │ BYTECODE section       │ │
│  │ CONSTANTS section      │ │
│  │ FUNCTIONS section      │ │
│  │ NATIVE_IMPORTS section │ │
│  │ EXPORTS section        │ │
│  │ TYPES section          │ │
│  │ DEPENDENCY_TABLE       │ │
│  │ DEBUG_SPANS (opt.)     │ │
│  │ DEBUG_NAMES (opt.)     │ │
│  └────────────────────────┘ │
└─────────────────────────────┘
```

The magic bytes appear at file offset 0 and are not part of the header. The header begins at offset 8. The body begins at file offset `8 + header_size`. The body checksum covers the half-open byte range `[8 + header_size, 8 + header_size + body_length)` — that is, exactly `body_length` bytes starting at the body start.

---

## 5. Magic Bytes

```
\x89 G N G \r \n \x1a \n
 89  47 4E 47  0D 0A  1A  0A
```

8 bytes, at file offset 0.

The high bit of the first byte (`\x89`) flags this as a binary file and causes rejection by any tool treating it as ASCII text. The `\r\n` sequence (`0D 0A`) followed by `\n` (`0A`) detects line-ending mangling: any text-mode copy operation that converts `\r\n` to `\n` or vice versa will corrupt this pattern. The `\x1a` is the MS-DOS end-of-file marker and prevents some tools from reading the file as text. This design is borrowed from PNG.

A loader must reject any file whose first 8 bytes do not exactly match this sequence.

---

## 6. Header

The header begins at file offset 8. Its total size in bytes — including the `header_size` field itself and the magic is not included — is given by `header_size`.

**Forward compatibility:** If a loader reads a header whose `header_size` is larger than the layout this document defines, it must skip the unknown trailing bytes (treating them as reserved). It must not reject the file solely because of a larger header, provided `header_version` is within the supported range.

**No smaller-than-required headers:** `header_size` must be at least the minimum size required by `header_version`. Smaller-than-required headers are invalid and must be rejected. Defaulting missing hash fields to zero is not permitted — a missing `vm_fingerprint`, `source_graph_hash`, or `options_hash` would produce false cache hits.

### 6.1 Field Definitions

| File offset | Header offset | Size | Type | Field | Description |
|-------------|---------------|------|------|-------|-------------|
| 8 | 0 | 2 | `u16` | `header_size` | Total header size in bytes. Current minimum for `header_version` 1: 184. |
| 10 | 2 | 2 | `u16` | `header_version` | Version of this header layout. Current value: 1. |
| 12 | 4 | 2 | `u16` | `format_major` | Bytecode format major version. |
| 14 | 6 | 2 | `u16` | `format_minor` | Bytecode format minor version. |
| 16 | 8 | 2 | `u16` | `language_major` | Gengoscript language major version. |
| 18 | 10 | 2 | `u16` | `language_minor` | Gengoscript language minor version. |
| 20 | 12 | 4 | `u32` | `flags` | Compilation flags bitfield. See §6.2. |
| 24 | 16 | 4 | `u32` | `target_id` | Target platform identifier. See §6.3. |
| 28 | 20 | 4 | `u32` | `backend_id` | Bytecode backend identifier. See §6.4. |
| 32 | 24 | 2 | `u16` | `entry_kind` | Entry kind of this artifact. See §6.5. |
| 34 | 26 | 6 | — | `_reserved` | Must be zero. Reject if nonzero. |
| 40 | 32 | 8 | `i64` | `compiled_at` | Unix timestamp (seconds) of compilation. **Debug and logging only. Never used for cache invalidation.** |
| 48 | 40 | 32 | `hash32` | `source_graph_hash` | SHA-256 of the source graph. See §6.6. |
| 80 | 72 | 32 | `hash32` | `vm_fingerprint` | SHA-256 identifying the runtime VM binary. See §6.6. |
| 112 | 104 | 32 | `hash32` | `module_provider_hash` | SHA-256 identifying the module provider / stdlib. See §6.6. |
| 144 | 136 | 32 | `hash32` | `options_hash` | SHA-256 of the canonical compiler options encoding. See §6.6. |
| 176 | 168 | 8 | `u64` | `body_length` | Length of the body in bytes. |
| 184 | 176 | 8 | `u64` | `body_checksum` | xxHash64 of the body bytes. |

Total defined header size for `header_version` 1: **184 bytes** (file offsets 8–191 inclusive).

### 6.2 Flags Bitfield

| Bit | Mask | Name | Description |
|-----|------|------|-------------|
| 0 | `0x0001` | `DEBUG_INFO` | At least one of `DEBUG_SPANS` or `DEBUG_NAMES` sections is present. If either section is present, this flag must be set. If this flag is set, at least one debug section must be present. |
| 1 | `0x0002` | `CHECKED_ARITHMETIC` | Range constraint checks are enabled (dev/checked mode). |
| 2 | `0x0004` | `OPTIMISED` | Compiled with optimisation enabled (release mode). |
| 3–31 | — | `RESERVED` | Must be zero. Reject if any reserved bit is set. |

`CHECKED_ARITHMETIC` and `OPTIMISED` are independent flags. The compiler may reject that combination at invocation time as a policy decision, but the format imposes no such restriction. Both bits set is a valid encoding that a loader must accept if the compiler permits it.

### 6.3 Target Identifiers

| Value | Constant | Description |
|-------|----------|-------------|
| `0x0000` | `TARGET_UNSPECIFIED` | Invalid; reject. |
| `0x0001` | `TARGET_WASM32_WASI` | WebAssembly 32-bit, WASI system interface. |
| `0x0002` | `TARGET_NATIVE_X86_64` | Native x86-64. Reserved, not yet used. |
| `0x0003` | `TARGET_NATIVE_AARCH64` | Native AArch64. Reserved, not yet used. |

All other values are reserved and must cause rejection.

### 6.4 Backend Identifiers

| Value | Constant | Description |
|-------|----------|-------------|
| `0x0000` | `BACKEND_UNSPECIFIED` | Invalid; reject. |
| `0x0001` | `BACKEND_BYTEVM` | Stack-based bytecode interpreter (current). |

All other values are reserved and must cause rejection.

### 6.5 Entry Kind

| Value | Constant | Description |
|-------|----------|-------------|
| `0x0000` | `ENTRY_UNSPECIFIED` | Invalid; reject. |
| `0x0001` | `ENTRY_SCRIPT` | Module with executable top-level body. No required EXPORTS section, but may have one if public declarations exist. May be imported by other artifacts if and only if it has an EXPORTS section with at least one entry; importing it runs top-level initialization exactly once. |
| `0x0002` | `ENTRY_MODULE` | Importable module artifact. Must have an EXPORTS section; `export_count` may be zero. Top-level code (if any) runs once on first import. |
| `0x0003` | `ENTRY_REPL_CELL` | REPL fragment. Depends on ambient REPL state; not independently loadable. |
| `0x0004` | `ENTRY_TEST` | Test artifact. |

See §1 for the rationale for treating scripts and modules as the same underlying shape.

### 6.6 Hash Fields

**`source_graph_hash`**

All inputs to `source_graph_hash` are length-prefixed using `str` encoding (§3) to prevent segmentation ambiguity — two different input sequences must not produce the same concatenated byte string. A domain label is prepended so this hash cannot be confused with hashes of other structures.

All inputs are length-prefixed using `str` or `bytes` encoding (§3) to prevent segmentation ambiguity. A domain label is prepended so this hash cannot be confused with hashes of other structures.

For a single-file source with no file imports:
```
source_graph_hash = SHA-256(
  str("GENGO_SOURCE_GRAPH_V1") ||
  str(root_source_utf8)
)
```

For a source that imports other files (once file imports are implemented):
```
source_graph_hash = SHA-256(
  str("GENGO_SOURCE_GRAPH_V1")      ||
  str(root_source_utf8)             ||
  u32le(file_dep_count)             ||
  for each resolved file dependency in stable topological order:
    str(resolved_id_utf8)           ||
    SHA-256(dep_source_utf8)
)
```

The stdlib is not included in `source_graph_hash` because it is covered by `module_provider_hash`. The topological ordering must be canonical and must not depend on filesystem ordering, discovery order, or any non-deterministic factor.

**`vm_fingerprint`**

For `TARGET_WASM32_WASI`: `SHA-256(gengo-cli.wasm)` — the same hash computed by `playground/deploy.sh`.

For other targets: a build-ID, git commit hash, or host-supplied ABI fingerprint agreed upon between compiler and loader. The important property is that this value changes whenever the bytecode instruction set changes, opcode encoding changes, native function binding table changes, or any other change would cause existing bytecode to produce different results.

This field is named `vm_fingerprint` rather than "runtime WASM hash" because it must work for non-WASM targets.

**`module_provider_hash`**

Identifies the set of modules and native bindings available at runtime.

For the current runtime, where `std` and all native providers are compiled into the runtime binary:
```
module_provider_hash = vm_fingerprint
```

Once stdlib ships as a separate binary or module providers become independently versioned:
```
module_provider_hash = SHA-256(
  str("GENGO_MODULE_PROVIDER_V1")               ||
  bytes(stdlib_binary)                          ||
  bytes(provider_registry_canonical_encoding)
)
```

`stdlib_binary` uses `bytes` (not `str`) because a compiled binary is not required to be valid UTF-8. All inputs are length-prefixed to prevent segmentation ambiguity.

Rationale for a separate field: `vm_fingerprint` covers the VM instruction interpreter; `module_provider_hash` covers what the bytecode can call. When these are the same binary they are the same value, but they must remain separate fields to allow them to evolve independently.

**`options_hash`**

SHA-256 of the canonical compiler options encoding (see §12 for encoding rules). Must change whenever any option that affects code generation changes.

---

## 7. Body Structure

The body begins at file byte offset `8 + header_size` and is exactly `body_length` bytes long. The `body_checksum` must equal `xxHash64(body_bytes)`. The checksum must be verified before any section is parsed.

### 7.1 Section Table

The body begins with a section table:

```
section_count : u32
section_table : [section_count]SectionEntry
```

Each `SectionEntry`:

```
SectionEntry {
  section_id : u32
  flags      : u32
  offset     : u64   // byte offset from start of body
  length     : u64   // byte length of section data
}
```

Section data begins at `body_start + entry.offset`. Sections may appear in any order. The section table itself has no required ordering, but by convention sections are written in the order listed in §7.2.

Section byte ranges must not overlap. A loader must reject a file where any two sections have overlapping byte ranges.

### 7.2 Section Identifiers

| `section_id` | Constant | Entry kinds | Description |
|--------------|----------|-------------|-------------|
| `0x0001` | `SEC_BYTECODE` | All | Raw instruction stream. |
| `0x0002` | `SEC_CONSTANTS` | All | Constant pool. |
| `0x0003` | `SEC_FUNCTIONS` | All | Function metadata table. |
| `0x0004` | `SEC_NATIVE_IMPORTS` | All | Native function binding declarations. |
| `0x0005` | `SEC_EXPORTS` | MODULE, optionally SCRIPT | Exported name table. |
| `0x0006` | `SEC_TYPES` | All | Type definitions. |
| `0x0007` | `SEC_DEPENDENCY_TABLE` | All | Import specifiers and dependency hashes. |
| `0x0100` | `SEC_DEBUG_SPANS` | All (opt.) | Source location spans per instruction. |
| `0x0101` | `SEC_DEBUG_NAMES` | All (opt.) | Variable names for debugging. |
| `0x8000`–`0xFFFF` | Vendor | — | Vendor or extension sections. |

### 7.3 Required vs Optional Sections

The low bit of the `flags` field in each `SectionEntry` controls handling of unknown sections:

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | `REQUIRED` | Loader must reject if it does not understand this section. |

If `REQUIRED` is not set and the loader does not recognise `section_id`, it must skip the section silently.

All sections marked "All" in §7.2 must be present with `REQUIRED` set. `SEC_EXPORTS` must be present and REQUIRED for `ENTRY_MODULE`; for `ENTRY_SCRIPT` it is optional and may be absent.

---

## 8. Section Formats

### 8.1 BYTECODE

The raw instruction stream as emitted by the compiler. Opaque to the format; its interpretation is defined by the instruction set reference for the `format_major`/`format_minor` version pair.

```
bytecode_bytes : [section.length]u8
```

No wrapper. Section length equals the number of instruction bytes. Function entries in `SEC_FUNCTIONS` reference byte offsets and lengths within this section.

### 8.2 CONSTANTS

The constant pool.

```
constant_count : u32
constants      : [constant_count]Constant
```

Each `Constant` is a tag byte followed by tag-specific data:

| Tag | Value | Data | Description |
|-----|-------|------|-------------|
| `NUMBER` | `0x01` | `f64` | IEEE 754 double. A `.float`-tagged Value only — see `INT` below; a writer must never emit `NUMBER` for a `.int`-tagged Value even when the integer is exactly representable as `f64`. |
| `STRING` | `0x02` | `str` | UTF-8 string. |
| `NULL` | `0x03` | — | No data bytes. |
| `BOOL` | `0x04` | `bool8` | Boolean value. |
| `RUNE` | `0x05` | `u32` | Unicode code point (0–0x10FFFF). Reject values outside this range. |
| `INT` | `0x06` | `i64` | A `.int`-tagged Value. See below. |
| `FUNC_REF` | `0x07` | `u32` | Index into `SEC_FUNCTIONS`. See below. |
| `TYPE_REF` | `0x08` | `u32` | Index into `SEC_TYPES`. See below. |

**`INT`**: the VM's `Value` union carries `.int` and `.float` as two distinct, never-implicitly-mixed tags (Gengo enforces nominal int/float strictness in arithmetic, comparison, and named-type binding — see `docs/changelog.md`'s "Strict int/float comparison" and "Nominal type strictness" entries) — the wire format must preserve which one a constant was, not merely a value that happens to look like one. Prior to this tag's introduction, both `.int` and `.float` were written through `NUMBER` as `f64`, and a loader reconstructed the tag with a "no fractional part → int" heuristic (§8.2, pre-0.7) — that heuristic is wrong for a whole-valued float (`1.0`, `2.0`, ...), silently turning it into `.int` on load and breaking any code that depends on it staying a float. `INT` removes the ambiguity: writers emit `.int` values through `INT` (raw `i64`, no round-tripping through `f64` and its 2^53 exact-integer ceiling) and `.float` values through `NUMBER`; loaders never guess. Found via the first round-trip test that returned a whole-valued float constant (`#5`, extending variant-type support) — every prior test happened to avoid that exact shape.

**`FUNC_REF`**: the constant pool has no self-contained representation for a function or closure — `make_closure` (and any other instruction addressing a function by constant index) resolves through this indirection instead. A `FUNC_REF` constant's `u32` value must be `< function_count` in `SEC_FUNCTIONS` (§8.3); a loader constructs the function object described by that `FunctionEntry` and installs it at this constant-pool slot before any bytecode runs. Referencing the same `FunctionEntry` from more than one `FUNC_REF` constant is invalid (each function has exactly one home constant slot) and must be rejected. `FUNC_REF` must not appear in any other constant-consuming context (e.g. as a value produced by the `constant` opcode) — it exists solely to let a `SEC_FUNCTIONS` entry occupy a constant-pool slot.

**`TYPE_REF`**: the same indirection as `FUNC_REF`, for a struct, named, variant, or interface type — `def_global` for a `type X struct {...}`/`type X int ...`/`type X variant {...}`/`type X interface {...}` declaration needs a constant-pool slot to hold the type object. A `TYPE_REF` constant's `u32` value must be `< type_count` in `SEC_TYPES` (§8.6); a loader constructs the `STRUCT`, `NAMED`, `VARIANT`, or `INTERFACE` type object described by that `TypeEntry` and installs it at this constant-pool slot before any bytecode runs. Same one-home-slot-per-entry rule as `FUNC_REF`. A struct field or named-collection element/key/value referencing *another* type by name (a `STRUCT_T`/`NAMED_T`/etc. `FieldTypeAlt`) does so by qualified-name string, not by a nested `TYPE_REF` — see §9.2 — so the referenced type's own `TYPE_REF` constant (if it has one) is independent of any reference to it.

Constants are indexed from 0. Instructions reference constants by `u16` or `u32` index as defined in the instruction set.

### 8.3 FUNCTIONS

Metadata for every compiled function, including closures and anonymous functions.

```
function_count : u32
functions      : [function_count]FunctionEntry
```

Each `FunctionEntry`:

```
FunctionEntry {
  name_constant_idx  : u32      // index into CONSTANTS for name str; 0xFFFFFFFF = anonymous
  bytecode_offset    : u32      // byte offset into BYTECODE section
  bytecode_length    : u32      // byte length of this function's instructions
  local_count        : u16      // number of local variable slots (includes parameters)
  arity              : u8
  is_variadic        : bool8
  variadic_type      : TypeSpec   // present only if is_variadic
  has_typed_params   : bool8
  has_typed_returns  : bool8
  named_return_count : u8
  param_type_count   : u16
  param_types        : [param_type_count]TypeSpec
  return_type_count  : u16
  return_types       : [return_type_count]TypeSpec
  capture_slot_count : u8
  capture_slots      : [capture_slot_count]u8
}
```

`bytecode_offset + bytecode_length` must not exceed the length of the `SEC_BYTECODE` section. Function byte ranges within BYTECODE may overlap (closures sharing outer code are not required to be separate ranges), but each `FunctionEntry` must reference a valid byte range.

`local_count` includes parameter slots. The VM uses this to allocate the call frame.

### 8.4 NATIVE\_IMPORTS

Declarations of all native (host-provided) functions referenced by this artifact. Native functions are resolved symbolically at load time; they are never stored as raw function pointers or implementation-internal integer IDs.

```
native_import_count : u32
native_imports      : [native_import_count]NativeImportEntry
```

Each `NativeImportEntry`:

```
NativeImportEntry {
  symbolic_id : str     // e.g. "std.io.println"
  arity       : u8
  is_variadic : bool8
}
```

On load, the runtime looks up each `symbolic_id` in the current native function registry. If not found, or if `arity` does not match the current binding, the load must fail (see §10).

Native import entries are referenced by index from bytecode instructions. The GBC index may differ from the runtime's internal native ID; the loader builds the mapping table at load time before any bytecode executes.

### 8.5 EXPORTS

Required for `ENTRY_MODULE` artifacts (with `export_count` ≥ 0); optional for `ENTRY_SCRIPT`. A module with no public declarations must still include this section with `export_count = 0`. Lists the public names this artifact exports.

```
module_id    : str          // this artifact's own canonical module identity
                             // (§14) — an importer's SEC_DEPENDENCY_TABLE
                             // resolved_id for this artifact, if linked,
                             // must equal this value, not the local import
                             // specifier the importer happened to write.
export_count : u32
exports      : [export_count]ExportEntry
```

Each `ExportEntry`:

```
ExportEntry {
  exported_name  : str            // the name importers use
  qualified_name : str            // the internal qualified global name
  type_kind      : u8             // 0=FUNC_OR_VAR 1=STRUCT 2=INTERFACE
                                   // 3=NAMED 4=VARIANT — mirrors the
                                   // compiler's own export classification;
                                   // lets a loader rebuild a full module
                                   // symbol table from this section alone,
                                   // with no live Compiler involved (§14).
  const_value    : OptConstValue  // present for every entry; NONE for a
                                   // non-const export (a func or a mutable
                                   // top-level var)
}
```

`OptConstValue` (a tagged compile-time constant, mirroring the compiler's
own `CompileTimeConst`):

```
OptConstValue {
  tag     : u8    // 0=NONE 1=NUMBER 2=STRING 3=BOOLEAN
  // payload present only if tag != NONE:
  number  : f64   // present only if tag == NUMBER
  string  : str    // present only if tag == STRING
  boolean : bool8  // present only if tag == BOOLEAN
}
```

`module_id` and the `type_kind`/`const_value` fields on `ExportEntry` were
added in format v2 (§14) — a v1 reader (`format_major == 1`) never
constructed a `SEC_EXPORTS` this shape, so this is a `format_major` bump,
not a backward-compatible addition.

### 8.6 TYPES

All user-defined types declared in this artifact. Serialised so the runtime can resolve type metadata without executing any bytecode.

```
type_count : u32
types      : [type_count]TypeEntry
```

Each `TypeEntry` begins with a kind byte:

```
TypeEntry {
  kind           : u8
  name           : str
  qualified_name : str
  // kind-specific fields follow (see below)
}
```

| Kind | Value |
|------|-------|
| `STRUCT` | `0x01` |
| `NAMED` | `0x02` |
| `ENUM` | `0x03` |
| `INTERFACE` | `0x04` |
| `VARIANT` | `0x05` |

**STRUCT** (`0x01`) — after common fields:
```
field_count : u16
fields      : [field_count]StructField
```
Each `StructField`: `name : str`, `type : TypeSpec`, `is_const : bool8`

**NAMED** (`0x02`) — after common fields:
```
base           : u8      // 0=int 1=float 2=string 3=bool 4=rune 5=array 6=map 7=enum_t
has_range      : bool8
is_cycle       : bool8
is_clamp       : bool8    // mutually exclusive with is_cycle; both false = hard range (RangeError)
min            : f64     // present only if has_range; see note below
max            : f64     // present only if has_range; see note below
parent_name    : str     // empty if not a subtype
elem_spec_present : bool8
elem_spec      : TypeSpec  // only if elem_spec_present — array_t base only
key_spec_present  : bool8
key_spec       : TypeSpec  // only if key_spec_present — map_t base only
val_spec_present  : bool8
val_spec       : TypeSpec  // only if val_spec_present — map_t base only
is_anonymous   : bool8    // an implicit wrapper for a bare `[]T`/`map[K]V`-typed
                          // local, not a user `type X ...` — read at runtime for
                          // anonymous array/map-typed-value equality
scale          : u8       // decimal fixed-point precision; 0 for every non-decimal base
has_predicate  : bool8
predicate_func_idx : u32  // present only if has_predicate — index into SEC_FUNCTIONS
                          // (§8.3); the loader wraps the resulting FuncObj in a
                          // zero-upvalue closure. A predicate declared inside a
                          // function body (capturing that function's own locals)
                          // is out of scope — writers must reject it rather than
                          // encode a captures-carrying closure here.
has_predicate_msg  : bool8  // present only if has_predicate
predicate_msg      : str    // present only if has_predicate_msg
has_default    : bool8
default_val    : f64 | str | bool8  // present only if has_default; shape depends
                                     // on base — float for int/float/rune/decimal,
                                     // str for string, bool8 for bool (array_t/
                                     // map_t/enum_t bases never have a default)
```

> **v1 limitation:** Range bounds are stored as `f64` regardless of whether the base type is integer or float. This matches the current VM's internal representation but loses exact representation for integers whose absolute value exceeds 2^53. A future format version should introduce a tagged `Bound` encoding. Until then, implementations must not define integer-typed named types with range bounds outside ±2^53, and loaders should reject such artifacts.

**ENUM** (`0x03`) — after common fields:
```
member_count    : u16
members         : [member_count]str
has_member_ints : bool8
member_ints     : [member_count]i64   // present only if has_member_ints
parent_name     : str                 // empty if not a subtype
```

> **Found during implementation (#5):** this section originally specified only `members`/`parent_name`, omitting explicit representation values (`type Status enum { pending = 10, active = 20, done = 30 }`) entirely. Without them a loader has no choice but to fall back to ordinal position, silently producing the wrong `.int` value for any enum whose explicit values diverge from ordinals — verified by round-tripping exactly that case before this was added. `has_member_ints`/`member_ints` follow the same present-flag-then-payload convention `NAMED`'s own optional fields (`elem_spec`/`key_spec`/`val_spec`/predicate/default) already use in this same section. `member_ints[i]` corresponds to `members[i]`; absent means every member's representation value is its ordinal position, matching `compiler_decls.zig`'s own enum-parsing convention.

**INTERFACE** (`0x04`) — after common fields:
```
method_count : u16
methods      : [method_count]InterfaceMethod
```
Each `InterfaceMethod`:
```
InterfaceMethod {
  name              : str
  arity             : u8
  is_variadic       : bool8
  variadic_type     : TypeSpec   // present only if is_variadic
  has_typed_params  : bool8
  has_typed_returns : bool8
  param_type_count  : u16
  param_types       : [param_type_count]TypeSpec
  return_type_count : u16
  return_types      : [return_type_count]TypeSpec
}
```

**VARIANT** (`0x05`) — after common fields:
```
shared_field_count : u16
shared_fields      : [shared_field_count]StructField
arm_count          : u16
arms               : [arm_count]VariantArm
```
`shared_fields` are fields declared directly in the variant body outside any
arm (`name type`, not inside an arm's `{...}`/`(...)`) — common to every arm
of the type, using the same `StructField` shape §8.6's `STRUCT` kind defines
above. Each `VariantArm`:
```
VariantArm {
  name     : str
  arm_kind : u8   // 0=NONE  1=SINGLE_PAYLOAD  2=RECORD
  // NONE: no further fields — a bare tag, e.g. `point` in `point,`.
  // SINGLE_PAYLOAD (present only if arm_kind == 1):
  payload_name : str        // e.g. `value` in `ok(value int)`
  payload_type : TypeSpec
  // RECORD (present only if arm_kind == 2):
  field_count  : u16
  fields       : [field_count]StructField   // e.g. `{ topic string, qos Qos }`
}
```
A variant arm has exactly one of two source shapes — `arm(payload_type)` (one
positional/named payload) or `arm { f1 T1, f2 T2, ... }` (zero or more named
fields, struct-style) — plus a bare no-payload form (`arm,`). `arm_kind`
makes the wire encoding explicit rather than inferring it from field/payload
presence, since a `RECORD` arm may have zero fields (`arm {}`), same shape as
`NONE` in every respect except which construction syntax accepted it.
`ordinal` (an arm's position in `arms`) is never itself semantically
significant on load — `switch`/field access always re-resolve an arm by
`name`, not by index (see the `variant_check` opcode and
`variantTypeFieldValue`) — so a loader is free to preserve or renumber
this array's order.

### 8.7 DEPENDENCY\_TABLE

Declares the **direct** imports made by this source — those that appear explicitly in the source text — with both the written specifier and its canonical resolved identity. Transitive dependencies are not listed here; their identity is captured through `source_graph_hash` in the header and through the dependency artifacts' own `DEPENDENCY_TABLE` sections.

```
dependency_count : u32
dependencies     : [dependency_count]DependencyEntry
```

Each `DependencyEntry`:

```
DependencyEntry {
  written_specifier : str      // as it appears in source, e.g. "std", "./math", or "./mathlib.gbc"
  resolved_id       : str      // canonical module identity; see below
  kind              : u8       // 0=STDLIB 1=FILE 2=HOST_PROVIDED 3=LINKED_ARTIFACT
  source_hash       : hash32   // SHA-256 of dependency source; all zeros for STDLIB and LINKED_ARTIFACT
  artifact_body_hash     : hash32   // SHA-256 of dependency's GBC artifact; all zeros if unavailable
  qualified_prefix  : str      // prefix used for symbols from this import in the compiled output
}
```

**`kind = LINKED_ARTIFACT`** (`3`, added in format v2, §14) is a precompiled
`.gbc` dependency spliced directly into this artifact's compiled output at
compile time — the mechanism §14 defines. Unlike `FILE` (check 21, §11.1:
recompile-from-source-if-changed), a `LINKED_ARTIFACT` dependency has no
source to recompile from at load time by definition, so its trust model is
different: `artifact_body_hash` is **mandatory** (not advisory) and must
match the dependency's actual GBC body bytes **exactly**. A mismatch — a
corrupted, substituted, or since-recompiled dependency artifact — must fail
loudly (`LinkedArtifactMismatch`), never fall back to any other behavior.
`resolved_id` for a `LINKED_ARTIFACT` entry must equal the dependency
artifact's own `SEC_EXPORTS.module_id` (§8.5), not a path derived from the
importer's `written_specifier`.

An artifact that itself contains any `LINKED_ARTIFACT` dependency entry
must not be produced as a linkable `ENTRY_MODULE` — §14 bounds linking to a
single level; a writer must reject compiling `--emit-gbc-module` output
whose source transitively imports a `.gbc`.

**`resolved_id`** is the canonical identity of the dependency as determined by the module resolver at compile time. It must be stable across equivalent resolutions (symlinks, `../` normalisations, etc. must all produce the same `resolved_id` for the same logical module). Suggested URI-style format:

| Kind | Example `resolved_id` |
|------|----------------------|
| STDLIB | `std://io`, `std://core` |
| File (WASI) | `file:///project/src/math.gengo` |
| File (browser/virtual FS) | `mem://playground/math.gengo` |
| Host-provided | `host://app/config` |
| Linked artifact | the dependency's own `SEC_EXPORTS.module_id` verbatim (§14) |

The exact URI scheme is host-defined. The loader must compare `resolved_id` strings exactly (byte-for-byte) and must not perform path normalisation on load; normalisation is a compile-time responsibility.

For `kind = STDLIB`, `source_hash` is all zeros — stdlib is covered by `module_provider_hash` in the header.

For `kind = FILE`, the loader must re-read the dependency source at the path implied by `resolved_id` and verify that `SHA-256(current_source) == source_hash`. If the hashes differ, the root artifact is stale.

`artifact_body_hash` is the SHA-256 of the dependency's compiled GBC artifact **body bytes** (the bytes covered by `body_checksum`, not the whole file), if available at compile time. Set to all zeros when not available.

Note: body-only means two artifacts with identical body content but different headers (different `vm_fingerprint`, `options_hash`, `language_version`, etc.) will share the same `artifact_body_hash`. This is acceptable only because the field is advisory and full validation is mandatory before trusting it.

`artifact_body_hash` is **advisory**. A loader may use it to locate a candidate dependency artifact, but must still perform full validation on that artifact — all 27 checks from §11.1 — before trusting it. A matching `artifact_body_hash` alone is not sufficient.

### 8.8 DEBUG\_SPANS (optional)

Maps bytecode instruction offsets to source locations. Present only when the `DEBUG_INFO` flag is set.

```
span_count : u32
spans      : [span_count]DebugSpan
```

Each `DebugSpan`:

```
DebugSpan {
  bytecode_offset : u32   // byte offset into BYTECODE section
  line            : u32   // 1-based source line
  column          : u16   // 1-based column
}
```

Entries are in ascending `bytecode_offset` order. Not every instruction requires a span entry. A loader looking up a location for offset `X` uses the last span entry with `bytecode_offset <= X`.

### 8.9 DEBUG\_NAMES (optional)

Maps local variable slot indices to human-readable names. Present only when `DEBUG_INFO` is set.

```
scope_count : u32
scopes      : [scope_count]DebugScope
```

Each `DebugScope`:

```
DebugScope {
  function_idx : u32   // index into FUNCTIONS section
  local_count  : u16
  locals       : [local_count]DebugLocal
}
```

Each `DebugLocal`: `slot : u8`, `name : str`

---

## 9. Type Encoding

### 9.1 TypeSpec

A `TypeSpec` encodes a type annotation, which may be a union of alternatives.

```
TypeSpec {
  alt_count : u8
  alts      : [alt_count]FieldTypeAlt
}
```

`alt_count` must be ≥ 1. An empty alternative set is invalid and must be rejected. Duplicate alternatives (two alts with the same tag and identical fields) are not permitted; loaders should reject them. The order of alternatives is not semantically significant but must be consistent between compiler and loader.

### 9.2 FieldTypeAlt

Each alternative is a tag byte followed by tag-specific fields. Only the fields listed for a given tag are present; no others are written or expected.

**`ANY` (`0x00`)** — no additional fields.

**`NULL_T` (`0x01`)** — no additional fields.

**`INT` (`0x02`)** — no additional fields.

**`FLOAT` (`0x03`)** — no additional fields.

**`RUNE_T` (`0x04`)** — no additional fields.

**`BOOLEAN` (`0x05`)** — no additional fields.

**`STRING` (`0x06`)** — no additional fields.

**`ERROR_T` (`0x07`)** — no additional fields.

**`ARRAY` (`0x08`)**:
```
elem_spec_present : bool8
elem_spec         : TypeSpec   // only if elem_spec_present
```

**`MAP` (`0x09`)**:
```
key_spec_present : bool8
key_spec         : TypeSpec   // only if key_spec_present
val_spec_present : bool8
val_spec         : TypeSpec   // only if val_spec_present
```

**`STRUCT_T` (`0x0A`)**:
```
struct_name : str
```

**`INTERFACE_T` (`0x0B`)**:
```
interface_name : str
```

**`NAMED_T` (`0x0C`)**:
```
named_name : str
```

**`VARIANT_T` (`0x0D`)**:
```
named_name : str
```

**`FUNC_T` (`0x0E`)**:
```
func_param_count  : u16
func_params       : [func_param_count]TypeSpec
func_return_count : u16
func_returns      : [func_return_count]TypeSpec
```

**`DECIMAL_T` (`0x0F`)** — no additional fields.

> **Note:** `decimal` was missing from this table entirely through v0.5 despite being an ordinary scalar base (`NUMBER`'s own kind-specific fields make no distinction, but `FieldTypeAlt` needs a tag to mark a struct field or named-collection element/key/value as decimal-typed, the same way `INT`/`FLOAT`/`RUNE_T` do). Found while extending GBC's struct/named-type support to actually round-trip `decimal` fields (#5). Added at `0x0F`, after `FUNC_T`, rather than renumbering.

---

## 10. Native Function Resolution

Native functions are stored as stable symbolic identifiers in `SEC_NATIVE_IMPORTS`. The mapping from symbolic ID to internal runtime ID is the loader's responsibility, established at load time.

The canonical symbolic ID format:

```
<module>.<submodule>.<function>
```

Current examples:
- `std.io.println`
- `std.io.printf`
- `std.core.len`
- `std.core.append`
- `std.core.recover`
- `std.conv.to_string`

### Loader resolution procedure

1. For each entry in `SEC_NATIVE_IMPORTS` (in index order):
   a. Look up `symbolic_id` in the current native function registry.
   b. If not found: fail with `NativeBindingNotFound(symbolic_id)`.
   c. If found but `arity` does not match the current binding: fail with `NativeArityMismatch(symbolic_id, declared_arity, actual_arity)`.
   d. Record the mapping: GBC native index → runtime native ID.
2. Patch or redirect all bytecode references through this mapping before any execution begins.

If any binding fails, abort the load entirely. Partial loading is not permitted.

**Do not store internal numeric native IDs in GBC files.** The current VM uses `NativeFuncObj { id: u8 }` internally. This is an implementation detail that may be renumbered without a format version bump. Only symbolic IDs are stable.

---

## 11. Validation Rules

### 11.1 Validation Phases

Validation proceeds in four phases. Failure at any point aborts loading with a specific error. Do not proceed to a later phase after a failure.

**Phase 1 — Structural/header integrity**

These checks require no content interpretation beyond reading fixed-offset bytes.

| # | Check | Failure |
|---|-------|---------|
| 1 | Magic bytes match exactly | `InvalidMagic` |
| 2 | File is at least `8 + header_size` bytes | `TruncatedHeader` |
| 3 | `header_version` is within the supported range | `UnsupportedHeaderVersion(n)` |
| 4 | `header_size >= 184` (minimum for `header_version` 1) | `HeaderTooSmall` |
| 5 | Reserved bytes in header are all zero | `NonZeroReserved` |
| 6 | `format_major` matches loader's supported major | `FormatMajorMismatch(artifact, loader)` |
| 7 | `format_minor <= loader's format_minor` | `FormatMinorTooNew(artifact, loader)` |
| 8 | `language_major` matches loader's language major | `LanguageMajorMismatch(artifact, loader)` |
| 9 | `language_minor <= loader's language_minor` | `LanguageMinorTooNew(artifact, loader)` |
| 10 | `target_id` is a known value and matches current runtime target | `TargetMismatch(artifact, runtime)` |
| 11 | `backend_id` is a known value and matches current runtime backend | `BackendMismatch(artifact, runtime)` |
| 12 | `entry_kind` is a known non-zero value | `UnknownEntryKind(n)` |
| 13 | `flags` reserved bits are all zero | `UnknownFlags` |
| 14 | File is at least `8 + header_size + body_length` bytes | `TruncatedBody` |
| 15 | `xxHash64(body_bytes) == body_checksum` | `BodyChecksumMismatch` |

**Phase 2 — Section table validation**

Parse the section table from the body. The body checksum (check 15) guarantees the section table has not been corrupted.

| # | Check | Failure |
|---|-------|---------|
| 16 | Section table is parseable (count reasonable, entries fit within body) | `MalformedSectionTable` |
| 17 | All sections marked REQUIRED and listed in §7.2 as required for this entry kind are present | `MissingRequiredSection(section_id)` |
| 18 | No two sections have overlapping byte ranges | `SectionOverlap(id_a, id_b)` |
| 19 | All section data falls within the body bounds | `SectionOutOfBounds(section_id)` |

**Phase 3 — Cache validity / staleness**

Requires reading `SEC_DEPENDENCY_TABLE` and querying external state (filesystem, runtime version). Parse the dependency table before computing source graph hash.

| # | Check | Failure |
|---|-------|---------|
| 20 | `SEC_DEPENDENCY_TABLE` is parseable | `MalformedDependencyTable` |
| 21 | For each FILE dependency: `SHA-256(current_source) == entry.source_hash`. For each LINKED_ARTIFACT dependency (§14): `SHA-256(dependency_artifact_body_bytes) == entry.artifact_body_hash` exactly — no recompile fallback | `DependencyStale(resolved_id)` / `LinkedArtifactMismatch(resolved_id)` |
| 22 | `source_graph_hash` matches the computed source graph hash | `SourceGraphStale` |
| 23 | `vm_fingerprint` matches the current runtime VM fingerprint | `VMFingerprintMismatch` |
| 24 | `module_provider_hash` matches the current module provider fingerprint | `ModuleProviderMismatch` |
| 25 | `options_hash` matches the current compiler options hash | `CompilerOptionsMismatch` |

**Phase 4 — Content validity**

| # | Check | Failure |
|---|-------|---------|
| 26 | All native imports in `SEC_NATIVE_IMPORTS` resolve with matching arities | `NativeBindingNotFound(id)` or `NativeArityMismatch(id, ...)` |
| 27 | All known sections parse without error and all internal cross-references are in range | `MalformedSection(section_id)` |

Check 27 covers at minimum: function `bytecode_offset + bytecode_length` within `SEC_BYTECODE`; `name_constant_idx` is `0xFFFFFFFF` or a `STRING` constant; all constant indices in bytecode within `constant_count`; export `qualified_name` strings are non-empty; debug scope `function_idx` within `function_count`; debug `bytecode_offset` within `SEC_BYTECODE`; `RUNE` constants in range 0–0x10FFFF; all `bool8` fields are `0x00` or `0x01`; `TypeSpec.alt_count >= 1`. Loaders are not required to exhaustively validate every bytecode instruction, but must validate all metadata structures.

### 11.2 Implementation-Defined Limits

Loaders must impose implementation-defined upper bounds on all count and size fields to prevent malicious or corrupt cache files from causing excessive memory allocation. The spec does not mandate specific values, but loaders must document and enforce limits on at minimum: `section_count`, `constant_count`, `function_count`, `type_count`, `native_import_count`, `export_count`, `dependency_count`, `span_count`, `scope_count`, individual `str` and `bytes` lengths, `TypeSpec.alt_count`, and `FunctionEntry.local_count`.

Exceeding an implementation-defined limit must be treated as a validation failure (reject and recompile), not a recoverable error.

### 11.3 Error Handling

On any validation failure:

- Report the specific failure with enough context for a human to diagnose (section ID, specifier, version numbers, etc.).
- Do not attempt partial loading or partial VM initialisation.
- Do not fall back to "best effort" interpretation of a corrupt or stale artifact.
- Signal to the caller that recompilation is required.
- Do not delete the artifact; leave eviction decisions to the caller.

**`compiled_at` must never be used for cache invalidation.** It exists solely for diagnostic output ("this artifact is N days old").

---

## 12. Version Compatibility Policy

### Format versions (`format_major`, `format_minor`)

- **Major bump:** Any breaking change to binary layout, instruction encoding, section format, or primitive encoding. A loader must reject artifacts with a different `format_major`.
- **Minor bump:** Backward-compatible addition (e.g., new optional section ID, new optional trailing field in an existing section). A loader may accept artifacts with `format_minor <= loader's`. A loader must reject artifacts with `format_minor > loader's`.

### Language versions (`language_major`, `language_minor`)

- **Major bump:** Breaking language change. Loader must reject a different `language_major`.
- **Minor bump:** Additive language change. A loader may accept artifacts with `language_minor <= loader's`. Artifacts compiled for a newer minor must be rejected — they may depend on instructions or type features not yet present.

### Header version (`header_version`)

Bumped when the header layout changes in a backward-incompatible way (field removed, field reordered, field meaning changed). New fields appended to the end of the header do not require a `header_version` bump if the existing minimum size rule allows readers to skip them.

### `options_hash` canonical encoding

The canonical encoding for `options_hash` is a byte string computed as:

```
options_encoding_v1 = SHA-256(
  u8(1)             ||   // encoding version, currently 1
  u32le(target_id)  ||
  u32le(backend_id) ||
  u32le(flags)           // full flags field; all bits, including currently reserved ones
)
```

Integer widths match the header field widths (§6.1). The full `flags` field is hashed rather than a truncated byte, so future codegen-affecting flags in any bit position are automatically included without requiring an encoding version bump.

Adding a new option means appending bytes to the encoding and bumping the encoding version byte. This changes `options_hash` for all existing option sets regardless of the new option's value. This is intentional: accept that adding an option invalidates existing artifacts rather than attempting to preserve old hashes by conditionally omitting default-valued options. The encoding version byte gives loaders a mechanism to distinguish old encodings if a migration path is needed.

---

## 13. Dependency and Module Graph Hashing

`source_graph_hash` must cover the entire set of source inputs that affected this compiled artifact.

**Baseline (single file, no file imports):**
```
source_graph_hash = SHA-256(
  str("GENGO_SOURCE_GRAPH_V1") ||
  str(root_source_utf8)
)
```

**With file imports:**
```
source_graph_hash = SHA-256(
  str("GENGO_SOURCE_GRAPH_V1")      ||
  str(root_source_utf8)             ||
  u32le(file_dep_count)             ||
  for each resolved file dependency in stable topological order:
    str(resolved_id_utf8)           ||
    SHA-256(dep_source_utf8)
)
```

All textual inputs use `str` encoding (§3: `u32le` length prefix + UTF-8 bytes) to prevent segmentation ambiguity. The dependency source is included as its raw SHA-256 digest (32 bytes, no length prefix needed — the size is fixed). The `resolved_id` (not the `written_specifier`) is used because two different written specifiers may resolve to the same module. The topological order must be canonical and deterministic.

Each module artifact stores `source_graph_hash` covering only its own transitive file dependencies. This allows per-module cache invalidation: changing `math.gengo` invalidates `math.gbc` and the GBC of any module that imports it, but not unrelated modules.

---

## 14. Cross-Artifact Linking (v2)

### 14.1 Scope

An `ENTRY_MODULE` artifact (§6.5) may be imported directly by another
compile — its exports spliced into the importer's own compiled output —
without recompiling the module's source. This is **single-level only**: a
linkable module artifact must itself have zero `LINKED_ARTIFACT`
dependencies (§8.7). A loader implementing this section therefore never
needs to recursively load a `.gbc` discovered while loading another `.gbc`
— every `LINKED_ARTIFACT` a loader encounters is a leaf. A module's own
file (`FILE`-kind) imports are unaffected by this section: they are still
compiled from source into the module at the module's own compile time,
exactly as today; only the one hop from an importer to a precompiled
dependency is new.

### 14.2 Resolution: explicit only

An import resolves to a precompiled artifact only when the import
specifier names one directly, e.g. `import("./mathlib.gbc")`. There is no
implicit fallback where a `.gengo` file with a same-stem `.gbc` sibling on
disk is silently preferred over recompiling from source. Two reasons:

1. **Auditability.** Whether a given import links a precompiled artifact
   or compiles source is then a property of the source text itself, not of
   filesystem state the source text doesn't mention.
2. **Correctness dependencies.** §14.3 and §14.4 below only hold for an
   artifact deliberately produced as a linkable module (`emit_halt=false`,
   a real `module_id`, no transitive `LINKED_ARTIFACT` deps of its own). A
   transparent same-stem fallback would make those production requirements
   an implicit per-file convention instead of an explicit, checked step at
   artifact-production time.

Transparent caching (recompile only if the source's hash has moved past
what a cached `.gbc` claims) may be layered on top of explicit linking in
a later revision; it is not part of this one.

### 14.3 Module identity

A dependency's own compiled bytecode has its `@mod:<path>.<name>`-style
qualified names (compiler internal naming scheme) baked into `def_global`/
`get_global` string constants at the dependency's *own* compile time —
before the importer's `written_specifier` for it is even known. String
constants are pool-deduplicated; rewriting them to match an importer's
local specifier after the fact would be a far riskier operation than the
integer-index remap linking already requires (§14.5), and is not needed.

Instead, a linkable module artifact's `SEC_EXPORTS.module_id` (§8.5) is
its own canonical identity, fixed at the time it was produced. An
importer's `SEC_DEPENDENCY_TABLE` entry for it (§8.7, `kind =
LINKED_ARTIFACT`) records that `module_id` as `resolved_id` — never a path
or name derived from the importer's local `written_specifier`. A loader
splicing a `LINKED_ARTIFACT` dependency into an importing compile builds
that dependency's module-record identity (the internal
path/global-name/prefix/struct-name a compiler needs for cross-module
symbol resolution) from `module_id`, not from how the importer happened to
spell the import.

### 14.4 Producing a linkable module artifact

An artifact is eligible to be linked by another compile only if:

1. `entry_kind == ENTRY_MODULE` and `SEC_EXPORTS` is present (§6.5, §8.5).
2. It was compiled without an implicit top-level `halt` — the same
   compile path used for an ordinary imported source file today, not the
   entry-script path that appends one. An artifact compiled with a
   trailing `halt` would, once spliced into an importer's bytecode at any
   position other than the very end, terminate the *importer's* program
   the instant the spliced code ran. This is a writer-side production
   requirement (how a `--emit-gbc-module`-style artifact is compiled), not
   something a loader can detect or repair — a conforming writer never
   emits a `halt` into a `SEC_BYTECODE` intended to back an `ENTRY_MODULE`.
3. `SEC_DEPENDENCY_TABLE` contains no `LINKED_ARTIFACT` entry (§14.1's
   single-level bound). A writer must reject producing a linkable module
   artifact whose source transitively imports a `.gbc`.

### 14.5 Splicing mechanics (informative)

This subsection is non-normative implementation guidance, not a wire
format requirement — a loader is free to reach the same result by any
means. The reference approach: append the dependency's constants,
functions, types, and bytecode onto the end of the importing session's own
in-progress chunk (constants at the current constant-pool length, code at
the current code length), then walk only the newly-appended bytecode range
and, for every instruction with a constant-pool operand, add the constant
base offset to that operand. Function entry points (`FuncObj.ip`) get the
code base offset added the same way. Relative jump/loop offsets need no
adjustment — they encode a delta from the instruction's own position, not
an absolute address, so splicing at a new base preserves them unchanged.
No bytecode is rewritten in place; only integer operands that are
constant-pool or absolute-code-offset references are adjusted.

### 14.6 Trust model

Unlike a `FILE` dependency, which is recompiled from source and only
flagged stale if the source moved (§11.1 check 21, §14 notwithstanding), a
`LINKED_ARTIFACT` dependency has no source available to recompile from at
load time. Its `artifact_body_hash` (§8.7) is therefore mandatory and must
match the dependency's actual compiled body bytes exactly — a mismatch is
a hard failure (`LinkedArtifactMismatch`), never a silent fallback to
recompilation or to treating the dependency as absent.

---

## 15. Future: GSI Artifact Class

A **Gengoscript Snapshot Image** (`.gsi`) would contain all GBC content plus a serialised representation of live VM state at a checkpoint. The GSI format would reuse the GBC header with a different entry kind or a distinct magic sequence, and add sections for:

- `SEC_HEAP_SNAPSHOT` — Object pool serialised with pointer swizzling (pointers replaced by pool indices).
- `SEC_GLOBALS_SNAPSHOT` — Global variable table with values as pool references or primitives.
- `SEC_GC_METADATA` — GC generation, root set, finalisers.

Additional header fields would be needed: `heap_layout_version`, `gc_generation_at_snapshot`.

Open questions that must be resolved before GSI is designed:

- Are closures capturing heap objects fully serialisable, or must they be restricted?
- Are open WASI resources (file handles, sockets) preserved, closed, or flagged as invalid?
- Are interned strings part of the heap snapshot or rebuilt from the constant pool?
- Can host objects (opaque to the VM) be serialised?
- What happens if the GC layout changes between the runtime that wrote the snapshot and the runtime that reads it?

**Do not design GSI until GBC is stable and in production use.**

---

## 16. Non-Goals for GBC v1

- **Heap serialisation.** Live VM state is not part of GBC.
- **Cross-compilation.** A `TARGET_WASM32_WASI` artifact is not loadable as `TARGET_NATIVE_X86_64`.
- **Multi-level linking.** §14 adds single-hop linking (an importer splicing in one precompiled leaf module); a linked module transitively linking *another* linked module is out of scope — enforced at write time, not just left undefined.
- **Transparent/implicit linking.** §14.2: an import only resolves to a precompiled artifact when the specifier names one explicitly. No same-stem-sibling cache fallback.
- **Streaming loading.** The body checksum must be verified before any section is parsed.
- **Partial cache hits.** Failing any validation check invalidates the entire artifact.
- **Automatic cache management.** The format specifies validation, not storage location or eviction policy.
- **Authentication.** The body checksum detects corruption, not tampering. Authenticating artifact provenance is a host responsibility.
- **Tagged integer bounds.** Range bounds are `f64` in v1. Exact integer bounds above 2^53 are a v2 concern.

---

## 17. Rationale Notes

**Why SHA-256 for identity hashes and xxHash64 for the body checksum?**
SHA-256 for `source_graph_hash`, `vm_fingerprint`, `module_provider_hash`, and `options_hash` because these are cache keys that must be collision-resistant — a collision would silently accept a stale artifact. xxHash64 for the body checksum because its purpose is corruption detection, not adversarial resistance, and it is significantly faster to compute over large bodies.

**Why not timestamps for cache invalidation?**
Timestamps are unreliable: network filesystems, backups, `touch`, version control operations, and timezone changes all corrupt them. Python's `.pyc` format used timestamps for years and caused debugging pain. Content hashes are definitive.

**Why separate `format_major`/`format_minor` from `language_major`/`language_minor`?**
The bytecode format can be stable across multiple language minor versions, and an internal VM optimisation (e.g., a new fused opcode) may require a format bump without any user-visible language change. Independent versioning prevents unnecessary cache invalidation.

**Why `module_provider_hash` rather than `stdlib_hash`?**
"stdlib" is too narrow. Once host providers, virtual modules, or separately versioned builtins exist, a field named `stdlib_hash` would become a misnomer. `module_provider_hash` is abstract enough to cover stdlib, host ABI declarations, and any future module registry without a field rename that would require a header version bump.

**Why `header_size`?**
A fixed-size header cannot be extended without a breaking format change. With `header_size`, new fields can be appended. The cost is two bytes. The cost of omitting it is a permanently frozen header.

**Why symbolic native IDs rather than numeric ones?**
The VM currently stores native functions as `NativeFuncObj { id: u8 }`. Reordering the native table — even without changing any individual function's ABI — would silently corrupt all stored numeric IDs. Symbolic IDs make the dependency explicit and give the loader a chance to detect and report the problem rather than silently calling the wrong function.

**Why not raw Zig struct serialisation?**
Zig struct layout is not guaranteed across compiler versions, targets, or compilation flags. Field padding and ordering are implementation details. An explicit canonical encoding defined here remains stable regardless of the Zig compiler version used to build the runtime.

**Why `bytecode_length` in FUNCTIONS?**
Without it, determining where a function's instructions end requires inferring from surrounding entries, which is fragile and fails for non-sorted tables. An explicit length makes each function entry self-describing and enables a validator to check that all function ranges lie within the BYTECODE section.

**Why `resolved_id` in DEPENDENCY\_TABLE?**
The written specifier (`./math`, `../lib/math`, symlinked paths) is not a stable canonical identity. Two different written specifiers can resolve to the same module; the same written specifier in different compilation contexts can resolve to different modules. Canonical identity is established by the resolver at compile time and must be recorded explicitly so the loader can validate it without re-running resolution.

**Why remove the `CHECKED_ARITHMETIC`/`OPTIMISED` mutual exclusion from the format?**
Build modes are policy decisions for the compiler tool, not invariants that the file format should enforce. The format records what flags were active; it does not constrain which flag combinations are meaningful. A future build mode that combines checked arithmetic with optimisation should not require a format version bump to accommodate.

**Why not promise that appending a default-valued option preserves the old `options_hash`?**
It is mathematically impossible: appending any bytes to the hash input changes the output. Attempting to preserve old hashes by conditionally omitting default-valued options produces subtle bugs when the "default" changes. The correct approach is to accept that adding an option changes the hash (triggering recompilation) and use the encoding version byte as an explicit migration mechanism if backward compatibility is needed.

**Why is v2 linking explicit-only, not a transparent same-stem cache (§14.2)?**
A transparent fallback ("if `math.gbc` exists next to `math.gengo` and isn't stale, use it") makes program behavior depend on filesystem state the source text never mentions — the same class of surprise a reviewer can't catch by reading the import line. It would also make §14.4's production requirements (no baked-in `halt`, a real `module_id`, no transitive linked deps) into implicit per-file conventions instead of something checked once at the point an artifact is deliberately produced as linkable. Explicit-only makes every link a visible, auditable decision in the source; a transparent-cache mode can be layered on top later once single-hop linking itself is proven, without revisiting this trust boundary.

**Why does `module_id` live in `SEC_EXPORTS` rather than being derived from the importer's specifier?**
The dependency's own compiled bytecode already has its qualified global names baked into string constants at its own compile time, before any importer's specifier for it exists. Renaming those post-hoc on load would mean rewriting deduplicated string-constant bytes throughout the spliced constant pool — a far more invasive and error-prone operation than the integer-index remap linking already needs (§14.5). Carrying the identity forward from the artifact itself sidesteps that entirely: an importer's `written_specifier` is local to the importer and never has to agree with anything baked into the dependency.

**Why is `artifact_body_hash` mandatory for `LINKED_ARTIFACT` but only advisory for other dependency kinds?**
A `FILE` dependency has a fallback: if the source hash doesn't match, recompile from the (still-available) source. A `LINKED_ARTIFACT` dependency has no source to fall back to at load time by construction — the whole point of linking is to skip having source available. So there is no safe "stale but recoverable" state for it: either the body matches exactly, or the artifact must be rejected outright.
