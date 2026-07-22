# Gengo Compiler Architecture

This document describes the compiler at a conceptual level: what its moving parts are, how source text becomes bytecode, and what invariants hold along the way. It is the compiler-side companion to `vm-architecture.md`, which picks up where this document ends — a correct, semantically-checked `chunk.State` ready for the load-time fusion pass and execution.

---

## 1. Overview

Gengo's compiler is a **genuine single-pass Pratt/recursive-descent compiler with no separate AST**. There is no intermediate tree, no separate "resolve" or "codegen" phase over nodes — parsing a construct *is* emitting its bytecode. Every parse function (`expr`, `stmt`, `decl`, `varDecl`, `ifStmt`, `structDeclBody`, ...) calls straight into `chunk.State`'s `emit*` methods as it consumes tokens.

This single-pass design is why two lightweight **lexical pre-scans**, confined to `module_compile.zig`, exist ahead of the real compile pass — they give the one-pass compiler information a multi-pass compiler would get for free from an earlier phase:

- **`Session.compileDependencies`** pulls `import(...)` statements out of the source with a lex-only scan to build the module dependency graph, and compiles dependencies (recursively, DFS, with cycle detection) *before* the importing module itself compiles. This gives imports a uniform, well-defined compile-time resolution order.
- **`Session.scanGlobalDeclarations`** is another lex-only scan (a `Lexer` cursor tracking brace depth, not a real parse) that harvests every top-level `func`/`const`/`var`/`type`/`subtype`/`:=` name into `known_globals`. This is what lets a **forward reference** to a function or global declared later in the same file type-check without a full symbol-table pass.

So cross-module ordering and forward-reference validation are handled by cheap token-level pre-scans, while compiling any single module remains a genuine single pass straight from tokens to bytecode.

**Call flow**: `Session.compileRoot` → `compileDependencies` (imports first) → `compileBegunModule`, which runs `scanGlobalDeclarations`, constructs a fresh `Compiler.init(...)`, and calls `compiler.compile(emit_halt)`. `compile()` primes the lexer and loops `while (!self.check(.eof)) { try self.decl(); }`. `decl()` is the top-level dispatcher (pub/test/var/const/type/subtype/method/func/statement); everything downstream — declarations, statements, expressions — is reached from that one loop.

Each module gets its **own fresh `Compiler`** (own `TypeRegistry`, own scope stack). There is no shared/merged cross-module registry; cross-module type/constant knowledge flows through explicit callback indirection into the `Session` instead (§9).

**No error recovery, no panic mode.** There is no synchronization-to-next-statement-boundary logic anywhere in `src/lang`. `Compiler.setErr` populates an error-message buffer and returns a Zig error, which propagates via `try` all the way out of `compile()`, aborting the whole module's compilation on the first error. This is a deliberate simplicity trade — Gengo does not need IDE-grade multi-error reporting from a single compile.

The source files for the components described here:

| Component | File |
|---|---|
| Tokenizer | `src/lang/lexer.zig` |
| Pratt parser core, scope/upvalue/type machinery | `src/lang/compiler.zig` |
| Expression compilation | `src/lang/compiler_expr.zig` |
| Statement compilation | `src/lang/compiler_stmts.zig` |
| Declaration compilation | `src/lang/compiler_decls.zig` |
| Type system data model (`TypeRegistry`, `Prec`, `FuncInfo`, ...) | `src/lang/compiler_types.zig` |
| Module/import resolution, cross-module symbol exchange | `src/lang/module_compile.zig` |
| Bytecode emitter this pipeline writes into | `src/lang/chunk.zig` (see `vm-architecture.md`) |

---

## 2. The Pratt Parser Core

**Precedence** is a plain enum, `Prec` (`compiler_types.zig`):

```
none, assign, null_coalesce, or_, and_, eq_, bit_or, bit_xor, bit_and, shift, cmp, term, factor, power, unary, call, primary
```

with `Prec.next()` simply bumping the ordinal by one. `tokPrec(tt: TT) Prec` is a big `switch` mapping token types to precedence levels — this stands in for the classic Pratt "rule table."

**There is no table of function pointers.** Prefix and infix dispatch are both plain `switch` statements over the token type, not a `ParseRule{prefix, infix, prec}` array as in Crafting Interpreters:

- **Prefix**: `parsePrecedence` advances one token, then switches on the previous token's type — numbers, strings, runes, `true`/`false`/`null`, identifiers (→ `varExpr`), unary `-`/`not`/`~`, grouping parens, array/map literals, function literals, `import`, and lexer-error tokens turning directly into compile errors.
- **Infix**: after the prefix parse, the classic Pratt loop runs — `while (prec <= tokPrec(cur)) { advance(); infixExpr(prev.typ); }`. `infixExpr` is one large function special-casing `.dot` (field/method access, static dispatch, `.type` comparisons), `.lbracket` (index/slice), `.lparen` (calls), short-circuit `and`/`or`, `??`, right-associative `**`, and a generic binary-operator tail that resolves typed intrinsics (§4) before emitting via `chunk.State.emitBinOpFused`.

Because Zig generics (`c: anytype`) are used throughout the compiler modules, and `compiler.zig` re-exports these free functions as `Compiler` methods via constant aliases, the "dispatch table" a reader might expect is really just Zig's own function-call graph plus these two big switches — no function-pointer indirection at parse time.

**Contextual keywords, a deliberate trade-off**: `range`, `cycle`, `clamp`, `default`, `predicate`, `message`, and switch's `default` are *not* reserved words — they're recognized only in clause position via one-token-ahead lookahead helpers. Only `type` and `subtype` stay globally reserved. This is a documented, considered choice: a misclassified clause word fails loudly rather than being silently reinterpreted as a plain identifier.

**Error state**: `Compiler` carries a fixed error-message buffer plus line/col fields, populated by `setErr`/`err`. `err()` always returns `error.UnexpectedToken`; most call sites instead call `setErr` directly and return a more specific error (`error.TypeMismatch`, `error.DuplicateLocal`, ...). `Session.copyCompilerError` copies this into session-level fields for host consumption. Line/col tracking originates in the lexer.

**Lexer error tokens**: rather than erroring out itself, the lexer returns sentinel token types (`.err_invalid_char`, `.err_unterminated_string`, `.err_string_pool_exhausted`, `.err_bad_escape`) that the compiler checks explicitly, both at the top of the main compile loop and inline wherever a prefix-position token might be a lex error.

---

## 3. Expression Compilation

**Literals**: numbers are classified int vs. float by scanning for a base prefix (`0x`/`0b`/`0o`) or a `.`/`e`/`E`, then emitted as a `.constant`. Strings and runes (exactly one codepoint) follow the same shape. `true`/`false`/`null` get dedicated opcodes.

**Type tracking without an AST — the `ExprPrimInfo` shadow stack.** Because there is no tree to hang type annotations on, per-expression type information is tracked via a **depth-indexed side array**, `expr_prim_info: [MaxExprDepth + 2]ExprPrimInfo`, indexed by an `expr_depth` counter incremented/decremented around every `parsePrecedence` call:

```zig
const ExprPrimInfo = struct {
    prim: ?PrimType = null,
    named_type: ?[]const u8 = null,
    struct_type: ?[]const u8 = null,
    index_result_spec: ?FieldTypeSpec = null,
    is_constant: bool = false,
    is_plain_binding: bool = false,
    is_zero_int: bool = false,
};
```

This array mirrors the recursive-descent call stack: each nested expression writes its own type info into its own slot; a parent reads its child's result (`expr_prim_info[expr_depth+1]`) right after the recursive call returns. An explicit "capture" mechanism (a small stack of saved depths) preserves an `ExprPrimInfo` across further parsing that would otherwise clobber the shared array — needed when a call's argument list or a binary op's second operand needs its type info to survive nested parsing of siblings.

**Typed-arithmetic intrinsic selection.** `selectTypedComparisonOp` swaps a generic float comparison (`.eq`, `.lt`, ...) for its typed sibling (`.eq_float`, `.lt_float`, ...) when both operands are tracked as `.float` and neither is a compile-time constant — generic comparisons only inline an int fast path, so this avoids a real function call for float. The int-side and add/sub/mul/div selection was removed 2026-07-21 (see CHANGELOG.md): the generic ops already inline the identical fast path for those cases, so the typed op saved nothing and, since selection ran before the load-time fusion pass, sometimes blocked a bigger fusion. Zero-comparison specialization for int (`x == 0` → `.eqz_int` etc.) is unaffected — that one removes a whole instruction, not a redundant check.

Result-type propagation and the full static compatibility ruleset for binary operators (int/float widening, string-concat-only arithmetic, bool/bitwise restrictions, named-type compatibility, bigint/float mixing) all live in one large function, `setCurrentExprPrimResult` — one of the largest single functions in the compiler, and effectively the whole static type-compatibility spec for binary operators in one place.

A smaller, parallel intrinsic layer exists specifically for **stdlib math functions**: direct calls like `std.math.abs`/`.min`/`.max`/`.clamp` are recognized and rewritten to dedicated opcodes (`.abs`, `.floor`, `.sqrt`, `.min`, `.max`, `.clamp`, ...), deleting the call-site bytecode that was speculatively emitted. This is compiler-level intrinsic inlining, distinct from the load-time fusion pass documented in `vm-architecture.md` — it happens once, at compile time, on a small fixed set of stdlib names, not as a general bytecode pattern rewrite.

**Calls**: the callee's resolved identity (a known named-type constructor, or a known global function via `emitGetVar`'s `pending_call_qname`) is captured before per-expression state gets cleared, so that after arguments are parsed the call site can still check each argument against the resolved signature and decide whether **every** argument is compiler-provably type-correct. If so, the call's argc byte gets its top bit set (`argc | 0x80`), letting the VM's warm call path skip runtime argument-type enforcement — quantified in the source as roughly 25% of `fib`'s runtime. Multi-named-return functions get a dedicated `call_spread` instruction so the verifier can track N pushed values, re-packed into a tuple only when the call site isn't itself a matching multi-assign context.

**Indexing/slicing**: `a[i]` becomes `.get_index`; `a[:]`/`a[i:]`/`a[:j]`/`a[i:j]` become `.get_slice` with a flags byte distinguishing which bounds are present.

**Field access / method calls** (the `.dot` infix) is the most involved single branch: it handles `.type` (resolved to a compile-time string constant when the receiver's named type is statically known, else a runtime `.type_name` op), static method dispatch on named types (walking the parent-type chain), the std-namespace call rewrite (turning `std.math.sqrt(...)` into a direct global lookup, truncating speculatively-emitted bytecode when a math intrinsic applies), and ordinary `receiver.method(args)` → `emitInvokeMethod`.

**Casts**: `int(x)`, `float(x)`, `bool(x)`, `string(x)`, `bigint(x)` are recognized as pseudo-calls on those five identifier names, emitting `.cast_int`/`.cast_float`/etc.

**Constant folding is split across two layers, deliberately.** The compiler proper never does arithmetic itself:

1. The "don't select a typed op when either operand is a literal constant" rule above exists precisely to keep constant sequences visible to layer 2.
2. Actual arithmetic folding happens one layer down, in `chunk.zig`: `emitBinOpFused` and `emitOp`'s special-casing for `.mul`/`.div`/`.int_div`/`.rem`/`.mod` detect two adjacent freshly-emitted `constant` instructions and fold them via `foldBinOp` (int/int and float/float, with overflow and divide-by-zero producing "don't fold" rather than a wrong answer). There's a dedicated string-literal concatenation fold (`"a" + "b"` → one constant, with care taken not to double-free deduplicated constant-pool slots), and a neg-peephole that folds `-<int-const>`/`-<float-const>` in place.

This split matters for anyone touching either layer: a change to typed-op selection that stops excluding constants would silently defeat the chunk-level folder, and a change to the folder needs to remember it only ever sees the *un-typed* generic ops by construction.

---

## 4. Statement Compilation

**`stmt()`** is a long lookahead-driven dispatcher. Keyword-triggered statements (`break`/`continue`/`return`/`defer`/`assert`/`if`/`for`/`switch`/`var`) are straightforward; an identifier-led statement uses **multi-token lookahead predicates** that clone the lexer and scan forward without consuming, to disambiguate `x, y := f()` / `x, y = f()` / `x.f = v` / `x[i] = v` / `x++`/`x += 1` / `x = v` / a bare expression statement.

**`if`** supports an optional `;`-separated init statement (detected via lexer-clone lookahead), compiles the condition with an explicit bool-type check, and uses the standard `jif_pop`/`jump`/`patchJump` two-branch idiom, recursing for `else if`.

**`for`** dispatches to three shapes based on lexer-clone lookahead: has `in` → `forInStmt`; has a bare `;` → `cForStmt` (classic `init; cond; post`); else → `whileForStmt` (condition optional; no condition at all means `for { }`, an infinite loop). All three follow the same jump/patch idiom: remember the loop start position, push a `LoopCtx`, emit the body, `emitLoop` back to the start, then patch every break target collected during body compilation.

`forInStmt` (`for k, v in iterable`) declares hidden locals for the loop variables, emits `.iter_init`, then reserves an **anonymous hidden local slot for the iterator object itself under an unmatchable empty name** — not merely counted, registered by name — because a stale name left behind by a previous loop's local-count reset could otherwise shadow the current loop's variable during name resolution (a fixed bug, encoded here as a permanent invariant rather than left implicit).

**Break/continue** must unwind locals down to the loop's boundary, emitting `.close_upvalue` for any captured local before popping it, close any loop-variable upvalues, then either jump to a break target (patched once the loop finishes) or loop back via `emitLoop`.

**Switch** supports two scrutinee modes: a type switch (`switch x.type { case int: ... }`) and a value/variant switch. Value cases support comma-separated value lists via chained `dup`/compare/`jif_pop`. Variant-arm cases (`case .arm_name [as binding] [when guard] { ... }`) emit `dup` + `variant_check` + `jif_pop`, with an optional payload binding and an optional `when` guard — a guarded binding is pinned as a hidden local rather than consumed, because a failed guard must leave the scrutinee available for the next case. **Exhaustiveness checking**: with no `default` arm, the compiler tries to uniquely identify the variant type from the arm names seen and reports any missing arms by name — a genuine compile-time check with no runtime component.

**Function bodies** are compiled by one shared function, `compileFuncWithPrefix`, used by plain function literals, named `func` declarations, and methods alike (a `prefix` parameter supplies the receiver name for methods). It parses parameters (optional `...` variadic, `const` params, default values, space-syntax type annotations), detects named vs. anonymous returns by lookahead, pushes a new function-level scope, and handles several load-bearing details at once:

- **Named returns** occupy dedicated locals, zero-initialized for scalar types so compound assignment works before any explicit write.
- **Return-type proof**: for a single-primitive-return function whose body provably ends with a `return` (so the compiler's own implicit-null-return path is provably unreachable) and whose every explicit `return` provably matches the declared type, the compiled function is marked `returns_proven` — letting the VM trust the return value's type rather than re-check it at runtime.
- **Recursive self-call typing**: a function's signature is only registered in the type registry *after* its body compiles, so a self-call inside the body resolves argument checking and the proven-args fast path through a small in-progress-signature stack instead, keyed by the function's qualified name.
- **Self-reference closures**: `name := func() { ... name() ... }` pre-declares the local slot with `null` before compiling the function-literal RHS, so the closure body can capture itself as an upvalue rather than falling through to a (nonexistent, at that point) global lookup.
- **Implicit return**: pushes the sole named-return value, `null`, or (for two-or-more named returns) a placeholder the VM's `ret` handler recognizes as "spread the named-return slots directly."

**`defer`** parses a call-shaped expression, with a special rewrite for `defer TypeName.method(instance, args...)` (detected and converted to an ordinary method-style call on the first argument, truncating the speculatively-emitted type-object bytecode) — because invoking a method directly on the type object itself isn't the intended semantics. `defer { block }` desugars to a zero-arg closure plus `defer_call 0`.

**`return`**: bare `return` uses named-return locals or `null`; named-return functions with an explicit value assign into the named-return slots *before* implicit-return emission, so deferred closures observe the final values. **Tail-call detection is explicitly not done here** — the source carries an explicit comment stating this is decided later, by the load-time fusion pass, which sees whether a `close_upvalue` intervened between the call and the return. The front-end compiler's job is only to ensure correctness: it emits `close_upvalue` for any captured local *except* named-return slots, which must stay open because deferred closures need to observe post-return mutation of them.

**Multi-assign / multi-bind** (`x, y := f()` or `x, y = f()`) has two code paths: a matching multi-named-return call spreads values individually with no tuple involved; a general expression list gets packed into, then unpacked from, a runtime tuple (`tuple_check_arity`/`tuple_get`).

---

## 5. Declaration Compilation

**Functions** share `compileFuncWithPrefix` (§4) across plain declarations, methods, and function literals. Locals get slots by straightforward array append in declaration order — there is no separate "resolve" pass; slots are assigned as the parameter list and body are walked.

**Closures and upvalue capture — the actual compile-time mechanism** (see also §7): each function-level scope carries a small `upvalues` array. Resolving a name as an upvalue walks up **exactly one enclosing scope at a time** (Crafting-Interpreters style, not a flat search across all enclosing scopes): if the name is a local in the immediately enclosing scope, that local is marked captured and a direct upvalue is registered; if not, the resolver recurses into the *next* enclosing scope, and on success registers an indirect upvalue pointing at the parent's own upvalue slot. This is the standard upvalue-chain construction, done entirely at compile time, and it's what the VM's `get_upvalue`/`set_upvalue`/`close_upvalue`/`make_closure` opcodes execute against at runtime. Once a function body finishes, its upvalue array is packed into a compact byte array (top bit = "from an upvalue, not a local"; low 7 bits = index) and stored on the compiled function object — this is exactly what `make_closure` reads to build the real closure's upvalue array.

**Struct declarations** parse fields (name + space-syntax type, optional `const`), rejecting duplicate names and self-referential fields unless behind a reference type (`[]T`, `map`, `?T`). Non-generic structs are registered in the type registry and immediately emitted as a runtime struct-type constant plus `def_global`. **Generic structs are stored purely as an uninstantiated template** — no bytecode is emitted for the generic declaration itself; only instantiation (below) produces bytecode.

**Interface declarations** parse method signatures only, no bodies; interfaces cannot themselves have methods defined on them.

**Variant declarations** support payload-less arms, single-payload arms (positional or named field), record-style arms with multiple named fields, and shared fields declared outside any arm. Same generic/template split as structs.

**Named types** (`type Name Base ...`) are handled by the single largest declaration function in the compiler, dispatching by lookahead into: generic type-parameter lists, `struct`/`interface`/`variant` bodies, a bare `error` marker, `enum { ... }` (explicit or auto-incrementing integer representations), named array/map types, a generic-instantiation alias (`type IntStack Stack[int]`), and the general scalar-subtype form — `type Age int range 0..150 predicate func(...) message "..." default 0` — which supports range/cycle/clamp constraints on numeric bases, a compile-time-checked default against the range, and inheritance of range/predicate/scale/collection-spec when the declared base is itself a previously-declared named type.

**`subtype`** is a distinct, narrower form from `type X Y ...`: it requires an existing named type as parent and only narrows constraints (range/predicate/default), with explicit range-subset validation against the parent's bounds. It also supports narrowing an enum to a member subset, validated member-by-member against the parent.

**Generics — what "instantiation" actually looks like at the compiler level** (core infra is done; general inference is not, matching the project's own tracked status):

- Type parameters are tracked on the `Compiler` and pushed/popped around parsing a generic declaration or function body; a bare identifier inside that scope is recognized as a type parameter rather than a concrete type.
- A generic struct/variant is stored **unexpanded**, as a template plus its parameter list; nothing is emitted until first use.
- **Instantiation** parses concrete type arguments (`[int, string]`), builds a cache key, and on a cache miss deep-copies the template's fields/arms, recursively substituting type parameters with the concrete argument specs — including nested generics (`Stack[T]` used inside another generic's template), deferred until the substitution can resolve them concretely. The fully concrete type is then emitted as a runtime constant under a synthesized qualified name (`Stack[int]`) and cached both by instantiation key and by that name, for reverse lookup.
- **Generic functions** (`func name[T: constraint](...)`) support an optional structural constraint (`numeric`/`ordered`/`comparable`) checked against the concrete argument's primitive or named-type base, and explicit-type-argument call syntax (`name[T, U](args)`). There is **no inference of type arguments from argument values** — only struct/variant instantiation supports inferring a type argument from a literal's shape (`Stack[int]{ items: [] }`); generic function calls need the type argument written out.

**Method receivers** require the exact shape `func (recv_name recv_type) method_name(...)`, verified by lexer-clone lookahead before committing to parsing it as a method. The receiver becomes parameter 0. Methods are registered globally as `"<QualifiedReceiverType>.<method_name>"`, which is also how static-method dispatch in expression compilation (§3) looks them up. Interfaces cannot be receivers.

---

## 6. Type System Integration

`compiler_types.zig` defines the data model, not the algorithms that use it: `Prec`, `PrimType`, `TypeCheck` (a tagged union describing a value's static type constraint — none/prim/named/assert-array/assert-map/assert-error/interface/struct/anon-typed), `Local`/`Upvalue`/`FuncInfo`/`LoopCtx`, and the `TypeRegistry`.

**`TypeRegistry`** is the symbol table for the current compile: struct/interface/variant/named-error type names, rich named-type info (base, range, predicate, scale, parent chain, collection element specs, default value), and a unified table for global functions and constants. Lookups go through **two open-addressed hash tables** rather than linear scans — this replaced an earlier design with five separate per-category caps (`MaxStructTypes`/`MaxInterfaceTypes`/`MaxVariantTypes`/`MaxGlobalFuncs`/`MaxGlobalConsts`), collapsed into two unified caps (`MaxTypes`, `MaxGlobals`) sized so the hash tables stay well under load factor 0.5. `TypeRegistry.reset()` clears everything once per non-REPL compile, after which known stdlib types are reseeded so `std` methods/types resolve without a real import.

**Compile-time checks actually enforced** — this is the concrete list, not a claim of a general type system:

- **Named-type predicate/range enforcement**: runtime validation opcodes (`.check_named_predicate`, `.validate_named_range`) are inserted at compile time wherever a value is constructed, assigned, or mutated into a ranged or predicated named type, walking the parent chain so a subtype inherits its parent's predicate.
- **Named-type arithmetic compatibility**: mixing two different named types, or a named "erased scalar" type with a bare literal, is rejected unless explicitly unwrapped or constructed.
- **Struct/interface/variant assertions** (`.assert_struct`/`.assert_interface`/`.assert_type`) are inserted for typed `var`/return/parameter positions — runtime checks, but the decision of which check and where is entirely compile-time.
- **Direct-call argument compatibility** is a genuine compile-time type error (not a runtime-check insertion) when a call site passes an incompatible primitive or named type to a parameter with exactly one known type alternative.
- **Return-type proof** (§4, "C4") is a real, if narrow, compile-time soundness proof.
- **Generic constraint checking** (`numeric`/`ordered`/`comparable`) is compile-time-only structural checking.
- **Variant switch exhaustiveness** (§4) is compile-time-only, with no runtime component.

**There is no general type inference or unification engine.** Types are tracked forward through the `ExprPrimInfo` shadow stack (§3) and the declared `FieldTypeSpec` on locals/globals/parameters/returns. There is no solving of type variables beyond the narrow generic-constraint check above — this is a deliberate scope boundary, not a gap waiting to be closed by accident.

---

## 7. Scope, Locals, and Upvalues

- **Scope depth**: a fixed-size array of function-level scopes (max 8 deep), one `FuncInfo` per *function*, not per block. Entering a function body pushes a new `FuncInfo`; block scoping *within* a function is a separate, lighter mechanism — a block-depth counter plus a snapshot of the local count taken at block entry, with locals above that snapshot popped at block exit. There is one flat locals array per function; nested blocks just remember and restore a high-water mark rather than maintaining their own array.
- **Local slots**: appended to the current scope's locals array in declaration order. Resolving a name is a **linear reverse scan** (innermost-declared-first) — this is what gives shadowing its expected "closest declaration wins" semantics within one function. Names prefixed with `_` are exempt from the duplicate-name check, supporting a placeholder-binding idiom.
- **Upvalues**: one array per `FuncInfo`, built by the one-hop-at-a-time recursive walk described in §5, materialized into a packed byte array on the compiled function object.
- **Loop tracking** is a separate stack from function scopes (max 16 deep). Each loop context records a continue target, two different local high-water marks (one for `continue` cleanup, one — slightly higher, including loop-control locals like a C-for loop variable — for normal loop-back cleanup), and a list of break-jump offsets patched once the loop finishes compiling.

---

## 8. Module and Import Integration

`Session` (`module_compile.zig`) owns everything cross-module: an array of module records, a source-provider abstraction (filesystem, an in-memory table, or a callback — this is how embedders and tests inject virtual filesystems), import sandboxing (relative imports are checked against configured module roots), and capability/host-module descriptor tables.

**Compile-time-uniform import resolution**: a single resolver function is the dispatch point for *every* `import(...)` expression, regardless of kind — `cap:name` (checked against enabled capabilities), `host:name` (checked against registered host modules), `std` (a fixed global), and ordinary relative/package file imports (resolved to a canonical path, recursively compiled if not already compiled, returning a synthesized global name). This single function is the only thing the `Compiler` itself knows about imports — from the compiler's point of view, every `import(...)` just calls one callback and gets back a global name to look up. This is what the project's import-resolution design memory means by "all imports resolve uniformly at compile time": the uniformity lives in this one callback, not spread across the compiler.

**Module identity**: a non-root module gets a synthesized name prefix, which namespaces every top-level declaration inside it. At the end of compiling any module, a synthetic struct instance holding all `pub` exports as fields is built and bound under the module's global name — this is exactly the object `import(...)` hands back to the caller (`x := import("./foo"); x.bar()`).

**Cross-module type/constant resolution** goes through explicit callbacks into the `Session`, not a shared registry — each module's exports (names, type kinds, constant values) are recorded once that module finishes compiling, and a later module's compiler queries them by callback. This is how a qualified type reference (`alias.TypeName`) or a cross-module constant (`alias.CONST`) resolves.

**Where this pipeline's responsibility ends**: the compiler's job is "correct, semantically-checked bytecode in a `chunk.State`." It deliberately does not do peephole or opcode-fusion optimization beyond two narrow, local exceptions already covered (`chunk.zig`'s binary-op constant folder, and the compiler's own fixed-list stdlib math-intrinsic rewrites). Everything else — including the tail-call and `get_local`+binop fusions visible as dedicated opcodes in `op.zig` — is applied afterward, uniformly, by the load-time fusion pass documented in `vm-architecture.md` §6, on whatever bytecode this pipeline produced.

---

## 9. Key Invariants Summary

- **One compiler instance is bound to exactly one runtime's heap and chunk**, passed in explicitly at `init()` rather than read through any thread-local "active state." This is what makes multi-runtime isolation sound at the compiler level, not just the VM level.
- **The proven-args fast path** (stealing the top bit of a call's argc byte to mean "every argument is compiler-proven type-correct") is compiler-authored, not VM-authored — it exists so the VM's warm call path can skip runtime argument-type checks, quantified in-source at roughly 25% of `fib`'s runtime.
- **`func name()` declarations are immutable bindings; `name := func(...)` is not.** This is required, not stylistic — call-site type-checking and the proven-args fast path both depend on a named function's signature never changing underneath a call site that already checked it.
- **Tail-call decisions are deliberately not made here.** The compiler only guarantees correctness (closing captured locals except named-return slots); whether a `call` immediately followed by `ret` becomes `call_tail` is decided later, by the load-time fusion pass, which can see whether a `close_upvalue` intervened.
- **Named-return slots must not be closed at `return` time**, unlike ordinary captured locals — a deferred closure reads them after the return statement runs, and closing early would sever that connection.
- **Contextual keywords fail loudly on misclassification.** `range`/`cycle`/`clamp`/`default`/`predicate`/`message` are recognized only by clause-position lookahead; a token that looks like one of these outside clause position is treated as a plain identifier, and any resulting mismatch is a compile error, never a silent reinterpretation.
- **Erased vs. boxed named types.** Named types over `int`/`float`/`bool`/`rune` (and enums, for this purpose) are erased to their bare scalar at runtime — the compiler emits validation-only prolog/epilog for them. Named types over non-scalar bases go through a real constructor call instead. This distinction threads through compound assignment, increment/decrement, and var-decl epilogs, and is worth knowing once rather than re-deriving at each call site.
- **The hidden iterator-slot invariant in `for...in`**: the iterator's hidden local must be registered under an unmatchable name, not merely counted — a stale name left over from a previous loop's local-count reset could otherwise shadow the current loop's variable during name resolution.
