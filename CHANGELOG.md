# Gengoscript Changelog

This changelog tracks notable language/runtime changes by implementation date.

## 2026-08-19

### GBC — generic function support via type-parameter erasure (#5)

`writeTypeSpec` used to reject any `FieldTypeAlt` tagged `.type_param`
with `error.UnsupportedFieldType` — a generic function's own declared
parameter type (the `T` in `func identity[T](x T) T`) is exactly that,
and since every function declaration emits a constant regardless of
whether it's ever called, `--emit-gbc` rejected any script merely
*declaring* a generic function, whether called or not.

Fixed by erasing `type_param` to `FT_ANY` on the wire instead of
rejecting it — matching `docs/language.md`'s own stated runtime
semantics ("Type parameters are erased at runtime, treated as any"),
not inventing new behavior: a generic function's body already treats a
`type_param`-typed value as `any` at every use once compiled, so a
loaded function doing the same is the existing behavior made explicit
on the wire, not a weaker one. Constraint enforcement
(`checkTypeArgConstraints`) is unaffected — it runs at each call site's
own compile time against the *caller's* concrete type arguments, never
by inspecting a callee's stored `param_types`, whether that callee came
from source or a loaded `.gbc`. Verified with a constrained generic
(`func maxOf[T ordered](a T, b T) T`) called both with an explicit type
argument and with inference, alongside a two-type-param function
combined with a `func_t` argument (`map_array`) — not just the trivial
single-param case — producing byte-identical output to running the
source directly, both before and after this change.

`enums`, `task types`, and now `generic functions` are removed from
`known-limitations.md`'s Tooling table entirely — the three type/
signature kinds implemented across today's three GBC entries. Remaining
unsupported: in-body predicates with real captures and closures with
real captures — the two genuinely hard cases left, since they need to
represent capture semantics in the wire format, not just another
type-descriptor or erasure case.

### GBC — task/actor type support, plus a real scheduler bug found along the way (#5)

`TYPE_KIND_TASK` (wire value `0x06` — no gap was reserved for it, since
task/actor shipped after the initial GBC spec pass) implemented following
`enum_t`'s pattern from earlier the same day: the task's `behavior`
FuncObj registers through the same `SEC_FUNCTIONS`/`FuncNamePatchTarget`
machinery a named type's predicate uses, except never closure-wrapped —
task bodies can't capture outer locals at all (design doc §3.3), so
there are never any upvalues to carry, unlike a predicate.

Writing an actual round-trip test for a spawning task (not just a
data-fidelity check) surfaced a real, separate bug: `Runtime.runFromGbc`
called `vm.runUntilSuspend` once, directly, with no task scheduler
loop at all — it predates task/actor integration entirely.
`runPathWithProvider` (the source-compiling entry point) gained the
scheduler loop when tasks shipped; `runFromGbc` never did. A task
spawned from a GBC-loaded program would enqueue but never get a turn:
the spawning script's own `receive()` would block forever, and since
nothing drove the scheduler to notice, the whole run silently returned
success having executed none of the spawned task's body — no crash, no
error, no output. Confirmed via the actual CLI (`--emit-gbc` then
running the artifact) before writing the regression test: a minimal
spawn-and-reply script produced zero output through GBC while working
correctly compiled normally. Fixed by extracting the scheduler loop
into `Runtime.driveTaskScheduler`, shared by both entry points instead
of one silently lacking it — this was a real correctness gap in
`runFromGbc` independent of the new TYPE_KIND_TASK work, not something
task_type's own serialization caused.

`enums`/`task types` removed from the `--emit-gbc`/`--emit-gbc-module`
"unsupported feature" error message and `known-limitations.md`'s
Tooling table (across both today's entries). Generic functions,
in-body predicates with real captures, and closures with real captures
remain unsupported.

### GBC — enum type support (#5)

`TYPE_KIND_ENUM` (wire value `0x03`) was reserved in `gbc-spec.md` §8.6
from the start but never implemented — `enum_type` fell through
`gbc_writer.zig`'s constant-writing switch to `UnsupportedConstant`, the
same generic rejection an unsupported type gets. Implemented following
`struct_t`/`variant_t`/`interface_t`'s existing `TypeEntryInfo`/
`writeTypesSection` pattern: members (name list), `member_ints` (optional
explicit representation values — absent means "use ordinal position"),
and `parent_name` (enum subtypes, `subtype Weekend Days { Sat, Sun }` —
a separate feature from named-type subtypes, sharing the same `""` == no
parent wire convention `TYPE_KIND_NAMED` already uses). The resolved
parent `*Object` pointer is left null on load and picked up lazily by
`vm_types.zig`'s `resolveEnumParent` on first use, identical to a
normally compiled enum subtype — no GBC-side cross-reference resolution
needed. Verified via the actual CLI (`--emit-gbc` then running the
artifact) before writing the regression test down: explicit
representation values, auto-incremented ordinals, `.name`/`.int`/
`from_int()`, and an enum subtype all produce byte-identical output to
running the same source directly. `enums` removed from the
`--emit-gbc`/`--emit-gbc-module` "unsupported feature" error message and
`known-limitations.md`'s Tooling table; generic functions, task/actor
types, in-body predicates with real captures, and closures with real
captures remain unsupported.

### Security — `cap:net` dial policy now defaults to deny, not allow (#221)

`checkDialPolicy` (`net_state.zig`) previously allowed any destination when
no dial policy rules were configured, unlike `checkListenPolicy`'s existing
default-deny — an inconsistency found while reviewing an external security
audit and confirmed against the code. Flipped dial's no-rules fallback to
deny, matching listen: a host must now add at least one explicit allow rule
(`engine_net_policy_add`, or the CLI's new `--net-dial-allow pattern[:port]`,
mirroring `--net-listen-allow`) before `net.dial(...)`/`net.dial_tls(...)`
succeed on anything. Breaking change for any embedder currently granting
`cap:net` dial with zero configured rules.

## 2026-07-28 (v0.6.0-pre2)

### stdlib — `std.crypto` gains 6 new primitives

- **`hkdf_sha256(ikm, salt, info, length)`** — HKDF-SHA256 (RFC 5869) key derivation; verified against RFC 5869 §A.1 test vector.
- **`xchacha20poly1305_seal(key, nonce, plaintext)` / `xchacha20poly1305_open(key, nonce, ciphertext)`** — XChaCha20-Poly1305 AEAD with 24-byte nonce (vs the 12-byte nonce of the existing `chacha20poly1305_*` pair).
- **`ed25519_sign(seed, message)`** — Ed25519 signature; returns 64 raw bytes.
- **`ed25519_verify(pubkey, signature, message)`** — verifies an Ed25519 signature; returns bool.
- **`x25519(secret, pubkey)`** — X25519 Diffie-Hellman (RFC 7748); verified against RFC 7748 §6.1 vector 1.

### Runtime — `NativeFnId` expanded to u16

Native function IDs backing type was `enum(u8)` (max 255 entries). Expanding the stdlib past 256 functions would have caused a silent enum truncation or compile error. The backing type is now `enum(u16)`, the `native_fn_backing` array is sized by `max_value + 1` (not field count) to handle the sparse enum correctly, and `vm_perf` counters updated accordingly.

### Fix — `package_state.MaxFileSize` now tracks `cfg.max_input_bytes`

The zip package decompressor previously rejected files larger than 64 KB regardless of the engine preset. `MaxFileSize` is now derived from `cfg.max_input_bytes` at comptime so it stays in sync with the compiler's own per-preset limit (128 KB for 1m, 512 KB for 16m, 64 MB for unlimited).

## 2026-07-28 (v0.6.0-pre1)

### Fixes

- **Net/HTTP per-Runtime isolation (#216)** — `NetEngineState` and `HttpEngineState` are now owned by each `Runtime` instance and activated per-call via the same pattern as `fs_state`. Each engine gets independent net policies, listen policies, handlers, connection tables, and HTTP handler — a real isolation gap for processes hosting multiple independently-configured runtimes. Embeddings that set net/HTTP state via the old process-global helpers must now configure them on the engine before first use.
- **Generic struct methods (#217)** — Methods can now be defined with a generic receiver (`func (s Stack[T]) top() T`) and on type aliases of generic instantiations (`type IntStack Stack[int]; func (s IntStack) top() int`). `isMethodDecl` now scans through `[...]` after the receiver type name; `methodDecl` parses the receiver type params, pushes them into scope for the body, and uses the alias's target qualified name for type-alias receivers. The VM falls back from the instantiated name (`@mod:Stack[int]`) to the base name when resolving generic-receiver methods, so one definition covers all instantiations.

## 2026-07-27 (v0.6.0-pre1)

### Security / Correctness — Multi-wave hardening audit (waves 4 + 5)

A systematic audit of the VM, compiler, GBC reader/writer, and all native stdlib modules found and fixed 39 additional issues. All are in-repo commits ea8500f / ab23a4a / 2d5be04 / 9809208 / 21a1dab and their wave-4/5 predecessors.

**User-visible breaking changes:**

- **`allow_io` defaults to `false`** — `std.io` output is now suppressed unless the host explicitly sets `allow_io = true`. Embeddings that relied on the previous default-allow must update their config.
- **`string.split_n(s, "", n)` now splits at UTF-8 codepoint boundaries** — previously byte-oriented. Code relying on byte-level splitting with an empty separator must switch to `std.bytes` operations.

**New errors / limits:**

- `HostValueTooDeep` — `ValueWire` values nested deeper than 64 levels; raised by `engine_call` / `engine_get_global` and host module calls instead of overflowing the call stack.
- `HostValueTooLarge` — a wire value's `len` field exceeds the u32 maximum.
- `NoSpaceLeft` — `std.Time.format` raises this when the expanded format string exceeds 512 bytes.
- `NestingTooDeep` — compiler error for `else if` chains exceeding 256 levels.
- `RangeError` from: `string.repeat`/`bytes.repeat` (result > 64 MB); `io.printf`/`fmt.format`/`fmt.stringify` (output > 64 MB); all `std.regexp` functions (input > 1 MB); `time.add_date` (i32 overflow).
- `MalformedSection` — GBC reader now rejects `named_return_count > 64`.

**Bug fixes (non-breaking):**

- IC warm-path field indices in crafted `.gbc` files were not range-checked; now guarded against OOB reads.
- Variant type field count (> 255 combined) now produces an error instead of silent corruption.
- Integer default parameter values now parsed as exact `i64` (no intermediate `f64`); integers > 2^53 were silently rounded.
- `std.core.deep_equal` no longer panics for maps with more than 128 entries.
- Import sandbox path-traversal check now runs before any filesystem probe for all import kinds.
- GBC writer now asserts `named_return_count <= 64` and `writeTypeSpec` is depth-limited to 64 levels.
- Defuse pass correctly handles `ret_const` and avoids double-remapping shared `FuncObj` pointers.
- Fusion pass now marks `.closure` and `.named_type` predicate-const IPs as branch targets.
- `bytes.unpack`: container object allocated before slice to avoid stale-slice UAF.
- `string.split_n` with empty sep now uses `utf8RuneCount`/`utf8NextRuneByteLen` for correct UTF-8 iteration.
- `core.deep_equal` for maps > 128 entries now heap-allocates the `used []bool` array.
- `template` exec/parse/add_func: re-derive slice pointers after any allocation to prevent stale-slice UAF.
- `cap_env` list: map object allocated before entries to prevent stale-slice UAF.
- `regexp`: `MaxMatchDepth = 200` prevents recursion overflow; content-hash cache key prevents false cache hits.
- `time.format`: buffer bounds checked on every write; `time.add_date` uses `@addWithOverflow`.
- `core.nativeConvToString` inline-variant path: bounds checks before each write.
- `io.sprintf`/`fmt.stringify`: 64 MB cap enforced.
- `arraySlice`: re-derives `items_now` after `vmAllocObject` to prevent stale-slice UAF.
- `stringSlice`/`stringIndex`: use new `makeStringViewFromStringObj` helper that allocates first, then re-derives bytes, preventing stale-slice UAF.
- `vm_types.zig` rune-from-float: guards `t < 0 or t > 0x10FFFF`; string-arm: derives a fresh `dyn_string` from the source object after allocation.
- `resolveImportPath`: sandbox check runs before `sourceExists` for escaping paths.

## 2026-07-25 (latest) (v0.6.0-pre1)

### Runtime — `cap:net` gains `net.listen`/`Listener` (server-side sockets), gated by a new general capability-scope mechanism

Adds `net.listen(network, address) [Listener, error]` and `Listener.accept()/close()/local_addr()/set_accept_deadline(ms)`, so a script can bind a port and accept inbound TCP connections — an MQTT listener, an HTTP server, a TCP echo service — purely in Gengo, reusing the exact same `Conn` type and read/write/close/deadline API `net.dial` already produces for the data path.

- **New CLI/embedding mechanism, not just a new function**: `net` is now gated by scope — `--cap net=dial`, `--cap net=listen`, or `--cap net=dial,listen`. Bare `--cap net` (no `=`) still means exactly what it always has (dial-only); upgrading an existing deployment never silently grants listen. The `--cap name=scope1,scope2` syntax is a general CLI mechanism (split on `=` then `,`), not `net`-specific, so any future capability that grows scopes gets the same syntax for free. `cap:net`'s import gate succeeds as long as *some* net scope is granted; each function is refused individually at call time if its own scope wasn't (`ctx.vs.net_scopes`, computed from `Runtime.enabled_capabilities` in `Runtime.activate()`) — the same shape as an `fs` operation against a path with no matching mount.
- **Listen policy defaults to deny-all**, deliberately the opposite of dial's existing default-allow: a host must affirmatively add at least one allow rule before any `net.listen(...)` call succeeds. Separate rule list from dial's — configuring one has no effect on the other. Two ways to add a rule: the embedding API (`engine_net_listen_policy_add`, mirroring `engine_net_policy_add`'s shape and LIFO evaluation exactly), or the CLI's new repeatable `--net-listen-allow pattern[:port]` flag (added same day, after initially shipping this host-API-only to match dial's precedent — dial's identical "no CLI flag" gap doesn't matter in practice since dial defaults to allow, so the asymmetry meant listen's version of that gap left it completely unusable from the CLI, not just unrestricted; see #215).
- **`net.listen`/`Listener.accept` return `[value, error]` pairs**, unlike `dial`'s single "Conn or error" value — matching `http.get`/`post`/`fetch`'s existing convention (`l, err := net.listen(...)`) rather than dial's, since that's the calling shape the language surface actually needs here.
- Native POSIX implementation reuses existing `net_state.zig` machinery rather than inventing new plumbing: `socket()`+`bind()`+`listen()` (fixed backlog, 128) into a new `g_listeners` table (independent ceiling from `MaxConns`, default 8 — a script needing many listening ports is a different shape of program than one needing many connections); accept deadline reuses `posixSetSockOptTimeval`/`SO_RCVTIMEO` applied to the *listening* socket instead of a connection, so `EAGAIN` maps to `error.DeadlineExceeded` exactly like `netRead`'s existing arm; a successful `accept()` produces a plain connected socket wrapped in the same `NetConn` struct `dial` produces, pushed into the existing `g_conns`/`MaxConns` pool — accepted and dialed connections share one ceiling and one accounting path, not a separate parallel budget.
- Host-mediated path (WASI/browser/embedders without POSIX sockets) extends `gengo_net_handlers_t` with optional `listen`/`accept`/`listener_close`/`listener_local_addr`/`set_accept_deadline` callbacks — `null` on a host that supports dial but not listen, reported as `CapabilityNotAvailable` rather than a crash. WASI itself gets the same treatment `dial` already has (`error.CapabilityNotAvailable`): confirmed directly against Zig's std that WASI has no `bind`/`listen`/`accept` syscall wrappers at all (only Linux's raw syscall interface does), so there was a real platform gap to gate, not a guess.
- Tests: `compiler_test.zig` gains scope-gating and default-deny-policy tests, plus a genuine POSIX `bind`+`accept`+`read`+`write` roundtrip test using a `std.Thread`-spawned raw-socket client (kept off `net_state`'s own globals entirely to avoid a real cross-thread data race, since `net_state` has no locking) against the real listener implementation; `engine.zig` gains `engine_net_listen_policy_add`/`_clear` C API tests mirroring the existing dial-policy ones; a new `tests/spec/cap/fail/006_net_listen_scope_not_granted.gengo` conformance case.
- Docs: `capabilities.md` (scope table, `Listener` API, default-deny policy, server-loop shape), `capability-matrix.md`, `security.md` (listen vs. dial policy defaults, why they differ, existing cross-runtime `net_state` isolation gap now also covers listeners), `cli.md` (`--cap net=scope1,scope2` and `--net-listen-allow` syntax).
- New example: `examples/time-server/` — an RFC 868 Time Protocol server and client, about as minimal a demonstration of `net.listen`/`Listener.accept` as exists (connect, receive 4 bytes, done). Runs directly under the CLI, no host embedding needed.
- **Known, explicitly deferred, not fixed here**: `net_state.zig`'s connection/listener tables and both policy lists remain process-wide module state, not yet part of the per-instance activation set #190 tracks for `chunk`/`globals`/`heap`/`vm` — a pre-existing latent gap for dial, now also covering listeners. Not a concern for a single-`Runtime`-per-process embedding (the CLI); a host running multiple independently-untrusted scripts with `listen` enabled in one process should treat this as a real isolation gap until #190 lands, not assume it's already handled. See `dev-docs/design/net-listen-design.md` for the full design rationale.

## 2026-07-22 (v0.6.0-pre1)

### Runtime — GBC: interface and predicate support; two real bugs found and filed separately (#5, same day)

Closed out the last two gaps blocking `gengo-mqtt`'s `listener-all.gengo` from compiling to GBC end-to-end: its `Connection interface` (`mqtt/client.gengo`) and four predicate-bearing named types (`Topic`/`TopicFilter`/`ClientId`/`SubAckCode` in `mqtt/types.gengo`). Verified against the real script: it now compiles with `--emit-gbc`, and the resulting `.gbc` connects to a live MQTT broker and streams decoded packets identically to plain interpreted execution.

- **Interfaces.** Researched first (mirroring every prior GBC increment): `interfaceDeclBody` (`compiler_decls.zig`) builds a real `InterfaceTypeObj` and `emitConst`s it exactly like struct/named/variant declarations — not compile-time-erased as initially suspected — and it's genuinely consulted at runtime: `matchesInterfaceType`/`interfaceMethodMatches` (`vm_types.zig`) fetch the live `.interface_type` global by name and compare each method's declared param/return types against the actual implementing function's types on every `assert_interface` check (emitted for every interface-typed parameter/variable binding). Added `TYPE_KIND_INTERFACE` (wire kind `0x04`, the slot `gbc-spec.md` had already reserved for it) reusing the spec's pre-existing `InterfaceMethod` shape and the already-built `writeTypeSpec`/`readTypeSpec` machinery — no new wire concepts needed.
- **A real, more consequential gap this surfaced**: function and interface-method param/return types had never actually round-tripped — the writer always wrote empty placeholders (`param_type_count = 0`) and the reader always forced `has_typed_params`/`has_typed_returns` to `false`, a deliberate first-milestone deferral. That's silently safe for a plain function (it just skips a redundant runtime type check), but it breaks interface conformance outright: `interfaceMethodMatches` compares the interface's *real* declared types against the loaded function's forced-empty ones and would legitimately reject a correctly-typed, correctly-implementing struct method purely because it came from a `.gbc`. Completed the deferred implementation — the spec had always fully specified `FunctionEntry`'s `param_types`/`return_types`/`variadic_type` (§8.3); only the writer/reader had deferred it — using the same `writeTypeSpec`/`readTypeSpec` encoder already built for struct fields.
- **Predicates.** Researched whether a predicate closure is structurally guaranteed captureless: `resolveUpvalue` (`compiler.zig`) bails immediately at module/type scope (no enclosing function locals to capture), so every predicate declared there — which is how all of `gengo-mqtt`'s predicates are written — compiles to a zero-upvalue `.closure` wrapping an ordinary `FuncObj`. Crucially, that `FuncObj` never gets its own independent constant-pool slot at compile time (`compileFuncWithPrefix`'s own constant/`make_closure` emission is skipped for a predicate) — the writer now registers it manually into the same `SEC_FUNCTIONS` side-table a plain function constant uses, and stores the resulting index (plus `predicate_msg`, real, always-scalar) on the `NAMED` `TypeEntry`; the reader reverses this and reconstructs the zero-upvalue closure, matching what the compiler itself produces.
- **Also fixed while in the `NAMED` entry**: `is_anonymous` (read at runtime for anonymous array/map-typed-local equality — `vm.zig`), `scale` (decimal fixed-point precision — `vm_types.zig`/`value.zig`), and `has_default`/`default_val` (zero-init of a named type must produce its declared `default`, not the base type's ordinary zero) had *never* been written to the wire at all — not rejected, just silently dropped, a real correctness gap distinct from anything predicate/interface-related, found only because completing the `NAMED` entry for predicates meant looking at the whole struct for the first time in a while.
- **Two real, pre-existing bugs found along the way, confirmed unrelated to GBC (via `git stash` to the prior commit, still reproducing on plain interpreted execution with zero caching involved) and filed rather than fixed here, since neither blocks this script and both need dedicated attention**:
  - **#211** — a named type declared *inside a function body*, with a predicate that captures that function's own locals, crashes with `TypeError` unconditionally the first time the function runs. Root-caused to a bytecode emission-order bug: `make_closure` is emitted before the named type's own `emitConst` in `compiler_decls.zig`, but the `set_named_predicate` opcode (`vm.zig`) expects the opposite stack order.
  - **#212** — a function whose *declared, checked* return type is a predicate-bearing named type crashes the VM with a fatal integrity failure (frame corruption, `ImpossibleOpcodeState`) on return. Suspected mechanism: `enforceFuncReturnTypes`'s named-type path (`vm_types.zig`) re-invokes the predicate as a reentrant VM call while already mid-`ret`-opcode-handling, desyncing the frame stack.
- Tests (`compiler_test.zig`): full round-trips for a captureless predicate (valid and invalid values both still enforced correctly post-load), an interface (a conforming struct still passes `assert_interface`, a non-conforming one is still correctly rejected — the exact scenario the param/return-type fix was needed for), and a named type's `default`/`scale`. Updated the CLI's `UnsupportedConstant` message and `docs/cli.md`'s limitations list to the now-narrower remaining scope (enums, an in-function predicate, a closure with real captures). `gbc-spec.md` bumped to v0.8 with the `INTERFACE` `TypeEntry` and the completed `NAMED`/`FunctionEntry` field lists documented.

### Runtime — GBC: variant-type support, and a real int/float constant-tag fix (#5, same day)

Motivated by a real external script (`gengo-mqtt`'s `listener-all.gengo`) hitting `error.UnsupportedConstant` on its `ReceivedPacket variant { publish { topic Topic, pkt_id ?PacketId, payload string, qos Qos }, ... }` declaration — confirmed via a minimal, import-free repro that the `variant` type itself (not the multi-file import structure) was the blocker.

- Researched the actual runtime representation before writing any wire format, the same way as the earlier struct/named-type increment: `VariantArmSpec` (`value.zig`) has **two distinct arm shapes** sharing one struct — a single-payload arm (`ok(value int)`, `payload_name`/`payload_type`) and a record arm (`publish { topic string, ... }`, a `fields: []StructFieldSpec` list) — plus a no-payload bare tag, and a **type-level** `shared_fields: []StructFieldSpec` (fields declared directly in the variant body, common to every arm). The spec's pre-existing §8.6 `VariantArm` sketch (`payload_name`/`payload_type` only) covered only the single-payload shape — it had no way to represent a record arm like the mqtt script's four-field `publish` at all. Fixed by adding an explicit `arm_kind` (NONE/SINGLE_PAYLOAD/RECORD) wire discriminant and a shared `StructField`-list encoder (`writeFieldList`/`readFieldList`) reused by `STRUCT` entries, a variant's `shared_fields`, and a record arm's `fields` (spec v0.7).
- Confirmed via reading the actual opcode implementations (`variant_check`, `variantTypeFieldValue`, `variantValueFieldValue`, `build_struct_instance`'s `.variant_ctor` branch) that arm `name`/`has_payload`/`payload_name`/field names are load-bearing at runtime — every `switch`/`case` and field access re-resolves an arm by name against the *loaded* type object, never by a baked-in index — so the wire format's `arms` array order carries no semantic weight (a loader is free to preserve or reorder it). Also confirmed `arm.fields[].typ`/`shared_fields[].typ` aren't actually runtime-checked by any construction path today (asymmetric with ordinary struct fields, which are checked/coerced on every write) — encoded them with the real `FieldTypeSpec` machinery anyway, both for forward-compatibility and because a variant is already a first-class `FieldTypeAlt` case elsewhere (a struct field or function param typed as the variant).
- Added `TYPE_KIND_VARIANT` (kind byte `0x05`, matching the spec's pre-existing reservation — not `0x03`, which the spec had already set aside for a future `ENUM` kind; using the free slot instead of renumbering) to `gbc_writer.zig`/`gbc_reader.zig`, and a `.variant_type` case to the writer's constant-pool switch (previously fell through to `error.UnsupportedConstant`) and the reader's `CONST_TYPE_REF` switch (previously `error.MalformedSection` for any kind other than struct/named).
- **A second, unrelated real bug found via the new variant round-trip test**, not a variant-specific issue: the wire format's `NUMBER` constant tag stored *both* `.int` and `.float` Values as `f64`, and the reader reconstructed which tag to use via a "no fractional part → int" heuristic. That heuristic silently turns any whole-valued float constant (`1.0`, `2.0`, ...) into `.int` on load — wrong, since Gengo enforces strict, never-implicitly-mixed `.int`/`.float` typing everywhere (arithmetic, comparison, named-type binding). Every earlier GBC test happened to avoid returning a whole-valued float directly, so this pre-existing gap was invisible until the variant test's `c.x + area(c)` (both genuinely `.float`) came back tagged `.int` and panicked on `.float` field access in the test itself. Fixed by un-reserving the `INT` constant tag (`0x06` — the spec had explicitly reserved it "for a future format version," reasoning that "the current VM represents all numbers as f64 internally," which doesn't hold: `.int` and `.float` are two distinct Value tags today, not merely a display convention over one f64 representation): `.int` values now write through `INT` as a raw `i64`; `.float` always through `NUMBER`; no heuristic on read (spec v0.7).
- Tests (`compiler_test.zig`): a full round-trip covering a variant with a shared field, a record arm, a single-payload arm, and a no-payload arm, exercised through both field access and `switch` dispatch; a dedicated regression test asserting a whole-valued float constant comes back `.float` after the `INT`/`NUMBER` fix.
- Docs updated: `dev-docs/design/gbc-spec.md` (v0.7), `docs/cli.md`'s GBC limitations list, `docs/changelog.md`'s unreleased Tooling entry, and the CLI's `--emit-gbc` `UnsupportedConstant` error message all now say "variants" are supported and name the narrower remaining scope (enums, interfaces, predicate-bearing named types, closures with captures as constants).

### Runtime — GBC first milestone: writer + reader round-trip (#5)

Started implementation against `dev-docs/design/gbc-spec.md` (fully specified, nothing built yet before this). Scope matches the issue's own suggested first milestone: a minimal round-trip for a simple script — no imports, one bytecode section, constants, functions, empty types/exports/dependency tables — not the full 27-check validation gauntlet (§11.1), which the issue itself says to add "one by one" in follow-up work.

- `src/lang/gbc_writer.zig` / `src/lang/gbc_reader.zig` (new). The writer serializes the **defused** (core-ops-only) form of an already-compiled, already-fused chunk — reusing `vm_defuse.buildDefusedCode` (built for differential testing) rather than writing a second bytecode-transform pass. The reader loads core-ops + constants into a fresh `chunk.State` and hands off to `fusion_pass.fuse()` — the exact step the normal compile pipeline (`runtime.zig`'s `compileProgram`) already runs — so a loaded chunk becomes runnable through the identical path a freshly-compiled one does. Globals are not pre-populated from any table: running the loaded top-level code (`make_closure`+`def_global`) is what defines them, same as an ordinary script run.
- Two real spec gaps found and fixed while implementing against the spec for the first time:
  - **No way to represent a function in the constant pool.** `make_closure`'s bytecode operand is a constant-pool index that must resolve to a function, but the spec's `CONSTANTS` section only had tags for `NUMBER`/`STRING`/`NULL`/`BOOL`/`RUNE`, and `FUNCTIONS` was specified as a self-contained side-table with no stated link back to `CONSTANTS`. Added a `FUNC_REF` constant tag (`0x07`, spec v0.5) holding a `u32` index into `SEC_FUNCTIONS`; the loader resolves it to a constructed `FuncObj` and installs that into the constant slot before running any code.
  - **Header size arithmetic error.** The spec's own §6.1 field table sums to 184 bytes (7×`u16` + 3×`u32` + 6 reserved + `i64` + 4×`hash32` + 2×`u64`), not the 192 stated in three places (the `header_size` field description, the "total defined header size" line, and Phase 1 check #4). Found by implementing a writer against the table and a reader that rejected its own output. No field was added or removed — corrected all three mentions to 184.
- A third, narrower correctness fix in the reader itself (not a spec issue): `has_typed_params`/`has_typed_returns` can't be preserved from the wire as-written while `param_types`/`return_types` stay empty (TYPES-table support is deferred) — `vm_types.zig` only skips indexing into those slices when the corresponding `has_typed_*` flag is false, so a loaded function with a true flag and an empty slice would be an out-of-bounds read the first time an argument or return value was type-checked. The reader forces both flags to `false` regardless of what the writer recorded, documented as a correctness-safe (just unenforced, not silently unsafe) v1 limitation.
- Deliberately deferred for this slice, not oversights: Phase 3 staleness checks (`source_graph_hash`/`vm_fingerprint`/`module_provider_hash`/`options_hash` compared against *current* state — the writer computes and records real values, the reader parses but doesn't yet compare them), `vm_fingerprint` for native targets (spec leaves this host-defined; using a placeholder hash until a real build-id/commit mechanism exists), closures with upvalues and named/struct/variant types in the constant pool (writer rejects with `error.UnsupportedConstant` — struct/closure support needs the `TYPES` section built out first), and `local_count`/full `TypeSpec` decoding in `FUNCTIONS` entries (frame sizing instead comes from `chunk_verifier.verify()`'s `max_stack` stamp, recomputed on every load exactly as a fresh compile would).
- Tests: a full round-trip (compile → run for the expected value; compile again, write, read into a fresh chunk, fuse, run; assert identical results) plus rejection tests for an out-of-scope constant kind, a corrupted magic, and a corrupted body checksum — all in `src/compiler_test.zig`.

### Tooling — `gengo --emit-gbc` / running a `.gbc` directly (#5, same day)

Wired the writer/reader above into the CLI so the round-trip is a real, usable workflow rather than only a unit test: `gengo --emit-gbc app.gbc app.gengo` compiles and writes the cache; `gengo app.gbc` (detected by magic bytes at offset 0, not by extension) loads and runs it directly, skipping compilation — verified end to end, including a script using `std.io.println` (ordinary native/std calls need no special handling: they already compile to a `get_global` on a plain string constant, which round-trips through the existing `CONSTANTS` section with no GBC-specific work).

- `Runtime.runFromGbc` (new, `runtime.zig`) mirrors `runPathWithProvider`'s post-compile tail (install natives, `vm.run`) with `gbc_reader.read()`+`fusion_pass.fuse()` in place of `compileProgram()`.
- `--emit-gbc path` catches `error.UnsupportedConstant` (struct/named-type/closure constants, per the milestone's scope) and reports it as a named limitation instead of a raw Zig error trace.
- Found and fixed a real cross-target bug while wiring this up: `gbc_reader.zig` used `u64` wire-format offset/length fields directly as slice bounds. That's silently fine on a 64-bit host (`usize` is 64-bit, `u64` narrows to it without complaint) but fails to compile on `wasm32-wasi` (`usize` is 32-bit there, and a bare `u64` doesn't implicitly narrow) — caught by the `wasm32-wasi` build already in `zig build test`/pre-push, not by any native-only test run. Fixed by narrowing once, right after each value is bounds-checked against the actual buffer length (proving the cast safe), rather than at every later use.

### Runtime — GBC: struct and named-type support (#5, same day)

The single most limiting gap from the first milestone: `--emit-gbc` rejected any script declaring a `struct` or `type X int/float/... ...` with `error.UnsupportedConstant`, which covers most real scripts. Implemented the `TYPES` section (`SEC_TYPES`) the spec had designed but the milestone left unimplemented, plus a `TYPE_REF` constant tag mirroring `FUNC_REF`'s indirection (constant-pool slot → table entry).

- Researched what's actually load-bearing at runtime before implementing, rather than assuming struct field types could get the same "compile-time-only, safe to placeholder" treatment given to function param/return types: they can't. `build_struct_instance`/`opSetField`/`opSetIndex` re-check a struct field's declared type (and cascade into that field type's named-type predicate, if any) on *every* literal construction and field write, not just once at compile time — confirmed by reading the actual opcode implementations, not assumed. `is_const` is *only* enforced at runtime (no compile-time equivalent at all) — omitting it would have been a real, silent mutability regression, not a degraded-but-safe simplification. `key` (a struct field's `Value`) turned out to be safely omittable — it's mechanically `Value{.string = internStr(field.name)}` and never independently consulted for field lookup, which always goes by name.
- Implemented a real recursive `FieldTypeSpec`/`FieldTypeAlt` encoder/decoder (`writeTypeSpec`/`readTypeSpec`) for the shapes struct fields and named array/map elem/key/val specs actually use: all scalar tags, one level of `struct_t`/`interface_t`/`named_t`/`variant_t` (by qualified-name string — these are name-based at runtime already, `matchesTypeAlt` resolves them without needing the referenced type's own constant slot), and recursive `array`/`map`. Rejects `func_t`/`type_param` (generics-only, out of scope) with a dedicated `error.UnsupportedFieldType` rather than silently mis-encoding them.
- Found a second real spec gap while doing this: the `FieldTypeAlt` tag table never had a tag for `decimal` at all, despite every other scalar base (`int`/`float`/`rune_t`/`bool`/`string`) having one. Added `DECIMAL_T` at `0x0F` (spec v0.6).
- Predicate-bearing named types and enum/interface/variant object kinds are still rejected with `error.UnsupportedConstant` — a captureless-closure-in-a-constant encoding (what a predicate needs) isn't implemented yet, and enums/interfaces/variants are separate object kinds this pass didn't touch. The CLI's `--emit-gbc` error message was narrowed to name exactly this remaining scope instead of the original, broader "struct/named-type values" wording.
- Found and fixed a real memory-safety bug while testing this against `std.testing.allocator` (which tracks leaks strictly, unlike a general-purpose allocator that would have silently tolerated it): `fields`/`alts`/`capture_slots` arrays were allocated via the reader's transient scratch allocator, then embedded directly into the long-lived `StructTypeObj`/`FieldTypeSpec`/`FuncObj` constant they build — correct as long as that allocator happens to outlive the object (true for the CLI's per-process allocator, not guaranteed in general, and not true for a short-lived test allocator that frees at the end of each test). Switched all three to the GC heap (`heap.State.bump`), matching how the compiler itself allocates anything a compiled object needs to keep referencing after the allocating function returns.
- Known, documented gap: the CLI does not yet check a `.gbc`'s recorded source hash against the current source file before running it — regenerate a `.gbc` by hand when its source changes; a self-invalidating cache is follow-up work once Phase 3 staleness checks are implemented.

### Language — limited operator overloading via reserved dunder methods (#210)

A struct (or non-conflicting-base named) type can now overload `+ - * / rem` (binary), unary `-`, `==`/`!=`, and `< > <= >=` by declaring one of eight reserved method names — `__add__`/`__sub__`/`__mul__`/`__div__`/`__rem__`/`__neg__`/`__eq__`/`__compare__` — as an ordinary method (no new keyword). Kotlin/Python-flavored design: reserved *names* do the disambiguation work Kotlin's `operator` keyword modifier would otherwise be needed for, since Gengo (like Kotlin, unlike Rust) has no separate impl-block boundary — methods are always declared alongside their receiver type, so there's nothing for a keyword to compensate for that the name itself doesn't already handle. `__compare__` returns an `int` and backs all four ordering operators at once (Kotlin's `compareTo` trick); `!=` is derived from `__eq__`.

**Compile-time desugar** (`compiler_expr.zig`'s new `tryEmitDunderBinaryOp`, and `unaryExpr`'s `__neg__` branch): `a + b` becomes `a.__add__(b)` when the compiler can see `a`'s static type declares one — same `get_global`+`swap`+`call` shape the existing static method-dispatch path already uses for `.dot` calls, so no new opcode. The dunder check has to run *before* the RHS is parsed (not after, as the existing named-scalar arithmetic fast paths do), since the call convention needs `[callee, receiver, arg]` on the stack and the callee has to be inserted while only the receiver is there.

**Exact-match only, permanently**: the parameter type must be exactly the receiver's own type — no Rust-style asymmetric operands (`impl Add<Rhs>`). This isn't a v1 simplification; Gengo has no method overloading anywhere (two methods of the same name on one receiver is `"duplicate method"`), and an asymmetric form would require exactly that.

**Conflict rule, more precise than "block if the base has any operator"**: a named type may only declare a dunder for an operator its base doesn't *already correctly implement* — verified per-operator against actual VM behavior, not assumed. `int`/`float`/`rune` block all eight (full arithmetic + comparison already work); `decimal` blocks six but leaves `__rem__`/`__compare__` open (decimal's `rem` and ordering both throw a runtime `TypeError` today — a real, pre-existing gap, not a hypothetical one); `string` blocks only `__add__`/`__eq__` (concat and content equality work; ordering doesn't); `bool` blocks only `__eq__`; `array_t`/`map_t`/`enum_t`/struct block only what's genuinely already meaningful (enum's ordinal `==`; nothing for array/map/struct, since their `==` today is raw pointer identity, not a "real" operator worth protecting — declaring `__eq__` on a struct is exactly how you upgrade that reference-identity default to structural equality).

**Two three-turn compiler gaps found and fixed while making this actually reachable from ordinary code**: (1) struct literals (`structInstanceLit` in `compiler_expr.zig`) never set `ExprPrimInfo.struct_type` on their own result at all — only explicitly `var x StructType`-typed locals tracked struct type; (2) `typeCheckFromFieldTypeSpec` (`compiler.zig`) had no `.struct_t` case, so struct-typed *function parameters* got no type tracking either. Both fixed, plus new `:=`-inference for struct locals and globals (`inferred_struct_global_names`/`types` in `compiler.zig`, mirroring the existing `inferred_named_global_*` pattern) — without these, the feature would only have worked from explicitly `var`-typed bindings, which is not how anyone writes Gengo in practice.

**Runtime fallback for generic bodies** (`tryStructDunderBinary`/`tryStructDunderUnary` in `vm.zig`): the compile-time desugar can't fire inside a type-erased generic function body (`func f[T](xs []T) { ... xs[0] + xs[1] ... }` — `T` has no static type at compile time, no monomorphization in this language). Without a runtime path, bundling `__compare__`/`__eq__` into the `ordered`/`comparable` generic constraints (`satisfiesConstraint` in `compiler_decls.zig`) would have been a false promise: the constraint check passes at the call site, then the function body panics the first time it actually compares two values — a "fails loudly" violation, not a real gap. Added a genuine runtime dispatch path instead: `add`/`sub`/`mul`/`div`/`rem`/`eq`/`ne`/`lt`/`gt`/`le`/`ge`/`neg` all check, when both operands are the same struct type (pointer equality on the un-monomorphized `struct_type` object), whether that type declares the matching dunder, and if so call it via `vm.callFunction` — the same reentrant-call idiom already used for named-type predicates and `std.array`/`std.sort` callbacks, safe here since both operands are already off the value stack with no allocation happening before the call.

## 2026-07-22 (earlier) (v0.6.0-pre1)

### Language — `clamp`, a third named-type range mode (#208)

`range` (hard `RangeError`) and `cycle` (modular wrap) already shared one grammar clause (`parseConstraintBounds`) and one dispatch point (`is_cycle` throughout `vm_types.zig`'s `constructNamedType`/`applyNamedTypeFn`). Added `clamp` as a third option at that same clause — `type Percent int clamp 0..100` saturates an out-of-bounds value to the nearest bound instead of erroring or wrapping.

- New `is_clamp: bool` field alongside `is_cycle` on both `NamedTypeObj` (`value.zig`, the runtime object) and `NamedTypeInfo` (`compiler_types.zig`, the compile-time registry), propagated through both named-type declaration sites in `compiler_decls.zig` (top-level `type` and `subtype`), parent/subtype inheritance, and REPL cross-line persistence (`runtime.zig`).
- New `clampValue` helper in `vm_types.zig`, wired into `constructNamedType`'s `int`/`float`/`decimal`/`rune` branches and `applyNamedTypeFn` (`.succ`/`.pred`) — each gets an `else if (nt.is_clamp)` branch alongside the existing `is_cycle` branch. `rune` previously had no `is_cycle` branch at all (cycle is restricted to `int`/`float`/`decimal`); clamp has no such restriction and applies to all four range-eligible bases.
- Composes with the rest of the range-constraint machinery for free: clamping happens inside the same validation step `predicate` already runs after, so a clamped value is then predicate-checked like any other value — clamp doesn't bypass `predicate`, it just changes what value reaches it. `default` is unaffected — still validated strictly against `min..max` at compile time regardless of mode, since clamp's leniency is about construction-time values, not the type's own declared default.
- No opcode changes: `validate_named_range` already dispatches through `coerceNamedTypeResult`/`constructNamedType`, so the mode-specific behavior lives entirely in those two functions.

Found and fixed a pre-existing, unrelated doc/behavior mismatch while writing this up: `docs/language.md` claimed plain `range` types "clamp to the declared domain" for `.succ()`/`.pred()` at the boundary — they actually raise `RangeError` (verified: `Step.succ(Step(100))` panics for `type Step int range 1..100`). Corrected the wording before introducing the real `clamp` mode, to avoid the two concepts colliding.

Also updated four existing fail-case `.err` files (`252_range_on_string_type`, `253_range_on_bool_type`, `203_subtype_non_numeric_range`, `204_subtype_non_numeric_cycle`) whose expected-error substrings no longer matched after the compiler's error message changed from "range and cycle constraints..." to "range, cycle, and clamp constraints...".

## 2026-07-22 (earlier) (v0.6.0-pre1)

### Fix — named-return of a boxed named type panicked with `NotAFunction` (#204)

Found while backfilling #204's typed-assignment prolog/epilog matrix: `returnStmt` called `emitVarTypeEpilog` for a named-return slot without first calling `emitVarTypeProlog`, unlike `assignStmt`/`compoundStmt`/`incrStmt`, which all already pair the two. For a named-return type over a non-scalar base (`type Tag string` used as `func f() (result Tag)`), the epilog's `.named` branch emits a real constructor `call(1)` — but with no prolog, there was no constructor callee pushed under the return value, so the call treated the just-built return value itself as the callee: `return Tag(s)` panicked `NotAFunction` at runtime. Named-return types over an erased scalar/enum base (`Meters int`) were unaffected — their epilog branch is `validate_named_range`/`check_named_predicate`, which needs no callee.

Fixed in `compiler_stmts.zig`'s `returnStmt` by calling `emitVarTypeProlog` before compiling each named-return slot's expression, exactly mirroring the other three call sites. Regression coverage: `tests/spec/332_named_return_boxed_type.gengo` (behavioral) plus native bytecode-shape tests in `compiler_test.zig` covering the erased-vs-boxed distinction across compound-assign, increment/decrement, and named-return (closes the "typed-assignment prolog/epilog matrix" half of #204; the fusion-pass trigger-decision matrix half remains open).

## 2026-07-21 (latest) (v0.6.0-pre1)

### Tooling — `gengo --test --profile` (#58)

Each `test` block already compiles to a synthetic `__test_N` global run through one isolated loop in `Runtime.runPathWithProvider` (`vm.callGlobal`, sequential, pass/fail tracked) — that loop turned out to be exactly the wrapping point #58 needed, making this a smaller change than its `P3`/`v0.9.0` label suggested.

- **Stack peak**: reuses the verifier-proved `f.max_stack` bound `enterFunctionFrame`/`enterFunctionFrameWarm` already check on every call (`ctx.vs.stack_top + f.max_stack`) — an upper bound on capacity used, not a per-push sampled maximum, so it costs one extra branch at an already-existing call-entry checkpoint instead of touching the push/pop hot path at all.
- **Heap bytes / live objects peak**: `usedBytes()`/`liveObjectCount()` only ever grow at allocation time (GC only shrinks them), so checking-and-updating a peak at `vmAllocObject`/`vmAllocManagedSlice`/`vmAllocManagedBytes`'s 8 success points is sufficient to capture the true peak.
- **Ops count**: `ops_budget_remaining` only decrements when a real `max_ops` budget is set — an unbudgeted run takes a batched "heartbeat" dispatch path specifically to avoid a per-instruction accounting cost. `profile_mode` forces the interval to 1 (tick every instruction) with no real budget, so `budget_before - budget_after` gives an exact per-block count; this is the one part of the feature with a real, expected runtime cost (a diagnostic flag, not something to run by default).

All three are gated behind a new `Policy.profile_mode` field, zero cost when off. Verified with `tools/time-bench.sh compare`: no measurable regression on any benchmark.

## 2026-07-21 (later) (v0.6.0-pre1)

### Embedding — std natives are no longer host-overridable

A host could intercept 8 built-in natives (`std.core.len`/`append`/`bytelen`, `std.conv.to_int`/`to_float`/`to_bool`/`to_string`, `std.io.println`) via a capability-bitmask handshake (`host_caps`) and substitute its own implementation. That meant the same call could silently behave differently depending on which host an embedded script happened to run under — no script-visible signal, no naming difference, just different behavior for what reads as a plain stdlib call.

Removed entirely: the `host_caps` handshake, the 8 `CAP_*` bits, and the corresponding `HostCall` wire IDs (`src/runtime/host_abi.zig`). These 8 natives now always run their embedded implementation, unconditionally, regardless of `--backend`/`native_backend`. **`import("host:name")` host modules are unaffected** — they're a different, explicitly host-owned namespace (the host chooses the name and the `call_id`), not a substitution for something that looks like a builtin, and continue to work exactly as before. `ABI_VERSION` unchanged (still `2`) — the ABI has never been official at any level, so there's nothing to version-bump against.

## 2026-07-21 (v0.6.0-pre1)

### Performance — Decimal construction no longer recomputes pow(10, scale) (#206)

`tests/bench/016_decimal_billing.gengo` (a billing-style price\*qty→total workload) was added to measure whether decimal arithmetic is dispatch-bound enough to justify dedicated `decimal_add`/`decimal_mul` opcodes, per #206's decimal item. Profiling (`tools/profile-vm.sh`) showed `lang.vm_types.constructNamedType` — the shared named-type constructor every decimal arithmetic result passes through — spending the bulk of its time in `std.math.pow(f64, 10.0, scale)`, called fresh on every single decimal construction, plus a `std.math.pow(f64, 2.0, 63.0)` i64-range-boundary check likewise recomputed every call instead of being a constant.

Fixed at the root rather than papering over it with new ops:

- `value.zig`'s new `decimalScaleFactor(scale)` indexes a fixed 19-entry `pow10` table (decimal scale is compiler-validated to 0..18) instead of calling the transcendental `std.math.pow`. Used by both decimal construction (`vm_types.zig`) and decimal-to-float conversion (`decimalScaledToFloat`).
- The four `std.math.pow(f64, 2.0, 63.0)` bounds checks in `vm_types.zig`'s decimal construction path became a single named `f64` constant.

Measured on `016_decimal_billing.gengo` (`perf stat`, 20 runs): -15% instructions, -10% cycles, -9% wall time. Confirms the issue's own framing — once the redundant work is removed, decimal's real remaining cost (heap allocation to box the result, since decimal values carry their scale via the named-type pointer) dwarfs dispatch cost the same way bigint/string-concat already do, so **no dedicated decimal opcodes were added**; the opcode-space budget stays unspent.

Also fixed in the course of getting a measurement: `zig build bench-perf`'s WASM build (`gengo-perf`) was compiled at `.Debug` optimize level, which — now that the interpreter's opcode switch has grown past 165 assigned slots (#207) — emits enough unmerged per-arm locals that wasmtime's translator rejected the module outright ("too many locals"), silently breaking the perf-counter baseline lane. Switched to `.ReleaseSafe` (same safety checks as Debug, but with the register allocation that keeps locals under wasmtime's limit); `tests/bench/perf_baseline.txt` regenerated and now current with #207's bytelen/bytes_decode/field_add_const op-count reductions, which had never actually landed in the baseline file. `tools/profile-vm.sh` had an unrelated `pipefail`/`grep` bug that aborted the script on any fully-cached (zero-output) build; fixed alongside since it blocked this investigation.

### Performance — `get_index_const_str`: constant-key map access (#206)

The last item of #206's specialization roadmap. `m["literal"]` — a bare string-literal index, the overwhelmingly common shape for map access (`tests/bench/011_map_lookup_heavy.gengo`) — went through generic `get_index` (pop key, pop receiver, unbox, switch on receiver kind) even though the key is already known at compile time.

New core op `get_index_const_str = 0x82` (`u16:name_const_idx`), lowered directly at the compiler's `[` handling site (`compiler_expr.zig`) when the index expression is a single bare string-literal token immediately closed by `]` — this is a compile-time lowering, not a fusion-pass rewrite, since there's no multi-instruction runtime pattern to match (the key never gets pushed onto the stack in the first place). `map_hashed` (the common case) reads the key straight out of the constant pool and calls the same `vmmap.mapGet` the generic path uses; every other receiver kind (array/struct/named wrapper/...) pushes the constant back and delegates to `opGetIndex` verbatim, so non-map indexing logic exists in exactly one place.

Measured on `011_map_lookup_heavy.gengo` (`perf stat`, 30 runs): -5.8% instructions, -8.8% cycles, -8% wall time. Op count for that benchmark drops by exactly 800,000 (4 lookups × 200,000 iterations × 1 fewer instruction each).

### Performance — Reclaimed 14 of the 26 typed-arithmetic opcodes (7d4e39d)

Re-measured whether splitting `add_int`/`sub_int`/etc. out of the generic arithmetic ops was worth the permanent opcode-space spend. Mostly not: `sub_int`/`mul_int`/`div_int`, `eq_int`/`ne_int`/`lt_int`/`le_int`/`gt_int`/`ge_int`, and `sub_float`/`mul_float`/`div_float` (12 ops) turned out to be byte-for-byte redundant — the generic ops already inline the identical fast path. `add_int` measured ~3% *slower* than generic `.add` despite fewer instructions (icache/branch cost), and `add_float` was statistically neutral. Both also silently defeated fusions (`local_add_local`, `add_ret`, `const_add`) since those only pattern-match the generic opcode, not its typed sibling — confirmed with `--disasm`.

Kept: the 6 int zero-compare shortcuts (genuinely save a whole instruction) and the 6 float comparisons (generic comparisons only inline an int fast path, not float — `lt_float` measured ~2.5% faster than the fallback). Math intrinsics unaffected.

14 slots reclaimed to `reserved_*` in `op.zig`; never released, so nothing depended on the values. `dev-docs/opcodes.md` now shows 152/256 slots assigned (was 166).

## 2026-07-12 (v0.6.0-pre1)

### Performance — Small struct inline storage (#157)

Struct instances with ≤4 fields are now stored as a new `small_struct_instance` Object variant with inline field values (`[4]Value`), eliminating the secondary managed-slice allocation that every struct construction previously required.

- `build_struct_instance` and `zero_struct` use inline storage for ≤4-field structs.
- All field access (`get_field`, `set_field`), method dispatch, index operations, GC tracing, deep-clone, and all native helpers (`len`, `is_struct`, `type_name`) handle both variants transparently.
- Structs with ≥5 fields continue to use the managed-slice path unchanged.
- The inline cache for `get_field`/`set_field` continues to work identically: it keys on the struct type's pool index, which is the same for both variants.

For typical user structs (2–4 fields), this halves the GC object count per construction: one Object allocation instead of two.

### Performance — Zero-allocation named-return spread (#188)

Multi-named-return functions called in a destructuring context (`a, b := f()`) now produce **zero GC allocations** on the common path (no defers), down from four.

Previously, `emitImplicitReturn` built a tuple (2 allocs) that `retSlowPath` immediately discarded and rebuilt (2 more allocs). Now:

- A new `call_spread N` opcode tells the bytecode verifier that the call pushes N individual values. The VM `ret` handler and `retSlowPath` both push the named-return slots as N separate stack values — no boxing.
- For non-destructuring callers (`x := f()`, `f()` as argument), a `build_tuple N` is emitted after the call to re-pack N values into one (1 alloc, down from 2).
- Panic recovery (`std.core.recover()`) in multi-named-return functions also spreads N values correctly.

No language changes. Existing code is unaffected.

## 2026-07-03 (v0.6.0-pre1)

### Feature — Module Bundles (#48)

Scripts can now import modules from named bundles registered on the engine. No special prefix is needed — `import("mylib/utils/strings")` resolves against registered bundles transparently, keeping the same import path in development and production.

**New API:**

- **`engine_load_bundle(handle, name, name_len, zip_ptr, zip_len)`** — registers a zip-format bundle under a name. Each `.gengo` file in the zip becomes an importable module. Limits: 32 bundles per engine, 64 files per bundle, 64 KiB per file. Supports `store` and `deflate` compression.
- **`engine_load_bundle_dir(handle, name, name_len, dir, dir_len)`** — native-only convenience that loads all `.gengo` files found recursively under a directory. Useful during development to load live source trees. Not available on WASM.
- **`engine_clear_bundles(handle)`** — removes all registered bundles.

**Resolution order:** stdlib → host modules → import loader callback → bundles → `engine_add_source` entries.

## 2026-07-03 (v0.6.0-pre1)

### Feature — Runtime Introspection

Four new engine API functions give the host visibility into a running script:

- **`engine_get_global(handle, name, name_len, out)`** — reads a named global as a `ValueWire`; returns `0` on success, `-2` if not defined.
- **`engine_list_globals(handle, callback, userdata)`** — enumerates every global variable; callback receives `(userdata, name, name_len, *ValueWire)`.
- **`engine_list_functions(handle, callback, userdata)`** — same as above, filtered to user-defined functions and closures; callback receives arity instead of a wire value.
- **`engine_set_trace_fn(handle, callback, userdata)`** — registers a per-source-line hook; callback fires as `(userdata, handle, line, col)` at most once per line during `engine_run` / `engine_call`. Pass `NULL` to clear.

`engine_get_global` works on all targets. The three callback-based APIs are not available on WASM.

## 2026-06-28 (v0.5.0-pre6)

### Feature — `std.bytes` Module

New module for raw binary data: byte-level construction, decomposition,
integer encoding/decoding, and byte-indexed search.

```gengo
b := std.bytes

frame := b.u16be(0xDEAD) + b.u16be(0xBEEF)
std.io.println(std.hex.encode(frame))   // "deadbeef"
std.io.println(b.u16be_at(frame, 0))    // 57005
```

Key functions: `u8`, `pack`, `unpack`, `at`, `slice`, `len`,
`u16be`/`u32be`/`u64be`/`u16le`/`u32le`/`u64le` (encode),
`u16be_at`/`u32be_at`/`u64be_at`/`u16le_at`/`u32le_at`/`u64le_at` (decode),
`index_of`, `contains`, `starts_with`, `ends_with`, `count`, `replace`, `repeat`.

IEEE 754 float encode/decode is also available: `f32be`, `f64be`, `f32le`, `f64le`
and their `_at` counterparts.

### Feature — String Escape Sequences

String literals now support hex and Unicode escape sequences:

```gengo
"\x41"          // "A"
"A"        // "A"
"\U00000041"    // "A"
```

`\xHH` encodes a single raw byte. `\uXXXX` and `\UXXXXXXXX` encode Unicode
code points as UTF-8.

### Feature — HTTP Timeout Support

`cap:net` connections now support deadlines. Pass a millisecond timeout to
`conn.set_deadline(ms)`, `conn.set_read_deadline(ms)`, or
`conn.set_write_deadline(ms)`. An expired deadline returns a catchable
`error("timeout")` value rather than hanging.

### Feature — `--heap` CLI Flag

The native CLI now accepts `--heap <bytes>` to override the compiled-in heap
size at runtime (subject to the preset ceiling):

```bash
gengo --heap 2097152 script.gengo   # 2 MiB heap
```

### Fix — Regexp Group Alternation Backtracking

Regexp group alternatives (`(a|b)c`) now correctly backtrack when the
continuation after the group fails. Previously a match on the first alternative
could fail the whole pattern even when the second alternative would have
succeeded.

### Fix — Large Integer Literal Precision

Integer literals larger than 2^53 now parse as exact `i64` values without
floating-point rounding. `9007199254740993` (2^53 + 1) previously parsed as
`9007199254740992` due to intermediate `f64` conversion.

### Fix — GC and Heap Fixes

Several GC and heap fixes for long-lived embeddings:

- Managed heap now supports true compaction: live objects are relocated to
  eliminate fragmentation after a failed allocation.
- Size-class isolation prevents small-object frees from polluting large-block
  free lists.
- Array slice backing sources are now retained across GC.
- Map entries and variant values are correctly freed during sweep.
- Native function objects are stored outside the GC heap on flat-mode presets.

### Fix — Buffered TCP Reads

`cap:net` reads on native targets now batch socket reads into a 4 KiB
per-connection buffer. This reduces the number of `read(2)` syscalls from one
per `conn.read(n)` call to one per 4 KiB consumed, giving a ~3× throughput
improvement for MQTT-style framed-protocol workloads.

### Fix — Test Block Compiler Fixes

- The test block limit was raised from 64 to 256 per script.
- Undefined-global checks are now suppressed inside discarded test bodies,
  fixing a spurious compile error when test blocks reference names from the
  main script body.

## 2026-06-22 (v0.5.0-pre5)

### Feature — Module-Qualified Types

Types exported from a source module can now be used directly in function signatures, struct fields, and variable declarations via the import alias:

```gengo
geo := import("./geometry/shapes")

func make_point(x int, y int) geo.Point { ... }
func scale(d geo.Distance, n int) geo.Distance { ... }

type Segment struct { a geo.Point, b geo.Point }

var origin geo.Point = geo.Point { x: 0, y: 0 }
d := geo.Distance(10)
```

The compiler resolves the type kind (struct, interface, named, variant) at compile time by inspecting the imported module's export registry.

### Feature — Import Sandboxing

The CLI and WASM binary now restrict file imports to the script's own directory by default. Any import that would resolve outside that directory is rejected at compile time:

```
gengo: compile error: ImportOutsideRoot: import '../shared/utils' is outside the allowed source directories
```

Use `--modules <path>` (repeatable, up to 8 entries) to opt in additional directories:

```bash
gengo --modules /app/lib --modules /app/shared script.gengo
```

Embedded runtimes are unrestricted unless `source_root` is set explicitly in `api.Config`.

## 2026-06-22 (v0.5.0-pre4)

### Breaking — `%` Operator Removed

The `%` operator is no longer valid. Use `rem` or `mod` instead:

- `rem` — truncating remainder, sign follows the dividend (Ada/Pascal `rem`)
- `mod` — mathematical modulo, result is always non-negative when divisor is positive (Ada `mod`)

The compiler emits a helpful error pointing to the correct replacement.

### Breaking — `std.io.sprintf` Moved to `std.fmt.format`

`std.io.sprintf` has been removed. Use `std.fmt.format(fmt, ...args)` — same verbs, same semantics, correct namespace (it returns a string, not I/O).

### Feature — `div` Keyword Operator

Truncating integer division as a keyword operator, following Ada/Pascal convention:

```gengo
7 div 2    // 3
-7 div 2   // -3
```

`/` continues to work for float division. `div`, `rem`, and `mod` all work on named numeric types.

### Feature — `std.fmt.stringify`

Renders any value to a string exactly as `std.io.println` would display it:

```gengo
fmt := std.fmt
fmt.stringify(42)          // "42"
fmt.stringify([1, 2, 3])   // "[1, 2, 3]"
fmt.stringify(myStruct)    // same output as println(myStruct)
```

### Feature — Enum `.succ()`, `.pred()`, `.ordinal`

- `.succ()` — next member, wrapping from last back to first
- `.pred()` — previous member, wrapping from first back to last
- `.ordinal` — 0-based declaration position, independent of representation value

```gengo
type Day enum { mon, tue, wed, thu, fri, sat, sun }
Day.fri.succ()    // sat
Day.sun.succ()    // mon
Day.wed.ordinal   // 2
```

### Feature — Enum Representation Clauses

Enum members can be assigned explicit integer representation values. Gaps are allowed; unspecified members increment from the previous value:

```gengo
type Status enum { pending = 0, active = 1, done = 2 }
type Flags  enum { none = 0, read = 1, write = 2, exec = 4 }
```

Values are accessible via `.int` and reverse-looked up via `.from_int(?T)`.

### Feature — `case .arm as binding` Syntax

Variant pattern matching now uses `as` instead of parentheses for the binding:

```gengo
switch ev {
    case .submit as job { ... }
    case .finish as id  { ... }
}
```

### Feature — Default Parameter Values

Trailing parameters may declare defaults with `=`. Callers can omit any suffix of defaulted parameters:

```gengo
func greet(name string, greeting string = "Hello") string {
    return greeting + " " + name
}
greet("World")          // "Hello World"
greet("World", "Hi")    // "Hi World"
```

### Feature — Numeric Literal Bases

Integer literals now support hexadecimal, binary, and octal bases with optional digit separators:

```gengo
0xFF   0b1111_1111   0o377
```

### Feature — `std.JSONValue` / `json.parse_value`

`std.json.parse_value(src)` parses JSON into a typed variant for exhaustive pattern matching. See v0.5.0-pre3 entry for full details.

### Fix — GC Stress Crashes in Native Modules

Several native modules panicked under `-Dgc_stress=true`. All resolved.

### Fix — Zero-Initialise Struct and Enum `var` Declarations

`var x MyStruct` and `var x MyEnum` now produce valid zero values instead of crashing.

### Fix — Homogeneous Array Literals

Mixed-type array literals are now a compile error. `[1, 2.0]` is rejected; write `[1.0, 2.0]` instead.

## 2026-06-21 (v0.5.0-pre3)

### Breaking — Build Presets Renamed

The preset names now reflect their memory budgets directly:

| Old | New | Heap |
|---|---|---|
| `tiny` | `256k` | 256 KiB (doubled from 128 KiB) |
| `dev` | `1m` | 1 MiB |
| `server` | `16m` | 16 MiB |
| `stress` | dropped | — |
| *(new)* | `unlimited` | 256 MiB |

`stress` is removed as a preset; GC correctness testing is now
`-Dgc_stress=true` (independent of preset). Update all `-Dpreset=` invocations.

### Feature — `std.JSONValue` and `json.parse_value`

`std.json.parse_value(src)` parses a JSON string and returns a `std.JSONValue`
variant value, safe for exhaustive pattern matching with `switch`:

```gengo
doc := std.json.parse_value(src)
switch doc {
    case .jobject as m    { std.io.println(m["name"]) }
    case .jarray as items { std.io.println(std.core.len(items)) }
    case .jnull         { std.io.println("null") }
}
```

Arms: `jnull`, `jbool(bool)`, `jint(int)`, `jfloat(float)`, `jstr(string)`,
`jarray([]JSONValue)`, `jobject([string]JSONValue)`. The type is accessible as
`std.json.Value` or `std.JSONValue`.

### Feature — Recursive Struct Types

Struct fields typed as `[]T`, `[K]V`, or `?T` may now reference the enclosing
struct, enabling recursive data structures:

```gengo
type Node struct {
    value    int,
    children []Node,
}

type Tree struct {
    value int,
    left  ?Tree,
    right ?Tree,
}
```

Direct inline self-reference (non-reference field) remains a compile error.

### Feature — Type-Qualified Defer Calls

`defer TypeName.method(instance)` promotes the first argument to receiver
position, useful when the instance is an expression rather than a named
variable:

```gengo
defer Database.close(open(":memory:"))
```

### Feature — Compile-Time Name Check for Struct Literals

`Name{}` and `Name{ field: value }` now produce a compile error if `Name` is
not a registered type. Previously an unknown name followed by `{}` would
silently fall through to a block expression.

### Fix — `recover()` Clears Error Buffer

After a successful recovery the stale panic message is now cleared. Previously
`recover()` left the previous error string in the buffer, which could be read
by subsequent error-introspection calls.

### Fix — Named Type Subtypes Inherit Parent Methods

Methods defined on a parent named type are now accessible on subtypes without
re-declaration.

### Fix — Constant Folding Correctness

- `int / int` constant folding now produces `float` (true division), matching
  runtime behaviour.
- Float division and modulo by zero constant-fold to `null` instead of `+Inf`,
  so the runtime division-by-zero handler fires correctly.

### Performance — Value Size 24 → 16 Bytes

`Value` shrunk from 24 to 16 bytes via `StringSlice` indirection, reducing
stack and heap pressure across all workloads.

### Performance — Call-Site Inline Cache

The `call` opcode caches the last-seen callee's function pointer. Repeated
calls to the same global or closure skip the type-check dispatch on the hot
path.

### Performance — Compile-Time Constant Folding

Literal arithmetic expressions (`1 + 2`, `10 * 3`, etc.) are evaluated at
compile time and emitted as a single constant.

## 2026-06-18 (v0.5.0-pre2)

### Breaking — `and` / `or` / `not` Replace `&&` / `||` / `!`

Boolean operators are now Go-style keywords. `&&`, `||`, and `!` are rejected
at the lexer level. Update all boolean expressions. See commit `1aec116`.

### Breaking — Untagged Unions and `any` Removed

`any` is no longer a valid type. All struct fields, function parameters, and
variable declarations must carry explicit type annotations. Untagged union
fields (`field string | int`) are replaced by named variant types.
See commit `e89c965`.

### Breaking — NaN/Inf Rejected in Named-Type Construction

`type Meter float; Meter(math.inf)` now panics `TypeError` instead of
silently constructing an invalid named value. Closes #145.

### Feature — Compile-Time Undefined Global Detection

A pre-scan pass collects all top-level declaration names before compilation.
References to undeclared globals at the outermost scope are now rejected with
`UndefinedVariable` at compile time instead of failing at runtime with
`NotDefined`. Forward references within the same module work correctly.
Closes #152.

### Feature — `-e` / `--eval` Inline Code Execution

`gengo -e 'std := import("std"); std.io.println("hello")'` runs a snippet
without a source file. See commit `5bf039c`.

### Feature — `.type` Switch Dispatch for Union-Typed Values

Values declared as `string | int | bool` can be dispatched with
`switch v.type { case string: … case int: … }`. See commit `e1a4e64`.

### Feature — `cycle` Constraint for Float and Decimal Named Types

`type Angle float { cycle 0.0..360.0 }` wraps on overflow. Previously
restricted to integer types. See commit `f00b943`.

### Feature — `default` Clause for Named Scalar Types

`type Port int { default 8080 }` makes `var p Port` initialise to 8080
instead of zero. Subtypes inherit the parent's default. See commit `f5ef229`.

### Feature — Interface and Struct Contracts on Typed Var Declarations

`var conn DbConn` where `DbConn` is an interface now validates that the
zero value satisfies the interface at declaration time. Closes #143.

### Fix — Closure Self-Reference via varDecl Pre-Allocation

`var fib = func(n int) int { return fib(n-1) + fib(n-2) }` and any
closure that calls itself by name now works correctly. The varDecl cell
is allocated before the initialiser executes so the upvalue chain is
populated at first call. See commit `7d071b9`.

### Fix — MaxGlobals Raised from 256 to 2048

Scripts with many top-level declarations no longer hit `TooManyGlobals`.
The accompanying GC scan was O(N×TableSize); replaced with a compact
values array giving O(N) marking. Closes #154.

### Fix — `std.core.has` Uses Hash Table on Hashed Maps

`std.core.has` previously did a linear scan even on `map_hashed` objects,
making it O(N). Now it uses the hash table path for O(1) average lookup.
Closes #164.

### Performance — Superinstruction Expansion

Several new fused opcodes reduce dispatch counts in hot paths:
- `get_local_ret`: load-and-return in one dispatch
- `get_local_const_sub_call`: `n-1` / `n-2` recursive call pattern
- `add_ret`: add-and-return for binary recursive functions
- `local_add_const` / `local_add_local`: read-modify-write loop counters
- `std.*` direct-call lowering: `std.math.abs(x)` compiles to
  `get_global "module:std.math.abs" + call` — 2 dispatches instead of 4

### Hardening — Bytecode Verifier

`chunk.verify()` runs before every execution, checking that all constant
indices are in-bounds and all jump targets land on instruction boundaries.
See commit `fc7e47f`.

### Docs — VM Architecture Reference

`dev-docs/design/vm-architecture.md` — comprehensive developer reference
covering value/object types, chunk format, dispatch loop, peephole fusions,
inline caches, GC invariants, call protocol, closures, and the active-state
model. Closes #176.

## 2026-06-12 (v0.5.0-dev)

### Fix — Enum Subtype Members Validated at Declaration

`subtype Bogus Days { tuesday }` with a member the parent does not have
is now a compile error (`'tuesday' is not a member of Days`) instead of
compiling silently and failing at first use. The registry carries enum
member lists, so chained enum subtypes validate too. REPL caveat: a
parent enum declared on an earlier line has no persisted members yet,
so validation skips there (#115 tracks the REPL enum-subtype gaps).
See issue #114. Fail test: spec fail/212.

### Breaking — Boolean-Only Conditions (Go-Style)

`if`, `!`, `||`, `&&`, and template `{{if}}` now require actual `bool` values.
Non-boolean values that were previously treated as truthy/falsy (non-zero
integers, non-null strings, etc.) now produce a runtime `TypeError`. This
eliminates a class of subtle bugs where a non-boolean expression slips into a
condition. Use `std.conv.to_bool` for explicit conversion. See issue #109.

Positions affected:
- VM opcodes: `.jif_pop`, `.jump_if_false`, `.not`
- Template: `{{if}}` condition
- Array stdlib: `filter`, `find`, `findIndex`, `all`, `any` predicate return
- Sort stdlib: custom comparator fallback (non-int, non-float return)

The internal `isTruthy()` function on `Value` has been replaced with
`asBool()` that returns `TypeError` for non-boolean values. The errors name
the offending type and the remedy (`condition must be bool, got int; use a
comparison or std.conv.to_bool`; `predicate must return bool, got null`).
Fail tests: spec fail/196–199.

Named types over `bool` participate in conditions through their base
(`type Flag bool` makes `if Flag(true) { }` valid), the same way named
ints participate in arithmetic (spec 194). Generalising `subtype` beyond
numeric parents is tracked as #113.

`std.conv.to_bool` is the one explicit conversion and now treats heap-backed
strings like literals (`to_bool("")` and `to_bool(trim(" "))` are both
`false`) and converts named values through their underlying value
(spec 193).

### Breaking — Type Names Cannot Be Shadowed

No binding form may use a type name: function/variable/loop-variable
names, parameters, receivers, named returns, multi-assign targets, and
variant case bindings all reject primitive type names (`int`, `float`,
`bool`, `string`, `rune`, `decimal`, `error`, `any`, `map`) and every
registered named/struct/interface/variant type. `var bool bool`,
`func string() {}`, and `add(float float)` are now compile errors
naming the offence. Fail tests: spec fail/207–211.

### Improved — Bare Type Parameters in Interface Specs

Interface method parameters can be written as bare types, Go-style:
`add(float) float` is now valid alongside `add(x float) float` — the
names were documentation only, since interface methods have no body.
The language guide gains an Interfaces section. Spec 196.

### Improved — Subtypes of Any Scalar Named Type

`subtype Child Parent` now accepts any scalar named parent — `bool`,
`string`, and `decimal` join `int`/`float`/`rune`. A subtype without a
constraint is a distinct, substitutable name for the parent's domain
(`type UserId string` → `subtype AdminId UserId`), following the Ada
model. `range`/`cycle` constraints still require a numeric parent, and
non-scalar parents (arrays, maps) are rejected with a clear message.
Decimal subtypes inherit the parent's scale. Bare `subtype X SomeEnum`
now explains that enum subtypes take a member subset. See issue #113.
Spec 195, fail/203–206.

### Fix — REPL Named Types Persistence Across Lines

`type`, `subtype`, `struct`, `interface`, and `variant` type declarations now
persist across `runIncremental` calls. Previously the `TypeRegistry` was reset
on each call, causing type annotations, `subtype`, and `var x TypeName` to fail
on subsequent REPL lines. Now the `Runtime` stores type names in the same
pattern as `repl_const_names`, and pre-populates the registry before
compilation while skipping `registry.reset()` in REPL mode. The persisted
name buffer is compacted per line with overlap-safe copies so earlier type
names survive later declarations. See issue #112.

### Fix — Diagnostics: Misleading Errors from Module Load, Host Imports, String Pool

Three misleading error scenarios are now fixed (see issue #98):

1. **Module load failure** — When a module's compilation fails, its record is
   now marked `.failed` instead of staying in `.loading`. A subsequent import
   of the same module re-reports the original compile error instead of a
   misleading `ImportCycle` error.
2. **Host module exports** — Accessing a non-existent field on a host module
   (e.g. `db.nonexistent()`) now produces a compile-time error instead of
   surfacing only at call time.
3. **Lexer string pool exhaustion** — When the 128KB string pool overflows,
   the lexer now reports `"string pool exhausted (max 128KB)"` instead of the
   misleading `"unterminated string"` error.

### Improved — Named String Types Concatenate

`+` on two values of the same named string type (or subtype) now works and
keeps the named type: `Html("<p>") + Html("</p>")` is an `Html`. Mixing
different named types or a named type with a bare string remains a
`TypeError`. See issue #110. Spec 192, fail/201–202.

### Fix — Regexp Character Class Leading Dash

A `-` at the start of a character class (`[-:]`) is now a literal dash, as
in every mainstream engine; previously the class silently matched nothing.
See issue #111. Spec 190.

### Fix — Named Types, Enums, and Variants Satisfy Interfaces

`matchesInterfaceType` only recognised struct instances; named values, enum
values, and variant values with matching methods now satisfy interface
checks too. Spec 191, fail/200.

## 2026-06-12 — v0.4.1

### Fixed — Cross-Platform Release Builds

v0.4.0 shipped no binaries: the release workflow failed to cross-compile.

- **macOS** — `timeval.usec` is `c_int` on Darwin but `i64` on Linux; the
  `cap:net` deadline code now casts to the platform's field types.
- **Windows** — `cap:fs` read/exists used `std.posix.openat` (absent on
  Windows) since the post-v0.3.1 perf rewrite (#73); on Windows they fall
  back to the `std.Io` implementation that v0.3.1 shipped.

No language or runtime behavior changes on Linux. Released from the
`release/0.4` branch (v0.4.0 content plus the build fixes).

## 2026-06-12

### Infrastructure — Versioning Discipline

The engine now carries a single source-of-truth version string (`0.4.0` in
`build.zig`) that is embedded in all artifacts:

- **CLI** — `--version` flag prints `Gengoscript v0.4.0` and exits.
- **C API** — `gengo_engine_version()` returns the bare, machine-parseable
  version string (`"0.4.0"`); display branding is left to the caller.
- **TS SDK** — `package.json` version is kept in sync with the engine.
- **README** — Status section documents pre-1.0 stability policy.
- **CONTRIBUTING** — Documents the versioning and tagging workflow.

Every breaking change from now on is tagged, documented in the changelog, and
never happens silently. See issue #106.

## 2026-06-11

### Breaking — Strict int/float Comparison

Ordering comparisons now follow the same strictness as arithmetic: `1.5 > 1`
is a `TypeError`, matching `1.5 + 1`. Previously comparison silently allowed
the mix while arithmetic rejected it. Equality (`==`) is unchanged and still
evaluates to `false` across types. (Precedent: Ada and Go forbid mixed typed
values in both arithmetic and comparison; their leniency exists only for
adaptable literals, which Gengoscript does not currently have.)

### Improved — Runtime Errors Explain Themselves

Type and range errors from arithmetic, comparison, unary negation, and
named-type construction now carry messages naming the operand types and the
remedy (`cannot mix Age and int; wrap the int with Age(...) or unwrap the
named value with int(...)`; `Age: -1 is outside 0..200`). The REPL prints
the same `--> repl:line:col` location block as file mode, and embedding
hosts receive the messages through the existing error buffers.

### Breaking — Strict Nominal Types in Arithmetic and Comparison

Named-type values no longer mix with bare base-type values in arithmetic,
comparison, or compound assignment. `Severity(4) >= 3` is now a runtime
`TypeError`; write `Severity(4) >= Severity(3)` or unwrap explicitly with
`int(s) >= 3`. Mixing two different named types was already rejected; this
closes the named+base loophole so a named value's domain guarantees cannot
be bypassed mid-expression. Fail tests: spec fail/189–191.

### Fix — Expression Recursion Depth Limit

Deeply nested expressions now fail compilation with `ExpressionTooDeep`
(limit 256) instead of risking a host stack overflow (#99).

### Fix — By-Value `api.Runtime.init` Allocates Heap Backing

`api.Runtime.init(config)` previously skipped heap initialisation on native
targets, so the first `run()` panicked; it now routes through
`initWithConfig` like the in-place initialiser (#100).

### Fix — Peephole Fusion Across Patched Jump Targets (BadConstantIndex)

Short-circuit boolean expressions whose operands compare a local against a
constant could panic at runtime with `BadConstantIndex` (e.g.
`if a == "x" or a == "y"` when the first comparison is true). The `||` / `&&`
short-circuit jump is patched to land at the current end of code; pending
peephole state survived the patch, so a following `jif_pop` quad-fused into
the instruction at the jump target, leaving the jump pointing at operand
bytes. `patchJump` now clears all fusion trackers — a patched jump target is
an instruction boundary. Regression test: spec 186.

### New Example — Mosquitto ACL Plugin

`examples/mosquitto-acl/`: a Mosquitto v5 broker plugin (C) that delegates
ACL and basic-auth decisions to a Gengoscript policy script via the C engine API.
Fail-closed, per-call instruction budget, SIGHUP policy reload.

## 2026-06-09

### Fix — NaN/Inf Rejection in VM Arithmetic and Comparisons

Non-finite float values now produce a runtime error at the point of use rather than propagating silently or causing undefined behaviour in debug builds.

- **Arithmetic**: `pushNumericResultWithCarrier` rejects non-finite results with `TypeError`. Integer overflow in decimal add/sub/mul now uses `@addWithOverflow`/`@subWithOverflow`/`@mulWithOverflow`; `minInt(i64) / -1` is guarded. String concatenation length overflow is detected via wrapping arithmetic.
- **Comparisons**: `gt`, `lt`, `const_lt`, and `get_local_const_lt_jif_pop` all guard against NaN/Inf operands (`TypeError`).
- **Decimal construction**: constructing a decimal named type from a float that is non-finite or out of `i64` range now returns `TypeError` instead of invoking undefined behaviour via `@intFromFloat`.
- **`succ`/`pred`**: stagnation check (`result == n`) catches Inf and values too large for f64 to increment; returns `RangeError`.
- **`int()` cast**: NaN and out-of-range floats return `RangeError` (consistent with other range-overflow paths).
- **`defer_call`**: stack underflow guard added.
- Conformance tests added: spec 165–171 (NaN/Inf failure cases), 172 (NaN detection), 173 (decimal overflow).

### Fix — Compiler Safety Guards

- `arity + named_return_count > MaxLocals` now returns `TooManyLocals` instead of silent miscount.
- Assignment path `step_count` (a `u8`) guarded against paths longer than 255 segments.
- `repl_expr_pop_pos` assignment guarded against `codeLen() == 0` underflow.

### ABI Change — Column Counters Widened to `u32`

`CompileError.col` and `RuntimeError.col` in `api.zig` (and the corresponding fields in `Compiler`, `Session`, `Runtime`, and `Engine`) have been widened from `u16` to `u32`. This prevents a debug-mode panic on source lines longer than 65 535 characters.

**Hosts must recompile against updated headers.** Any host reading `col` from a `CompileError` or `RuntimeError` struct compiled against the old layout will get incorrect values.

---

## 2026-06-08

### Embedding — Per-instance Resource Limits (#57)

`engine_init_with_config` now accepts an `InstanceConfig` struct (56 bytes, all `i64`/`u8`) that sets per-engine heap and execution limits, overriding preset defaults for that instance. Fields: `heap_size_bytes`, `max_objects`, `max_stack`, `max_frames`, `max_defers`, `max_ops` (`-1` = preset default), `allow_io`. See `docs/engine-api.md` for the full layout.

### Embedding — Custom Allocator in Engine Config (#71)

`api.Config` gains an `allocator` field (`std.mem.Allocator`, default `page_allocator`). The allocator is used for all per-instance backing memory and must remain valid until `rt.deinit()` is called. `Runtime.deinit()` added; required when using a non-default allocator.

### Embedding — ValueWire Exhaustive Mapping (#70)

`engine_call` / `engine_run` return values no longer silently drop non-primitive types. New mappings:

| Gengoscript type | Wire tag |
|---|---|
| `struct` | `5` (`map`) — field names as keys |
| `rune` | `1` (`number`) — Unicode code point |
| named/enum value | unwrapped to underlying wire type |
| `error` value | `1` (`number`), payload `-2` |

### Performance — `cap:fs` Cold-start (#73)

`fs.read` and `fs.exists` now use `std.posix.openat` + read loop directly instead of `std.Io.Threaded`. Eliminated ~900 ms startup cost from thread-pool and io_uring initialisation. Measured: ~2 ms per call.

### Fix — `engine_last_error` on Init Failure (#74)

`engine_init_with_config` returning `-3` (config ceiling exceeded) now writes a descriptive message to a module-level buffer (`g_init_error`). `engine_last_error(0, ...)` reads from this buffer when the handle is invalid, so callers can retrieve the failure reason without a valid engine handle.

### Fix — `cap:http` Availability

`cap:http` is now importable from Gengoscript scripts and dispatches to the host HTTP handler. Added conformance spec tests with a mock handler. HTTP calls still incur ~900 ms cold-start on the native CLI due to `std.Io.Threaded` in the HTTP implementation (tracked in issue #72).

### Fix — Template GC Safety

Three GC use-after-free bugs in template rendering corrected: `tplValToDynStr` result rooted across `tplAppendToBuilder`; template object and range array rooted across GC during rendering; `tplBuildObj` ops/args/jmp rooted before any allocation.

### Fix — Zig 0.16.0 Alignment Syntax

`heap.init` uses `.@"16"` alignment tag to satisfy the `?mem.Alignment` enum requirement in Zig 0.16.0 (`alignedAlloc(u8, .@"16", size)` instead of `alignedAlloc(u8, 16, size)`).

---

## 2026-06-07

- **Variant records**: variant types may now declare bare shared fields alongside arm declarations. Shared fields are unconditionally accessible on any value of the type without a match. Construction supplies shared and arm-specific fields together in one struct literal.
- **Multi-field variant arms**: variant arms may now use `{ field Type, ... }` syntax to carry a struct-like record payload. The payload struct is bound in pattern matching and accessed via dot.
- **fix**: predicate closure no longer collected by GC in long loops (`NotAFunction: inside predicate for X`). The `named_type` GC mark path now traces the predicate field.

## 2026-06-06

### Language — Predicate Subtypes

Named types may include a predicate body that is evaluated at construction time:

```gengo
type Port int predicate func(x) { return x >= 1 and x <= 65535 }
p := Port(80)    // ok
p2 := Port(0)    // PredicateViolation
```

- The predicate function takes the raw value and must return `boolean`.
- Construction raises `PredicateViolation` if the predicate returns `false`.
- The body compiles as a closure and may capture variables from the enclosing scope.

### Language — `std.string.contains` + `std.core.contains` TypeError

- `std.string.contains(s, sub)` — new function; returns `true` if `sub` appears anywhere in `s`.
- `std.core.contains(arr, value)` now raises `TypeError` when the first argument is not an array.

### Embedding — Host ABI v2

Extended host ABI with five new call IDs for `std.conv.*` and `std.core.bytelen`:

| ID | Name |
|----|------|
| `5` | `core_bytelen` |
| `6` | `conv_to_int` |
| `7` | `conv_to_float` |
| `8` | `conv_to_bool` |
| `9` | `conv_to_string` |

ABI version bumped to `2`. Capability bits `3`–`7` guard the new calls; the VM falls back to embedded implementations when a capability bit is absent.

### Embedding — Host-Defined Module Registration

Host code can register named modules that Gengoscript scripts import by name:

```c
gengo_host_module_func_def_t funcs[] = {
    { .name_ptr = (uintptr_t)"add", .name_len = 3, .arity = 2 },
};
engine_register_module(handle, "mylib", 5, funcs, 1);
```

Scripts import with the `host:` prefix: `mylib := import("host:mylib")`. Calls are dispatched via the host's `nativeCallRaw` implementation.

New engine exports: `engine_register_module`, `engine_set_write_fn`, `engine_last_error_line`, `engine_last_error_col`.

### Embedding — ValueWire Arrays and Maps

Two new `ValueWire` tags:

| Tag | Name | `payload` | `len` |
|-----|------|-----------|-------|
| `4` | `array` | pointer to element sequence in engine memory | element count |
| `5` | `map` | pointer to interleaved key/value pairs in engine memory | pair count |

### Embedding — Native Shared Library (`libgengo-engine`)

New build targets produce a native shared library with the same API as `gengo-engine.wasm`:

```bash
zig build -Dpreset=dev engine-native          # debug build
zig build -Dpreset=dev engine-native-release  # optimised build
```

Output: `zig-out/lib/libgengo-engine.so` (Linux), `.dylib` (macOS), `.dll` (Windows).

The C header `gengo-engine.h` documents the full API. All pointer parameters use `uintptr_t` so the API is correct on 64-bit hosts as well as 32-bit WASM.

`engine_set_write_fn` must be called to receive output; the native target has no WASM import shim to capture writes.

### Embedding — TypeScript SDK

`sdk/typescript/` — a TypeScript wrapper for `gengo-engine.wasm` with a typed `GVal` encoding/decoding layer and a high-level `GengoEngine` class.

### REPL Improvements

- **Auto-print** — top-level expression results are automatically printed in the interactive session.
- **Typed redeclaration detection** — redeclaring a typed global with a conflicting type is now a compile error.
- **Error display** — compile errors show the source line with a caret pointing at the bad token.

Invoke the REPL by running `gengo` with no arguments on an interactive terminal.

### Platform — Windows Native CLI

The native CLI now builds and runs on Windows without libc (`no-libc` mode). Release CI re-enabled for `x86_64-windows`.

### Removed — `std.time.sleep`

`std.time.sleep` was removed from the standard library.

---

## 2026-06-05

### Language — Compile-time Field Validation on Imported Modules

The compiler now validates field accesses on imported module namespaces at compile time. Accessing a name that is not exported by the module raises a `CompileError` instead of silently producing `null` at runtime.

### Runtime — Typed Array Element Enforcement

Variable declarations typed as `[T]` (e.g., `items [int] = ...`) now enforce element types on every assignment, not only at initial construction.

### VM / GC Bug Fixes

- GC marking: verify that an iterator's source object is live before tracing its children (#28).
- GC: retry closure upvalue bump allocation after triggering a collection (#27).
- `for-in break`: correctly clean up the iteration stack frame to avoid a stack leak (#29).
- `cast_int` from float: bounds-check before truncating to prevent integer wrap-around (#30).
- Rune cache: fix overflow flag and validity ordering for strings near the cache boundary (#31).
- Defer + panic: release temp GC roots when `retSlowPath` fails mid-defer execution (#32).

---

## 2026-06-04

### Language — Tail-Call Optimization

Self-recursive and mutually recursive tail calls are now compiled into back-edge jumps rather than new call frames. Deep recursion (tested at 10 000 levels) no longer overflows the call stack.

### Standard Library — `std.regexp`

Regular expression matching with a backtracking NFA engine:

```gengo
std := import("std")
assert(std.regexp.match("^hello", "hello world"))
found := std.regexp.find("world", "hello world")  // "world"
all   := std.regexp.find_all("a", "banana")        // ["a", "a", "a"]
r     := std.regexp.replace("world", "hello world", "there")
parts := std.regexp.split(",", "a,b,c")            // ["a", "b", "c"]
```

`std.regexp.compile(pattern)` returns a reusable compiled regexp object that also supports method-call syntax (`re.match(s)`, `re.find(s)`, etc.).

Errors: `InvalidRegexp` on a malformed pattern.

Supported syntax: `.` `*` `+` `?` `^` `$` `|` `()` `[...]` `[^...]` character classes and ranges, `\d` `\D` `\w` `\W` `\s` `\S` shorthands.

### Standard Library — `std.fmt`

`std.fmt.format(fmt, ...args)` — returns the formatted string (formerly `std.io.sprintf`).

`std.fmt.stringify(v)` — renders any value to a string, exactly as `std.io.println` would display it.

Additional verb: `%x` / `%X` — hexadecimal integer.

---

## 2026-06-03

### Build — Native Zig Test/Bench Runners

Replaced all shell-script test/bench harnesses with native Zig executables built and run directly by `build.zig`:

- `src/test_runner.zig` — unified runner for conformance, benchmarks, and parity tests
- `src/bench_perf_runner.zig` — perf-counter benchmark runner

Removed:
- `tests/run_conformance.sh`
- `tests/run_bench.sh`
- `tests/run_host_parity.sh`
- `scripts/perf/run.sh`

No `WASMTIME_BIN` environment variable is required. The `-Dwasmtime=` build option (default `wasmtime`) is passed directly to the native runners.

## 2026-06-01

### Language — Zig-style `\\` Multiline Strings

Multiline string literals now use `\\` prefix on each line, identical to Zig.

- Content after `\\` is taken **literally** — no escape processing.
- Each line contributes its content plus a trailing newline (including the last line).
- Consecutive `\\` lines at any indentation are joined into a single string value.
- A blank line or any non-`\\` line terminates the literal.

```gengo
msg :=
    \\Hello, world!
    \\Escape seqs like \n and \t are NOT processed.
    \\Quotes like "this" need no backslash.

std.io.print(msg)
```

The old continuation-marker multiline syntax (repeating the opening quote at the
same indentation column) has been removed. Single-line `"..."` and `'...'`
strings are unchanged; they now reject embedded newlines rather than silently
treating them as a continuation attempt.

**New:** `std.io.print(...args)` — prints without a trailing newline, useful
when printing `\\` multiline strings that already end with `\n`.

### VM — Monomorphic Inline Caches for Struct Access

Three self-patching call-site caches eliminate the dominant hot-path costs for
struct-heavy code.

**`get_field` / `set_field` opcodes** replace `constant(name) + get_index` /
`constant(name) + set_index` for all dot-access (`.field`) reads and writes.
Each instruction embeds a 2-byte type-pool index and 1-byte field index as a
cold slot (0xFFFF / 0xFF). The first execution does a `findFieldIndex` linear
scan and writes the results back into the live bytecode. Every subsequent call
to the same struct type reads the cached slot index directly — O(1) instead of
O(fields).

**`invoke_method` IC** — four bytes appended after `argc` (ic_type:u16,
ic_func:u16) cache the struct type and resolved function object pool indices.
On a hit the function value is fetched directly, skipping the
`"TypeName.method"` string construction and `globals.get()` hash lookup.

All non-struct access paths (maps, enum types, named types, variant types) fall
through to the existing logic; the IC bytes are simply read and discarded.

Compiler: `infixExpr`, `deferStmt`, `emitAssignTargetPath`, and
`propertyAssignStmt` updated. `propertyAssignStmt` refactored to track last
step kind; compound assignment (`+=` etc.) on a dot field now emits
`dup + get_field + expr + op + set_field` instead of `dup2 + get_index + …`.

## 2026-05-31 (6)

### VM — Iterative GC Marking

Replaced the recursive `markObject` traversal with an explicit worklist-based marking phase. A file-local `mark_worklist[MaxObjects]` array holds pending objects; each object is marked *before* being queued, so it can never appear twice. The previous recursion depth was proportional to the live-object graph depth (worst case MaxObjects = 2048 frames), which could overflow the native stack in WASM for pathological inputs. The new approach processes all reachable objects in bounded O(live_objects) iterations with no recursion.

### VM — `std.string.builder`

New `std.string.builder()` native that creates a mutable string accumulator backed by the managed heap's size-class allocator. Internal buffer doubles (via the next size class) each time the content overflows capacity, giving O(total_bytes) total work for N appends versus O(N²) for repeated `s = s + piece` concatenation.

```gengo
std := import("std")
b := std.string.builder()
b.write("hello")
b.write(", world")
std.io.println(b.str())   // "hello, world"
b.reset()
b.write("again")
std.io.println(b.str())   // "again"
```

Methods: `.write(s string)`, `.str() string`, `.reset()`.

### Compiler/VM — Constant pool expanded to 512 (u16 indices)

Constant indices are now encoded as 2-byte big-endian `u16` values instead of 1 byte. The pool limit rises from 256 to 512 unique constants per compilation unit. String constants continue to be deduplicated, so the effective headroom for large scripts is significantly higher. All opcode sequences that reference the constant pool (`constant`, `def_global`, `get_global`, `set_global`, `make_closure`, `invoke_method`, `defer_invoke_method`, `variant_check`) now consume one extra byte per reference.

## 2026-05-31 (5)

### Type System — Subtype Declarations (Stage 3)

Subtypes create a constrained view of an existing named scalar type with an explicit, tracked ancestry relationship.

**Declaration syntax:**
```gengo
type Percent int range 0..100
subtype FailingGrade Percent range 0..59
subtype PassingGrade Percent range 60..100
```

The `range` clause is optional; if omitted the subtype inherits the parent's range. The subtype's range must lie within the parent's range (compile-time `RangeError` if violated).

**Widening (implicit, safe):** A subtype value is accepted anywhere its parent (or any ancestor) type is expected:
```gengo
func showPercent(v Percent) { std.io.println(v) }
showPercent(FailingGrade(40))  // OK: FailingGrade widens to Percent
```

**Narrowing (explicit, range-checked):** Assigning a parent value to a subtype variable requires an explicit constructor call:
```gengo
base Percent = Percent(30)
narrow FailingGrade = FailingGrade(base)  // range-checked at runtime
```

**Arithmetic with subtypes:**
- `T_sub op T_sub → T_sub`, range-checked against the subtype's range
- `T_sub op T_parent → T_parent`, range-checked against the parent's range
- `T_parent op T_sub → T_parent`, same
- `T_sub op T_sibling → TypeError` (siblings of the same parent do not implicitly unify)

**Comparison with subtypes:**
- `T_sub cmp T_parent → bool` and `T_parent cmp T_sub → bool` are allowed
- `T_sub cmp T_sibling → TypeError`

**Type attributes** (`T.name`, `T.first`, `T.last`) work on subtypes and reflect the subtype's own name and range.

## 2026-05-31 (4)

### Type System — Variants + Pattern-Matching Switch (Stage 5)

**Variant type declarations:**
```gengo
type Decision variant {
    allow,
    deny(reason string),
    review(reason string)
}
```
Each arm may have zero or one payload (optionally with a field name for documentation). Multiple fields can be composed via a struct payload.

**Construction:**
- Payload-less arm: `Decision.allow` — returns a variant value directly
- Payload arm: `Decision.deny("msg")` — calls the arm constructor with the payload; type-checked at construction

**Pattern-matching switch** with `.arm_name` patterns:
```gengo
switch d {
    case .allow { std.io.println("allowed") }
    case .deny as reason { std.io.println("denied:", reason) }
    default { }
}
```
The `.` prefix signals a variant arm pattern. Inside a function, the binding variable (`reason`) is a scoped local; at global scope it becomes a global.

**Type annotations:** `func handle(d Decision)` enforces that arguments are `Decision` variant values.

**Type attribute:** `Decision.name` returns the type name string.

**printValue:** variant values print as `TypeName.tag` or `TypeName.tag(payload)`.

**New opcodes:** `variant_check` (pop dup'd value, push bool matching arm tag), `variant_payload` (pop variant value, push payload).

## 2026-05-31 (3)

### Type System — Type Attributes (Stage 4)

Type objects now expose read-only attributes via `.name` property access.

**Named scalar types** (`type T int/float/... [range lo..hi]`):
- `T.name` → string name of the type
- `T.first` → named value `T(min)` — requires a range constraint, TypeError otherwise
- `T.last` → named value `T(max)` — same

`T.first` and `T.last` return proper named values so they can be used directly wherever a `T` is expected, including comparisons and return statements:
```gengo
func clampMonth(n int) Month {
    if n < Month.first { return Month.first }
    if n > Month.last { return Month.last }
    return Month(n)
}
```

**Enum types** (`type T enum { a, b, ... }`):
- `T.name` → string name of the type
- `T.first` → first enum value (ordinal 0)
- `T.last` → last enum value
- `T.values` → `array` of all enum values in declaration order

## 2026-05-31 (2)

### Type System — Typed Collections (Stage 2)

**Type annotations:**
- `array[T]` — typed array annotation; any array whose elements all satisfy `T`
- `map[K, V]` — typed map annotation; any map whose keys satisfy `K` and values satisfy `V`
- Unparametrized `array` and `map` continue to work as before (accept any element types)

**Named collection types:**
- `type Users array[User]` — nominal array type; only `Users([...])` produces a `Users` value
- `type Index map[string, User]` — nominal map type; same pattern
- Construction validates all elements/keys/values against the declared constraints

**Enforcement points:**
- Function parameters: `func f(ps array[Point])` rejects arrays with non-Point elements
- Struct fields: `type Batch struct { users Users, }` rejects non-Users values at assignment
- `std.core.append`: element type is checked when appending to a named array; named type is preserved in the return value
- Index assignment (`users[0] = x`): element type is checked on named array types
- Map insertion (`idx["k"] = v`): key and value types are checked on named map types

**All std.core collection functions** (`len`, `append`, `contains`, `remove`, `has`, `delete`, `keys`, `values`) transparently handle named collection types by unboxing.

## 2026-05-31

### Type System — Named Scalar Operator Enforcement (Stage 1)

Named scalar types now form proper nominal domains inside expressions, not just at
variable/field/parameter boundaries.

**Arithmetic rules:**
- `T op T → T`, result range-checked against the named type constraints
- `T op base → T`, result range-checked
- `base op T → T`, result range-checked
- `T op U → TypeError` when T and U are different named types

**Comparison rules:**
- `T cmp T → bool`
- `T cmp base → bool` (compares underlying value; e.g. `Age(20) == 20` is `true`)
- `base cmp T → bool`
- `T cmp U → TypeError` when T and U are different named types

**Unary operators:**
- `-T → T`, range-checked (e.g. `-Age(5)` is `RangeError` if range is `0..100`)
- `~T → T`, range-checked

**Explicit conversion remains the sanctioned escape hatch:**
- `int(age) + int(score)` is always allowed; the cast strips the named domain

## 2026-05-30

### Language
- Removed `var` keyword. Mutable typed declarations now use bare space syntax: `x int = 10`.
- Made function parameter types mandatory. Untyped params (`func f(x)`) are now a compile error.
  - Use `any` to explicitly accept any type: `func f(x any)`.
- `any` is now a first-class predeclared type equivalent to an empty interface. Every value satisfies it.
- Fixed GC corruption in `build_array`, `build_map`, and `build_tuple`: objects are now initialised to a valid empty state immediately after allocation, before any subsequent allocation that could trigger collection.

### Type Syntax (space everywhere, colon removed)
- All type annotations now use space syntax uniformly:
  - Struct fields: `type S struct { x int, y int }` (colon form `x: int` removed)
  - Function params: `func f(a int, b int)` (colon form `a: int` removed)
  - Typed variable declarations: `x int = 10` (colon form `x: int = 10` removed)
  - Single return: `func f(a int) int`
  - Multi-return: `func f() (result float, err ?error)` (parens required for 2+ returns)

## 2026-05-28

### Runtime / VM
- Added runtime instruction budget guard:
  - CLI flag `--max-ops <N>`
  - runtime error `InstructionBudgetExceeded` when budget is exhausted.
- Added `Runtime`-level isolation validation with interleaved multi-runtime mutable-call checks.
- Migrated runtime state ownership to per-instance activation model across:
  - `chunk`
  - `globals`
  - `heap`
  - `vm`
- Removed snapshot/restore-based runtime copy-back path and switched to active-state pointer activation.
- Added host-facing embedding layer:
  - `runtime/api.zig`
  - typed run/call result contracts for compile/runtime errors.
- Added embedding API validation runner (`embedding_runner.zig`) and hooked it into `zig build test`.

### Language
- Added `const` immutable bindings while keeping `:=` as first-class mutable declaration syntax.
- Added const binding enforcement (`AssignToConst`) for reassignment, compound assign, inc/dec, and direct multi-assign targets.
- Added declaration-side variadics (`...args`) with typed variadic argument enforcement.
- Added `std.io.printf(fmt, ...args)` with `%v`, `%s`, `%d`, `%f`, `%t`, and `%%`.
- Added Ada-inspired nominal scalar and range types:
  - `type Name Base`
  - `type Name int range a..b`
- Added runtime named-type constructors and range checks (`RangeError` on violation).
- Added enums:
  - `type Status enum { ... }`
  - qualified member access (`Status.pending`)
  - unqualified enum members no longer implicit globals.

### Benchmarks
- Added runtime call overhead benchmark:
  - `examples/bench/008_runtime_call_overhead.gengo`

## 2026-05-27

### Language
- Added multiline string literals for both escaped (`"`) and raw (`'`) modes.
- Added explicit multiline continuation marker behavior based on opening-quote indentation column.
- Added function parameter annotation support in both forms:
  - `param: Type`
  - `param Type`
- Added anonymous-function typed-parameter parser regression coverage (`t.value` selector case).
- Added `std.conv` namespace:
  - `to_int`
  - `to_float`
  - `to_bool`
  - `to_string`
- Switched string semantics to UTF-8 rune-oriented behavior:
  - `std.core.len` counts runes
  - string index/slice operate on rune positions
  - string iteration yields runes and rune indexes
- Added `std.core.bytelen` for raw UTF-8 byte length.
- Added first-class `rune` scalar and rune literals using backticks (single code point).
- Added rune/number numeric operator compatibility and cast coverage.

### Runtime / VM
- Added first-class `error` value helpers:
  - `std.core.error(msg)`
  - `std.core.is_error(v)`
- Added map/array/tuple multi-assignment and multi-return destructuring support.
- Added `switch` support (`case`/`default`, no fallthrough).
- Added GC-managed dynamic strings and managed collection storage paths.
- Added mark-sweep GC improvements:
  - proactive object threshold collection
  - heap-pressure-triggered collection
  - temp GC roots for in-flight allocations during native/build paths
  - stale/non-live object guard during mark traversal
- Added `std.core.gc_stats()` with:
  - `heap_used_bytes`
  - `heap_size_bytes`
  - `live_objects`
- Enabled host-backend parity for VM-local natives (`core.error`, `core.is_error`, `core.gc*`, `conv.*`) by executing them in guest VM.

### Limits / Memory
- Increased runtime heap arena default to `512 KiB`.
- Fixed managed block free behavior for dynamic-string class-sized blocks.
- Added build-time runtime limit presets:
  - `runtime/config_dev.zig`
  - `runtime/config_tiny.zig`
  - `runtime/config_stress.zig`
  - Make targets: `config-*`, `wasi-tiny`, `wasi-stress`

### Conformance
- Expanded spec coverage across:
  - struct contracts and methods
  - closures/upvalues
  - iteration forms
  - multi-return and path assignment
  - GC stress and dynamic string churn
  - multiline string pass/fail cases
- Added benchmark suite harness:
  - `examples/bench/*` with checked outputs
  - `tests/run_bench.sh`
  - Make targets: `bench`, `bench-tiny`, `bench-stress`
  - bench `.policy` support (`ALLOW_OOM`) for expected low-memory outcomes
  - `GENGO_BENCH_STATS=1` mode for elapsed/ops reporting
- Added backend parity harness:
  - `examples/parity/*`
  - `tests/run_host_parity.sh`
  - Make target: `parity`
- Added host-backend graceful fallback when host import is unavailable.

### Planning
- Added Host ABI parity roadmap document: `archive/host-abi-v2-plan.md`.

## 2026-05-26

### Language Foundation
- Established `std`-only import policy (`import("std")`).
- Added named function declaration sugar (`func name(...) { ... }`).
- Added strong struct contracts with typed/nullable/union fields.
