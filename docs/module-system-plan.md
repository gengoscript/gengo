# gengo Source Module System Plan

## Goal

Add first-class source-file modules without treating modules as dynamic maps.

The intended model is:
- every source file is an implicit namespace
- that namespace behaves like a struct instance
- `pub` marks the declarations exported by that file
- `import("./path")` returns the cached module struct instance
- native filesystem loading is supported for the CLI
- WASM loading is supported through an optional source provider or preloaded sources

This is a gengo-native module design.

## Current State

Today, only `import("std")` is supported.

Current implementation shape:
- `import("std")` compiles to a dedicated `import_std` opcode.
- `std` is currently exposed as a module map.
- non-`std` imports are rejected at compile time.
- top-level declarations compile into one flat global namespace.
- globals use `get_global`, `set_global`, and `def_global`.
- struct field access already has stronger semantics and better caching than map lookup.

The module work should not be implemented by source splicing. It needs a module graph and module-aware symbol names.

## Desired User Semantics

Given:

```gengo
// math.gengo
pub fn add(a, b) {
    return a + b
}

fn helper() {
    return 123
}

pub const version := "1.0"
```

Usage:

```gengo
std := import("std")
math := import("./math")

std.io.println(math.add(1, 2))
std.io.println(math.version)
```

Invalid:

```gengo
math.helper()
math.version = "2.0"
```

`helper` is private to `math.gengo`.
`version` is exported, but the module namespace field is const.

Conceptually, `math.gengo` behaves like:

```gengo
const math = struct {
    pub const add = <function add>
    pub const version = "1.0"
}
```

The `struct { ... }` wrapper is implicit and file-local.

## Module Objects

Imported source modules should be represented as `struct_instance`, not `map`.

Each module gets a synthetic struct type:
- internal type name: stable module-qualified name, for example `@mod:/abs/path/math.gengo`
- display name: friendly basename or import alias, for example `math`
- fields: one const field for each public declaration
- field type: initially `any`

Example export struct:

```text
@mod:/abs/path/math.gengo {
    const add any
    const version any
}
```

Reasons to use structs:
- fixed public export set
- unknown export gives a struct-field error instead of map-miss behavior
- existing struct field inline caches can accelerate `module.symbol`
- const fields prevent accidental namespace mutation
- this matches the Zig-style "file is a struct" mental model

The initial implementation should use `any` export fields. Richer export field types can be added later if the compiler gains enough type information to make that useful.

## Visibility

Add `pub` as a declaration modifier.

Allowed:
- `pub fn name(...) { ... }`
- `pub const name := expr`
- `pub type Name struct { ... }`
- `pub type Name int`
- `pub type Name enum { ... }`
- `pub type Name variant { ... }`
- `pub type Name interface { ... }`

Private by default:
- unmarked top-level declarations are visible only inside their source file
- private declarations are not fields on the module struct

Recommended first rule:
- module struct fields are always const
- `pub var` should either be rejected initially or exported as a const binding to the current value
- avoid externally mutable module namespaces

Interior mutability is still normal:
- exporting an array/map/struct value does not freeze the object
- only reassignment of the module field is forbidden

## Import Syntax

Keep `import(...)` as the import expression.

Supported forms:
- `import("std")`
- `import("./math")`
- `import("./math.gengo")`
- `import("./pkg")`

Resolution order for relative imports:
1. exact path
2. path plus `.gengo`
3. path plus `/mod.gengo`

Examples:
- `import("./math")` resolves to `./math.gengo`
- `import("./pkg")` resolves to `./pkg/mod.gengo`

Do not require file extensions in user code.

Non-relative imports:
- `std` remains special-cased for now
- future package/module roots can be added later
- reject unknown bare imports with a clear compile error

## Canonical Paths And Caching

Every loaded source module needs a canonical module key.

Native CLI canonicalization:
- resolve relative paths from the importing file's directory
- normalize `.` and `..`
- prefer absolute canonical filesystem paths when available

WASM canonicalization:
- use host-provided logical paths
- normalize `.` and `..`
- do not require host filesystem access

Module execution:
- each module executes at most once per runtime compilation
- repeated imports return the same module struct instance
- cyclic imports must be detected before execution

Cycle handling:
- start with a compile-time `ImportCycle` error
- do not implement partially initialized modules in the first version

## Internal Symbol Names

The compiler needs module-qualified internal names.

Example:

```gengo
// a/math.gengo
pub fn add(a, b) { return a + b }
fn helper() { return 1 }
```

Internal names:

```text
@mod:/abs/a/math.gengo.add
@mod:/abs/a/math.gengo.helper
```

The public module struct field is named `add`, but the function object/global can still use the fully qualified internal name.

This avoids collisions between:

```text
./a/math.gengo.add
./b/math.gengo.add
```

## Struct Type Names And Methods

The existing method lookup path must be handled carefully.

If method dispatch keys are based on:

```text
StructTypeName.methodName
```

then module support must prevent collisions between same-named types in different modules.

Required rule:
- internal struct type names must be module-qualified
- diagnostics/printing may use a separate display name later

Example:

```text
internal type: @mod:/abs/geo.gengo.Point
display name: Point
method key: @mod:/abs/geo.gengo.Point.distance
```

First implementation options:
1. use qualified type names everywhere internally, accepting uglier debug printing temporarily
2. add `display_name` to struct type objects so runtime lookup uses the internal name and printing uses the display name

Option 1 is simpler.
Option 2 is cleaner for user-facing output.

Private methods are harder than private functions because current method lookup is runtime/global based.

Recommended first rule:
- methods on public types should be public only when declared `pub`
- private methods should be callable only inside their defining module
- implementing this cleanly likely requires method keys to include module context or compiler-side resolution for private method calls

If that is too large for phase one, document a temporary restriction:
- all methods on exported types are exported
- private methods on exported types are rejected until method visibility is implemented

## Compiler Architecture

Add a module graph layer above the current compiler.

Do not splice imported source text into the importer.

Suggested new pieces:
- `SourceProvider`
- `ModuleLoader`
- `ModuleInfo`
- `ModuleRegistry`
- module-aware compiler context

`SourceProvider`:
- resolves and reads module source bytes
- native implementation reads files
- WASM implementation reads preloaded source buffers or rejects unsupported imports

`ModuleLoader`:
- resolves imports
- builds dependency graph
- detects cycles
- caches compiled modules
- assigns module ids

`ModuleInfo`:
- canonical path/key
- display name
- source bytes
- import state: loading, loaded, compiled
- internal prefix
- public export table

`ModuleRegistry`:
- maps canonical module key to `ModuleInfo`
- maps module id to synthetic module struct type
- maps import expression sites to module ids or module values

Compiler context additions:
- current module id
- current module internal prefix
- current source path for diagnostics/import resolution
- export collector
- symbol resolver

## Symbol Resolution

Within a source file:
- unqualified top-level references first check locals/upvalues
- if not local, resolve against the current module's top-level symbols
- emit qualified global access for module top-level symbols

Across files:
- imported modules are normal values
- access is via dot lookup on the module struct instance
- no unqualified cross-module symbol access

Example:

```gengo
math := import("./math")
math.add(1, 2)
```

Compilation:
- `import("./math")` loads/returns module instance
- `math` is a local/global binding in the importer
- `math.add` emits ordinary field access

## Bytecode Strategy

Phase one can avoid a large bytecode rewrite.

Recommended strategy:
- compile all modules into the same chunk for one program
- use module-qualified global names internally
- generate module initialization code before importer execution
- define one global per module instance using an internal module name

Module initialization order:
1. topologically sort modules by dependency
2. compile and emit dependency module declarations first
3. build each dependency module struct instance
4. compile importer

For import expressions:
- `import("std")` keeps current behavior initially
- source module imports emit a load of the cached module instance

Possible implementation choices:
1. emit `get_global @module-instance-key`
2. add `import_module <module-id>` opcode

Recommendation:
- start with `get_global @module-instance-key`
- add a dedicated opcode only if profiling or semantics need it

## Building Module Struct Instances

After compiling a module's top-level public declarations:
1. create synthetic struct type object with fields for public exports
2. push the struct type
3. push every public export value in field order
4. emit `build_struct_instance`
5. define global `@module-instance-key`

Important:
- field order must be deterministic
- duplicate public export names are compile errors
- module field names are user-facing names, not qualified names

Export value examples:
- public function: function/closure value
- public struct type: struct type object
- public enum type: enum type object
- public constant: evaluated constant value

## Standard Library Migration

`std` can remain special during phase one.

There are two reasonable long-term options:
1. keep `std` as a native module object but represent it as structs instead of maps
2. rewrite `std` as synthetic source-like module structs

Recommended path:
- first implement source modules
- then migrate `std` from map namespaces to struct namespaces if practical

This avoids mixing two separate changes in one risky patch.

## WASM And Embedding

WASM should not force filesystem module loading.

Add an abstract source-provider contract:

```text
resolve(importer_key, import_string) -> module_key
load(module_key) -> source bytes
```

Native CLI:
- source provider reads files
- relative imports are resolved from importer directory

WASM:
- default provider supports only `std`
- optional provider supports preloaded source modules by logical path
- host embedding API can pass `{ path, source }` entries

This keeps sandboxed execution simple while allowing multi-file programs when the host explicitly provides sources.

## Diagnostics

Add specific compile errors:
- `UnsupportedImportModule`
- `ImportPathTooLong`
- `ImportNotFound`
- `ImportCycle`
- `DuplicateExport`
- `PrivateSymbolAccess`
- `InvalidPubTarget`
- `ModuleLimitExceeded`

Diagnostics should include:
- importing file path
- import string
- resolved candidate paths where relevant
- cycle chain for `ImportCycle`

Example cycle diagnostic:

```text
ImportCycle: ./a.gengo -> ./b.gengo -> ./a.gengo
```

## Limits

Because gengo uses fixed-size runtime structures, module support should define explicit caps.

Suggested initial caps:
- max modules: 64
- max imports per module: 64
- max exports per module: 128
- max canonical path bytes: 256
- max module graph depth: 64

These should be tied to presets if needed.

## Tests

Add conformance examples.

Passing cases:
- import without extension
- import exact `.gengo`
- import directory `mod.gengo`
- repeated import returns same module instance
- public function export
- public const export
- public type export
- private helper used by public function
- same symbol name in two different modules
- same struct type name in two different modules
- method call on imported public type
- nested imports

Failing cases:
- unknown import path
- unsupported bare import
- import cycle
- access private function through module object
- mutate module export field
- duplicate public export name
- `pub` on invalid syntax
- private method restriction, if adopted

WASM/embedding cases:
- default WASM rejects source imports cleanly
- preloaded source provider supports source imports
- native CLI and embedding provider produce identical behavior for same module graph

Performance cases:
- hot imported function call
- hot imported const read
- hot imported struct type construction
- repeated import in loop
- module field access benchmark compared to map namespace access

## Rollout Plan

### Phase 1: Parser And Token Support

Tasks:
- add `pub` token and lexer keyword
- parse optional `pub` before top-level declarations
- reject `pub` outside valid declaration positions
- record public/private visibility on declaration metadata
- add syntax tests

No import loading changes in this phase.

### Phase 2: Module Loader Skeleton

Tasks:
- add `SourceProvider` abstraction
- add native filesystem provider
- add module path resolution
- add module registry/cache
- add import graph cycle detection
- keep non-`std` imports rejected until compiler integration is ready
- add loader unit tests where possible

### Phase 3: Module-Aware Compiler Context

Tasks:
- add current module context to compiler
- qualify top-level internal symbol names
- collect public exports
- preserve existing single-file behavior by compiling the main file as the root module
- update global lookup/definition emission to use qualified names for top-level module declarations
- test same-named declarations in different modules

### Phase 4: Compile Source Imports

Tasks:
- make `import("./x")` call the module loader
- compile dependency modules before importers
- generate module instance globals
- compile import expressions to load cached module instances
- keep `import("std")` behavior unchanged
- add passing/failing import tests

### Phase 5: Synthetic Module Structs

Tasks:
- generate synthetic struct type objects for modules
- field list is public exports only
- fields are `const any`
- build module struct instances deterministically
- ensure unknown export access uses normal struct-field error behavior
- ensure field assignment fails with `AssignToConst`
- add benchmarks for module field access

### Phase 6: Type And Method Collision Fixes

Tasks:
- qualify internal type names by module
- decide whether to add display names for user-facing printing
- update method keys to use qualified type names
- define and test method visibility rules
- test same-named types and methods across modules

### Phase 7: WASM And Embedding Support

Tasks:
- add preloaded-source provider for embedding
- document default WASM behavior for source imports
- add embedding API shape for module sources
- add host parity tests if relevant

### Phase 8: Standard Library Struct Migration

Tasks:
- decide whether `std` should become struct-backed
- migrate `std.io`, `std.core`, and other namespaces from maps to synthetic structs
- update docs from "module map" to "module struct"
- benchmark std namespace access

## Non-Goals For First Version

- package manager
- remote imports
- partially initialized cyclic modules
- implicit global imports from dependencies
- wildcard imports
- re-export syntax
- public/private enforcement for every method edge case unless method dispatch is redesigned in the same patch
- static export field typing beyond `any`

## Recommended First Milestone

The smallest complete milestone should be:
- `pub` keyword
- native CLI relative source imports
- no extension required
- `mod.gengo` directory imports
- source module object is a const synthetic struct instance
- repeated imports are cached
- import cycles are rejected
- private declarations are not externally accessible
- `std` remains as-is

That gives the desired source-file-as-struct model without forcing a full stdlib or method-system rewrite in the same step.
