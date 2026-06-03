# Gengo Bytecode Cache — File Format Specification

**Status:** Draft  
**Version:** 0.4  
**Scope:** GBC artifact only (see §2 for artifact class definitions)

**Revision history**
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
14. [Future: GSI Artifact Class](#14-future-gsi-artifact-class)
15. [Non-Goals for GBC v1](#15-non-goals-for-gbc-v1)
16. [Rationale Notes](#16-rationale-notes)

---

## 1. Purpose and Scope

A GBC file is a **compiled module artifact**. It answers one question:

> Can parsing, type-checking, and code generation be skipped for this source input under this runtime?

A GBC file contains the bytecode, constant pool, function table, type metadata, import/export declarations, and optional debug information produced by the Gengo compiler. It does not contain live heap state, open resources, or VM execution state.

Loading a valid GBC file into a fresh VM must be equivalent to compiling the original source under the same conditions. No observable behaviour may differ.

### What a GBC file is not

A GBC file is not a **snapshot** of a running VM. Serialising the live object heap, global variable values, open file handles, allocator state, or GC metadata is explicitly out of scope for this format. That is a separate artifact class (§14).

### Script vs module philosophy

The intent is that every Gengo source file is module-shaped. An `ENTRY_SCRIPT` artifact is a module that also carries executable top-level code — it is not a fundamentally different kind of entity. The distinction is operational (how the host runs it) rather than structural (what the artifact contains). Future versions of this format should converge `ENTRY_SCRIPT` and `ENTRY_MODULE`: a script is a module with an entrypoint, and a module with public declarations is importable regardless of whether it also has a top-level body.

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
| 8 | 0 | 2 | `u16` | `header_size` | Total header size in bytes. Current minimum for `header_version` 1: 192. |
| 10 | 2 | 2 | `u16` | `header_version` | Version of this header layout. Current value: 1. |
| 12 | 4 | 2 | `u16` | `format_major` | Bytecode format major version. |
| 14 | 6 | 2 | `u16` | `format_minor` | Bytecode format minor version. |
| 16 | 8 | 2 | `u16` | `language_major` | Gengo language major version. |
| 18 | 10 | 2 | `u16` | `language_minor` | Gengo language minor version. |
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

Total defined header size for `header_version` 1: **192 bytes** (file offsets 8–199 inclusive).

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
| `0x0001` | `BACKEND_BYTEVM` | Register-based bytecode interpreter (current). |

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

For `TARGET_WASM32_WASI`: `SHA-256(gengo-runtime.wasm)` — the same hash computed by `playground/deploy.sh`.

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
| `NUMBER` | `0x01` | `f64` | IEEE 754 double. |
| `STRING` | `0x02` | `str` | UTF-8 string. |
| `NULL` | `0x03` | — | No data bytes. |
| `BOOL` | `0x04` | `bool8` | Boolean value. |
| `RUNE` | `0x05` | `u32` | Unicode code point (0–0x10FFFF). Reject values outside this range. |

> **Reserved tag `INT` (`0x06`, `i64`):** Not used in v1 — the current VM represents all numbers as `f64` internally. This tag is reserved for a future format version when the VM gains a distinct integer representation. Writers must not emit it; loaders must reject it.

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
export_count : u32
exports      : [export_count]ExportEntry
```

Each `ExportEntry`:

```
ExportEntry {
  exported_name  : str   // the name importers use
  qualified_name : str   // the internal qualified global name
}
```

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
base        : u8      // 0=int 1=float 2=string 3=bool 4=rune 5=array 6=map 7=enum_t
has_range   : bool8
is_cycle    : bool8
min         : f64     // present only if has_range; see note below
max         : f64     // present only if has_range; see note below
parent_name : str     // empty if not a subtype
```

> **v1 limitation:** Range bounds are stored as `f64` regardless of whether the base type is integer or float. This matches the current VM's internal representation but loses exact representation for integers whose absolute value exceeds 2^53. A future format version should introduce a tagged `Bound` encoding. Until then, implementations must not define integer-typed named types with range bounds outside ±2^53, and loaders should reject such artifacts.

**ENUM** (`0x03`) — after common fields:
```
member_count : u16
members      : [member_count]str
parent_name  : str   // empty if not a subtype
```

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
arm_count : u16
arms      : [arm_count]VariantArm
```
Each `VariantArm`:
```
VariantArm {
  name              : str
  has_payload       : bool8
  payload_name      : str        // present only if has_payload
  payload_type      : TypeSpec   // present only if has_payload
}
```

### 8.7 DEPENDENCY\_TABLE

Declares the **direct** imports made by this source — those that appear explicitly in the source text — with both the written specifier and its canonical resolved identity. Transitive dependencies are not listed here; their identity is captured through `source_graph_hash` in the header and through the dependency artifacts' own `DEPENDENCY_TABLE` sections.

```
dependency_count : u32
dependencies     : [dependency_count]DependencyEntry
```

Each `DependencyEntry`:

```
DependencyEntry {
  written_specifier : str      // as it appears in source, e.g. "std" or "./math"
  resolved_id       : str      // canonical module identity; see below
  kind              : u8       // 0=STDLIB 1=FILE 2=HOST_PROVIDED
  source_hash       : hash32   // SHA-256 of dependency source; all zeros for STDLIB
  artifact_body_hash     : hash32   // SHA-256 of dependency's GBC artifact; all zeros if unavailable
  qualified_prefix  : str      // prefix used for symbols from this import in the compiled output
}
```

**`resolved_id`** is the canonical identity of the dependency as determined by the module resolver at compile time. It must be stable across equivalent resolutions (symlinks, `../` normalisations, etc. must all produce the same `resolved_id` for the same logical module). Suggested URI-style format:

| Kind | Example `resolved_id` |
|------|----------------------|
| STDLIB | `std://io`, `std://core` |
| File (WASI) | `file:///project/src/math.gengo` |
| File (browser/virtual FS) | `mem://playground/math.gengo` |
| Host-provided | `host://app/config` |

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
| 4 | `header_size >= 192` (minimum for `header_version` 1) | `HeaderTooSmall` |
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
| 21 | For each FILE dependency: `SHA-256(current_source) == entry.source_hash` | `DependencyStale(resolved_id)` |
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

## 14. Future: GSI Artifact Class

A **Gengo Snapshot Image** (`.gsi`) would contain all GBC content plus a serialised representation of live VM state at a checkpoint. The GSI format would reuse the GBC header with a different entry kind or a distinct magic sequence, and add sections for:

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

## 15. Non-Goals for GBC v1

- **Heap serialisation.** Live VM state is not part of GBC.
- **Cross-compilation.** A `TARGET_WASM32_WASI` artifact is not loadable as `TARGET_NATIVE_X86_64`.
- **Linking.** GBC files are not linkable in v1. Each artifact is self-contained.
- **Streaming loading.** The body checksum must be verified before any section is parsed.
- **Partial cache hits.** Failing any validation check invalidates the entire artifact.
- **Automatic cache management.** The format specifies validation, not storage location or eviction policy.
- **Authentication.** The body checksum detects corruption, not tampering. Authenticating artifact provenance is a host responsibility.
- **Tagged integer bounds.** Range bounds are `f64` in v1. Exact integer bounds above 2^53 are a v2 concern.

---

## 16. Rationale Notes

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
