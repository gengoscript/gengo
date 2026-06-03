# Gengo Bytecode Cache — File Format Specification

**Status:** Draft  
**Version:** 0.1  
**Scope:** GBC artifact only (see §2 for artifact class definitions)

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
    - 11.1 [Ordered Checks](#111-ordered-checks)
    - 11.2 [Error Handling](#112-error-handling)
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
| `str` | variable | `u32` byte-length followed by UTF-8 bytes; no null terminator |
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

The magic bytes appear at file offset 0 and are not part of the header. The header begins at offset 8. The body begins at offset `header_size` (as stored in the header). The body checksum in the header covers all bytes from `header_size` to `header_size + body_length - 1`.

---

## 5. Magic Bytes

```
\x89 G N G \r \n \x1a \n
 89  47 4E 47  0D 0A  1A  0A
```

8 bytes, at file offset 0.

The high bit of the first byte (`\x89`) flags this as a binary file and causes rejection by any tool treating it as ASCII text. The `\r\n` sequence (`0D 0A`) followed by `\n` (`0A`) is designed to detect line-ending mangling: any text-mode copy operation that converts `\r\n` to `\n` or `\n` to `\r\n` will corrupt this pattern and be caught on load. The `\x1a` is the MS-DOS end-of-file marker; its presence prevents some tools from reading the file as text. This design is borrowed from PNG.

A loader must reject any file whose first 8 bytes do not exactly match this sequence.

---

## 6. Header

The header begins at file offset 8. Its size is given by the `header_size` field at offset 8. The header includes the `header_size` field itself.

A loader that reads a header with `header_size` larger than it knows about must skip the unknown trailing bytes rather than rejecting the file, unless `header_version` indicates a breaking change. A loader that reads a header with `header_size` smaller than the current layout must treat all missing fields as having their defined default values (typically zero).

### 6.1 Field Definitions

| File offset | Header offset | Size | Type | Field | Description |
|-------------|---------------|------|------|-------|-------------|
| 8 | 0 | 2 | `u16` | `header_size` | Total header size in bytes including this field. Current value: 192. |
| 10 | 2 | 2 | `u16` | `header_version` | Version of this header layout. Current value: 1. |
| 12 | 4 | 2 | `u16` | `format_major` | Bytecode format major version. |
| 14 | 6 | 2 | `u16` | `format_minor` | Bytecode format minor version. |
| 16 | 8 | 2 | `u16` | `language_major` | Gengo language major version. |
| 18 | 10 | 2 | `u16` | `language_minor` | Gengo language minor version. |
| 20 | 12 | 4 | `u32` | `flags` | Compilation flags bitfield. See §6.2. |
| 24 | 16 | 4 | `u32` | `target_id` | Target platform identifier. See §6.3. |
| 28 | 20 | 4 | `u32` | `backend_id` | Bytecode backend identifier. See §6.4. |
| 32 | 24 | 2 | `u16` | `entry_kind` | Entry kind of this artifact. See §6.5. |
| 34 | 26 | 6 | — | `_reserved` | Must be zero. Reject if nonzero on load. |
| 40 | 32 | 8 | `i64` | `compiled_at` | Unix timestamp (seconds) of compilation. Debug and logging only. Never used for cache invalidation. |
| 48 | 40 | 32 | `hash32` | `source_graph_hash` | SHA-256 of the source graph. See §6.6. |
| 80 | 72 | 32 | `hash32` | `vm_fingerprint` | SHA-256 identifying the runtime VM. See §6.6. |
| 112 | 104 | 32 | `hash32` | `stdlib_hash` | SHA-256 identifying the stdlib/module-provider. See §6.6. |
| 144 | 136 | 32 | `hash32` | `options_hash` | SHA-256 of the canonical compiler options. See §6.6. |
| 176 | 168 | 8 | `u64` | `body_length` | Length of the body in bytes. |
| 184 | 176 | 8 | `u64` | `body_checksum` | xxHash64 of the body bytes. |

Total defined header size: **192 bytes** (file offset 8 through 199 inclusive).

### 6.2 Flags Bitfield

| Bit | Mask | Name | Description |
|-----|------|------|-------------|
| 0 | `0x0001` | `DEBUG_INFO` | DEBUG\_SPANS and/or DEBUG\_NAMES sections are present. |
| 1 | `0x0002` | `CHECKED_ARITHMETIC` | Range constraint checks are enabled (dev/checked mode). |
| 2 | `0x0004` | `OPTIMISED` | Compiled with optimisation enabled (release mode). |
| 3–31 | — | `RESERVED` | Must be zero. Reject if any reserved bit is set. |

`CHECKED_ARITHMETIC` and `OPTIMISED` must not both be set simultaneously.

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
| `0x0001` | `ENTRY_SCRIPT` | Top-level script. No explicit exports. Globals are file-private. |
| `0x0002` | `ENTRY_MODULE` | Module artifact. Has an EXPORTS section. Importable by other modules. |
| `0x0003` | `ENTRY_REPL_CELL` | REPL fragment. Depends on ambient REPL state; not independently loadable. |
| `0x0004` | `ENTRY_TEST` | Test artifact. |

### 6.6 Hash Fields

**`source_graph_hash`**

For a single-file source with no non-stdlib imports:
```
source_graph_hash = SHA-256(source_text_utf8)
```

For a source that imports other files (once file imports are implemented):
```
source_graph_hash = SHA-256(
  root_source_text_utf8 ||
  for each resolved import in topological order:
    resolved_specifier_utf8 || SHA-256(dependency_source_text_utf8)
)
```

The stdlib is not included in `source_graph_hash` because it is covered by `stdlib_hash`. The hashing order is canonical (topological, stable) and must not depend on filesystem ordering or discovery order.

**`vm_fingerprint`**

For WASM32\_WASI targets, this is `SHA-256(gengo-runtime.wasm)` — the same hash computed by `playground/deploy.sh`. For other targets, it is a build-ID or host-supplied ABI fingerprint agreed upon between compiler and loader.

The vm\_fingerprint must change whenever the bytecode instruction set changes, the opcode encoding changes, the native function binding table changes, or any other change would cause existing bytecode to execute differently.

**`stdlib_hash`**

When the stdlib is compiled into the runtime binary (current state), set `stdlib_hash` to the same value as `vm_fingerprint`. When the stdlib ships as a separate module provider, set `stdlib_hash` to `SHA-256(stdlib_binary)` independently.

**`options_hash`**

SHA-256 of a canonical encoding of all compiler options that affect code generation. The canonical encoding is:

```
options_hash = SHA-256(
  u8(target_id) ||
  u8(backend_id) ||
  u8(1 if CHECKED_ARITHMETIC else 0) ||
  u8(1 if OPTIMISED else 0)
  [... additional options appended as they are added ...]
)
```

The canonical encoding must be appended to, never reordered. New options are appended with a defined default value that preserves the hash of existing option sets if the new option is at its default.

---

## 7. Body Structure

The body begins at file byte offset `header_size` and is exactly `body_length` bytes long. The body checksum in the header must equal `xxHash64(body_bytes)` before any further parsing.

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

Section data begins at `body_start + entry.offset`. Sections may appear in any order. The section table itself has no minimum ordering requirement, but by convention sections are written in the order listed in §7.2.

Offsets must not overlap. A loader must reject a file where any two sections have overlapping byte ranges.

### 7.2 Section Identifiers

| `section_id` | Constant | Required | Description |
|--------------|----------|----------|-------------|
| `0x0001` | `SEC_BYTECODE` | Yes | Raw instruction stream. |
| `0x0002` | `SEC_CONSTANTS` | Yes | Constant pool. |
| `0x0003` | `SEC_FUNCTIONS` | Yes | Function metadata table. |
| `0x0004` | `SEC_NATIVE_IMPORTS` | Yes | Native function binding declarations. |
| `0x0005` | `SEC_EXPORTS` | MODULE only | Exported name table. |
| `0x0006` | `SEC_TYPES` | Yes | Type definitions (struct, named, enum, interface, variant). |
| `0x0007` | `SEC_DEPENDENCY_TABLE` | Yes | Import specifiers and dependency hashes. |
| `0x0100` | `SEC_DEBUG_SPANS` | No | Source location spans for each instruction. |
| `0x0101` | `SEC_DEBUG_NAMES` | No | Variable and local names for debugging. |
| `0x8000`–`0xFFFF` | Vendor | No | Vendor or extension sections. |

### 7.3 Required vs Optional Sections

The `flags` field of each `SectionEntry` controls handling of unknown sections:

| Bit | Name | Description |
|-----|------|-------------|
| 0 | `REQUIRED` | Loader must reject if it does not understand this section. |

If `REQUIRED` is not set and the loader does not recognise `section_id`, it must skip the section silently. This enables forward-compatible extensions.

All sections in §7.2 marked "Yes" must be present with `REQUIRED` set. A loader must reject a file missing any required section.

---

## 8. Section Formats

### 8.1 BYTECODE

The raw instruction stream as emitted by the compiler. This is an opaque byte sequence from the perspective of the format; its interpretation is defined by the bytecode instruction set reference for the `format_major`/`format_minor` version pair.

```
bytecode_bytes : [section.length]u8
```

No wrapper. The section length equals the number of instruction bytes.

Function entries in SEC\_FUNCTIONS reference byte offsets into this section.

### 8.2 CONSTANTS

The constant pool. Each constant is prefixed by a tag byte.

```
constant_count : u32
constants      : [constant_count]Constant
```

Each `Constant`:

```
Constant {
  tag   : u8
  value : ...  // tag-dependent
}
```

| Tag | Value | Encoding |
|-----|-------|----------|
| `0x01` | Number | `f64` (8 bytes) |
| `0x02` | String | `str` (u32 length + UTF-8 bytes) |
| `0x03` | Null | No value bytes. |

Constants are indexed from 0. Instructions that reference constants by index use `u16` or `u32` indices as specified in the instruction set.

### 8.3 FUNCTIONS

The function metadata table. Each entry describes one compiled function (including closures and anonymous functions).

```
function_count : u32
functions      : [function_count]FunctionEntry
```

Each `FunctionEntry`:

```
FunctionEntry {
  name_constant_idx    : u32    // constant index for string name; 0xFFFFFFFF = anonymous
  bytecode_offset      : u32    // byte offset into BYTECODE section
  arity                : u8
  is_variadic          : bool8
  variadic_type        : TypeSpec
  has_typed_params     : bool8
  has_typed_returns    : bool8
  named_return_count   : u8
  param_type_count     : u16
  param_types          : [param_type_count]TypeSpec
  return_type_count    : u16
  return_types         : [return_type_count]TypeSpec
  capture_slot_count   : u8
  capture_slots        : [capture_slot_count]u8
}
```

Function indices in this table are referenced by the bytecode via the instruction set (e.g., `make_closure` instructions).

### 8.4 NATIVE\_IMPORTS

Declarations of all native (host-provided) functions referenced by this artifact. Native functions must be resolved symbolically at load time; they are never stored as raw function pointers or integer IDs that could become stale.

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

On load, the runtime looks up each `symbolic_id` in the current native function registry. If any declared import is not found, or if `arity` does not match, the load must fail with an explicit error naming the missing binding. The loader must not partially initialise the VM and then attempt to run.

Native import entries are referenced by index from bytecode instructions that invoke native functions. The index in the GBC file may differ from the `NativeFuncObj.id` used internally; the loader builds the mapping table at load time.

**Rationale:** Storing numeric native IDs directly (as currently used in the VM) would make artifacts silently incorrect after any reordering of the native function table. Symbolic IDs make the dependency explicit and detectable.

### 8.5 EXPORTS

Present only for `ENTRY_MODULE` artifacts. Lists the public names this module exports and the qualified global name each refers to.

```
export_count : u32
exports      : [export_count]ExportEntry
```

Each `ExportEntry`:

```
ExportEntry {
  exported_name    : str   // the name importers use
  qualified_name   : str   // the internal qualified global name
}
```

### 8.6 TYPES

All user-defined types declared in this artifact. Serialised before bytecode execution so the runtime can resolve type metadata without running any bytecode.

```
type_count : u32
types      : [type_count]TypeEntry
```

Each `TypeEntry` begins with a kind tag:

```
TypeEntry {
  kind           : u8    // see table below
  name           : str
  qualified_name : str
  // kind-specific fields follow
}
```

| Kind | Value | Description |
|------|-------|-------------|
| `STRUCT` | `0x01` | Struct type |
| `NAMED` | `0x02` | Named scalar type (int, float, string, etc.) |
| `ENUM` | `0x03` | Enum type |
| `INTERFACE` | `0x04` | Interface type |
| `VARIANT` | `0x05` | Variant (tagged union) type |

Kind-specific fields:

**STRUCT** (`0x01`):
```
  field_count : u16
  fields      : [field_count]StructField
```
Each `StructField`: `name : str`, `type : TypeSpec`, `is_const : bool8`

**NAMED** (`0x02`):
```
  base        : u8     // 0=int, 1=float, 2=string, 3=bool, 4=rune, 5=array, 6=map, 7=enum
  has_range   : bool8
  is_cycle    : bool8
  min         : f64    // meaningful only if has_range
  max         : f64    // meaningful only if has_range
  parent_name : str    // empty string if no parent
```

**ENUM** (`0x03`):
```
  member_count : u16
  members      : [member_count]str
  parent_name  : str   // empty if not a subtype
```

**INTERFACE** (`0x04`):
```
  method_count : u16
  methods      : [method_count]InterfaceMethod
```
Each `InterfaceMethod`: `name : str`, `arity : u8`, `is_variadic : bool8`, `variadic_type : TypeSpec`, `param_type_count : u16`, `param_types : [...]TypeSpec`, `return_type_count : u16`, `return_types : [...]TypeSpec`, `has_typed_params : bool8`, `has_typed_returns : bool8`

**VARIANT** (`0x05`):
```
  arm_count : u16
  arms      : [arm_count]VariantArm
```
Each `VariantArm`: `name : str`, `has_payload : bool8`, `payload_name : str`, `payload_type_present : bool8`, `payload_type : TypeSpec` (if present)

### 8.7 DEPENDENCY\_TABLE

Declares all imports made by this source, including their resolved specifiers and source hashes for cache validation.

```
dependency_count : u32
dependencies     : [dependency_count]DependencyEntry
```

Each `DependencyEntry`:

```
DependencyEntry {
  specifier        : str     // as written in source, e.g. "std" or "./math"
  kind             : u8      // 0=STDLIB, 1=FILE, 2=HOST_PROVIDED
  source_hash      : hash32  // SHA-256 of dependency source; all zeros for STDLIB
  qualified_prefix : str     // the prefix used for symbols from this import
}
```

For `STDLIB` dependencies, `source_hash` is all zeros. Stdlib is covered by `stdlib_hash` in the header. For `FILE` dependencies, `source_hash` is `SHA-256(resolved_source_text_utf8)` and must match the hash of the actual file at load time.

If any FILE dependency's actual source hash does not match, the artifact is stale and the root source must be recompiled.

### 8.8 DEBUG\_SPANS (optional)

Maps each bytecode instruction (by byte offset) to a source location. Present only when the `DEBUG_INFO` flag is set.

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

Spans are in ascending `bytecode_offset` order. Not every instruction requires a span entry; a loader looking up a location for offset `X` uses the last span entry with `bytecode_offset <= X`.

### 8.9 DEBUG\_NAMES (optional)

Maps local variable slot indices to human-readable names. Present only when the `DEBUG_INFO` flag is set.

```
scope_count : u32
scopes      : [scope_count]DebugScope
```

Each `DebugScope`:

```
DebugScope {
  function_idx  : u32    // index into FUNCTIONS section
  local_count   : u16
  locals        : [local_count]DebugLocal
}
```

Each `DebugLocal`:

```
DebugLocal {
  slot  : u8
  name  : str
}
```

---

## 9. Type Encoding

### 9.1 TypeSpec

A `TypeSpec` describes a field or parameter type annotation. It is a list of alternatives (union types).

```
TypeSpec {
  alt_count : u8
  alts      : [alt_count]FieldTypeAlt
}
```

### 9.2 FieldTypeAlt

```
FieldTypeAlt {
  tag            : u8    // see table
  struct_name    : str   // tag=STRUCT_T
  interface_name : str   // tag=INTERFACE_T
  named_name     : str   // tag=NAMED_T or VARIANT_T
  // for ARRAY_T: elem_spec present
  elem_spec_present : bool8
  elem_spec         : TypeSpec  // if elem_spec_present
  // for MAP_T: key_spec and val_spec present
  key_spec_present  : bool8
  key_spec          : TypeSpec  // if key_spec_present
  val_spec_present  : bool8
  val_spec          : TypeSpec  // if val_spec_present
  // for FUNC_T: param and return types
  func_param_count  : u16
  func_params       : [func_param_count]TypeSpec
  func_return_count : u16
  func_returns      : [func_return_count]TypeSpec
}
```

Fields that are irrelevant for a given tag are not written. Writers must omit them; readers must not expect them. The tag determines exactly which fields are present.

| Tag | Value | Relevant fields |
|-----|-------|----------------|
| `ANY` | `0x00` | none |
| `NULL_T` | `0x01` | none |
| `INT` | `0x02` | none |
| `FLOAT` | `0x03` | none |
| `RUNE_T` | `0x04` | none |
| `BOOLEAN` | `0x05` | none |
| `STRING` | `0x06` | none |
| `ERROR_T` | `0x07` | none |
| `ARRAY` | `0x08` | `elem_spec_present`, `elem_spec` |
| `MAP` | `0x09` | `key_spec_present`, `key_spec`, `val_spec_present`, `val_spec` |
| `STRUCT_T` | `0x0A` | `struct_name` |
| `INTERFACE_T` | `0x0B` | `interface_name` |
| `NAMED_T` | `0x0C` | `named_name` |
| `VARIANT_T` | `0x0D` | `named_name` |
| `FUNC_T` | `0x0E` | `func_param_count`, `func_params`, `func_return_count`, `func_returns` |

---

## 10. Native Function Resolution

Native functions are referenced by the `NATIVE_IMPORTS` section using stable symbolic identifiers. The current mapping from symbolic ID to internal numeric ID is the responsibility of the loader, not the format.

The canonical symbolic ID format is:

```
<module>.<submodule>.<function>
```

Examples from the current stdlib:
- `std.io.println`
- `std.io.printf`
- `std.core.len`
- `std.core.append`
- `std.conv.to_string`

The loader resolution procedure:

1. For each `NativeImportEntry` in `NATIVE_IMPORTS`:
   a. Look up `symbolic_id` in the current native function registry.
   b. If not found: fail with `NativeBindingNotFound(symbolic_id)`.
   c. If found but `arity` does not match: fail with `NativeArityMismatch(symbolic_id, declared, actual)`.
   d. Record the mapping: GBC native index → runtime native ID.
2. Patch or redirect all bytecode references using this mapping before any execution begins.

If any native binding fails to resolve, the entire load must be aborted. Partial loading is not permitted.

**Do not store internal native function IDs (such as `NativeFuncObj.id : u8`) in GBC files.** These are runtime implementation details that may be renumbered without a format version change. Only symbolic IDs are stable across runtime rebuilds that do not change the function ABI.

---

## 11. Validation Rules

### 11.1 Ordered Checks

A loader must apply these checks in order. On any failure it must abort loading, report the specific failure, and not return a partially initialised VM.

| # | Check | Failure |
|---|-------|---------|
| 1 | Magic bytes match exactly | `InvalidMagic` |
| 2 | `header_size >= 192` and file is at least `header_size` bytes past the magic | `TruncatedHeader` |
| 3 | `header_version == 1` (or within supported range) | `UnsupportedHeaderVersion(n)` |
| 4 | Reserved bytes in header are all zero | `NonZeroReserved` |
| 5 | `format_major` matches loader's supported major | `FormatMajorMismatch(artifact, runtime)` |
| 6 | `format_minor <= loader's format_minor` | `FormatMinorTooNew(artifact, runtime)` |
| 7 | `language_major` matches loader's language major | `LanguageMajorMismatch(artifact, runtime)` |
| 8 | `language_minor <= loader's language_minor` | `LanguageMinorTooNew(artifact, runtime)` |
| 9 | `target_id` is a known value and matches the current runtime target | `TargetMismatch(artifact, runtime)` |
| 10 | `backend_id` is a known value and matches the current runtime backend | `BackendMismatch(artifact, runtime)` |
| 11 | `entry_kind` is a known value | `UnknownEntryKind(n)` |
| 12 | `flags` reserved bits are all zero | `UnknownFlags` |
| 13 | `body_length` bytes are present after the header | `TruncatedBody` |
| 14 | `xxHash64(body_bytes) == body_checksum` | `BodyChecksumMismatch` |
| 15 | `source_graph_hash` matches computed source graph hash | `SourceGraphStale` |
| 16 | `vm_fingerprint` matches current runtime VM fingerprint | `VMFingerprintMismatch` |
| 17 | `stdlib_hash` matches current stdlib fingerprint | `StdlibFingerprintMismatch` |
| 18 | `options_hash` matches current compiler options | `CompilerOptionsMismatch` |
| 19 | All `REQUIRED` sections are present | `MissingRequiredSection(id)` |
| 20 | No two sections have overlapping byte ranges | `SectionOverlap` |
| 21 | All FILE dependency source hashes match on disk | `DependencyStale(specifier)` |
| 22 | All native imports resolve successfully | `NativeBindingNotFound(id)` or `NativeArityMismatch(id, ...)` |

Checks 1–14 are structural integrity checks and must be performed before any content is interpreted. Checks 15–18 are staleness checks and govern cache validity. Checks 19–22 are content validity checks.

### 11.2 Error Handling

On any validation failure:

- Report the specific failure reason (from the table above) with enough context for a human to diagnose the problem.
- Do not attempt to use the artifact partially.
- Do not fall back to "best effort" loading.
- Signal to the caller that recompilation is needed.
- Do not delete the artifact automatically; leave that decision to the caller.

**The `compiled_at` timestamp must never be used as a cache key or for invalidation.** It exists solely for human-readable diagnostic output such as "this cache is N days old."

---

## 12. Version Compatibility Policy

### Format versions (`format_major`, `format_minor`)

- **Major bump**: Any breaking change to the binary layout, instruction encoding, section format, or primitive encoding. A loader must reject artifacts with a different `format_major`.
- **Minor bump**: Backward-compatible addition, such as a new optional section ID or a new optional field appended to an existing section. A loader may load artifacts with `format_minor <= current`. A loader must reject artifacts with `format_minor > current` (features it does not understand may be required).

### Language versions (`language_major`, `language_minor`)

- **Major bump**: Breaking language change. A loader must reject artifacts compiled for a different `language_major`.
- **Minor bump**: Additive language change. A loader may load artifacts with `language_minor <= current`. An artifact compiled for a newer minor than the current runtime must be rejected because it may depend on instructions or type features not yet present.

### Header version (`header_version`)

- Bumped only when the header layout itself changes in a backward-incompatible way.
- Readers should skip unknown trailing bytes (those beyond the known header size) if `header_version` is within a supported range.

---

## 13. Dependency and Module Graph Hashing

The `source_graph_hash` must cover the entire set of source inputs that affected the compiled artifact. Hashing only the root source is insufficient once file imports exist.

**Computation for SCRIPT artifacts with no file imports (current baseline):**
```
source_graph_hash = SHA-256(root_source_utf8_bytes)
```

**Computation once file imports are implemented:**
```
inputs = []
inputs.append(root_source_utf8_bytes)
for each resolved file import in stable topological order:
    inputs.append(utf8(resolved_specifier))
    inputs.append(SHA-256(dependency_source_utf8_bytes))
source_graph_hash = SHA-256(concat(inputs))
```

The topological order must be canonical and not depend on discovery order, filesystem ordering, or any other non-deterministic factor.

Each individual module artifact also stores its own `source_graph_hash` covering only its own source and its own transitive file dependencies. This allows per-module cache invalidation: changing `math.gengo` invalidates only `math.gbc` and the GBC of any module that imports it, not all modules in the project.

---

## 14. Future: GSI Artifact Class

A **Gengo Snapshot Image** (`.gsi`) would contain all of the above plus a serialised representation of the live VM state at a checkpoint: the object heap, the global variable table, initialised type instances, and GC metadata.

The GSI format would reuse the GBC header structure with a different entry kind or magic sequence, and add the following additional sections:

- `SEC_HEAP_SNAPSHOT`: Object pool serialised with pointer swizzling (pointers replaced by pool indices).
- `SEC_GLOBALS_SNAPSHOT`: Snapshot of the global variable table with values serialised as heap pool references or primitive values.
- `SEC_GC_METADATA`: GC generation, root set, finalisers.

Additional header fields would be required:
- `heap_layout_version`: Independent version of the heap serialisation format.
- `gc_generation`: GC generation counter at snapshot time.

Additional open questions that must be resolved before GSI is designed:
- Are native functions at their initialised state or symbolic-only?
- Are open WASI file handles serialisable, or must they be re-opened on load?
- Are interned strings part of the heap snapshot or rebuilt from the constant pool?
- What is the native resource policy for a GSI that contains open resources?
- Can closures capture objects that are not serialisable?

**Do not design GSI until GBC is stable and in production use.** The complexity of GSI is an order of magnitude higher. Premature convergence of the two formats produces a format that does neither job well.

---

## 15. Non-Goals for GBC v1

The following are explicitly out of scope for the current format version:

- **Heap serialisation.** Live object state is not part of GBC.
- **Cross-compilation.** A GBC file produced for `TARGET_WASM32_WASI` is not loadable on `TARGET_NATIVE_X86_64`.
- **Linking.** GBC files are not linkable into larger artifacts in v1. Each artifact is self-contained.
- **Streaming loading.** The body checksum must be verified before any section is parsed. Streaming section parsing before checksum verification is not permitted.
- **Partial invalidation.** If any header check fails, the entire artifact is invalid. There is no partial cache hit.
- **Automatic cache management.** The format specifies how to validate artifacts, not where to store them or how to evict them. Cache location and eviction are host responsibilities.
- **Encryption or signing.** The body checksum is integrity-only, not authentication. Authenticating the source of an artifact is a host responsibility.

---

## 16. Rationale Notes

**Why SHA-256 for identity hashes and xxHash64 for the body checksum?**
SHA-256 for `source_graph_hash`, `vm_fingerprint`, `stdlib_hash`, and `options_hash` because these are cache keys that must be collision-resistant — a collision would cause a stale artifact to be silently accepted. xxHash64 for the body checksum because its purpose is corruption detection, not adversarial resistance, and it is significantly faster to compute over large bodies.

**Why not use timestamps for cache invalidation?**
Timestamps are unreliable: network filesystems, backups, `touch`, version control operations, and timezone changes all produce incorrect timestamps. Python's `.pyc` format used timestamps for decades and caused persistent debugging confusion. Content hashes are definitive.

**Why a separate `format_major`/`format_minor` distinct from `language_major`/`language_minor`?**
The bytecode format can remain stable across multiple language minor versions. Conversely, an internal VM optimisation (e.g., adding a new fused opcode) requires a format bump without any user-visible language change. Keeping them independent prevents unnecessary cache invalidation.

**Why `header_size`?**
A fixed-size header cannot be extended without a breaking format change. With `header_size`, new fields can be appended and older readers can skip them (for backward-compatible additions) or reject cleanly (for breaking additions signalled by `header_version`). The cost is two bytes. The cost of omitting it is a locked header forever.

**Why symbolic native IDs rather than numeric ones?**
The current VM stores native functions as `NativeFuncObj { id: u8, arity: u8 }`. If the native function table is reordered — even without changing the ABI of any individual function — all stored numeric IDs become wrong. Since `vm_fingerprint` changes on any runtime rebuild, this is currently safe: stale numeric IDs are rejected before they can cause incorrect behaviour. However, symbolic IDs allow the runtime to reorder its internal table without a `vm_fingerprint` change, reducing unnecessary cache invalidation in the future.

**Why not raw Zig struct serialisation?**
Zig struct layout is not guaranteed across compiler versions, target architectures, or even across different compilation flags. Field padding, alignment, and order are implementation details. Defining an explicit canonical encoding in this document means the format is stable independent of the Zig compiler version used to build the runtime.
