# Tasks (Actors) — Design Notes

**Status:** Draft (design only — no code written yet)\
**Scope:** Adding an isolated, message-passing concurrency primitive
(`task`) to Gengoscript. No OS threads under any circumstance — must run
under WASM, where threading isn't an option.\
**Examples:** `task-examples/` holds design-sketch programs (they do not
compile) written to pressure-test this syntax, plus `FINDINGS.md` — the
numbered issues they surfaced. Findings adopted into this doc are marked
with their revision.

**Revision history**
- 0.1 — Initial draft, capturing the full design conversation: concurrency
  semantics, isolation architecture, scheduling, mailbox/monitor behavior,
  and syntax.
- 0.2 — Completeness pass against the actual codebase. Corrects §3.2's
  per-task-cost claim (vm_state has its own WASM static backing, so tasks
  need a backing pool there after all); closes two type-soundness gaps
  (send-time message typing §5, mutable same-module globals §3.3); adds
  GC/compaction integration (§3.5), sendability rules (§3.4), scheduler
  and lifecycle specification (§4, §9), generation-counted `ActorRef` and
  `self()` (§7), a concrete `Down`-arm detection proposal (§6), and an
  implementation-mapping section tying the feature to the existing
  verifier/fusion/const-pool machinery (§10).
- 0.3 — Resolutions from writing realistic example programs (see
  `task-examples/`, especially `FINDINGS.md`). The two that changed the
  design: import bindings become implicitly const so tasks can use
  `std` (§3.3), and `receive()` becomes an unconditional yield point
  because run-to-block turned the documented requeue pattern into a
  livelock (§4.2, §5). Also: mailbox-less tasks (optional message type,
  §8.2), `ActorRef` zero value (§7), task-0 exemption from the
  Down-arm rule (§6), switch-on-`any` rule for main's receive (§9),
  precise top-level-vs-function-scope const wording (§3.3), and doc
  examples aligned to the codebase's lowercase arm convention (§8).

---

## 1. Goal and non-goals

Gengo should gain a `task` type: a unit of concurrent execution with its own
private state, reachable only through message passing, running without OS
threads. Named after Ada tasks, but the actual isolation/communication
semantics are Erlang's, not Ada's — see §2 for why.

Non-goals for v1, explicitly:
- Bounded mailboxes / backpressure (see §5).
- Bidirectional/lethal linking or supervision trees (see §6).
- True preemptive scheduling (see §4).
- Generic, task-type-parameterized actor handles (see §7).
- `receive` timeouts (`after`-clause equivalents) — see §5.1.

## 2. Concurrency model: Erlang semantics, Ada-scale expectations

The request that started this: a task/actor whose variables cannot be
shared with the outside world at all, communicating only through something
mailbox-shaped. That is Erlang's shared-nothing actor model, not Ada's —
real Ada tasks *do* share memory and synchronize via rendezvous
(`entry`/`accept`) or protected objects, which is the opposite of isolation.
So: `task` as the keyword (reads well, and matches the scale this will
actually run at), Erlang semantics underneath.

**Scale expectation is deliberately Ada-like, not Erlang-like.** Each task
needs its own execution state, and — depending on the isolation mechanism
chosen (§3) — potentially other per-task costs. This is expected to support
a modest number of long-lived concurrent units (workers, connections,
subsystems), not spawn-per-request swarms of thousands. Don't design v1
APIs assuming cheap, disposable, high-volume spawning.

**Determinism is a feature, not an accident.** Single-threaded cooperative
scheduling with a specified ready-queue order (§4.2) means every run of a
program is bit-for-bit reproducible — no interleaving nondeterminism, ever.
This matters beyond aesthetics: the spec-test suite, the emitter/defuse
differential tests, and GBC round-tripping all assume deterministic
execution, and tasks must not break that. Any future scheduling change
(§4) must preserve determinism or be explicitly opt-in.

**Cooperative also means not parallel, and user docs must say so early.**
Writing the examples made this concrete (`task-examples/08`): "spawn
three jobs" runs them strictly one after another at the spawner's first
yield — nothing ever overlaps. Everyone arriving from threads reads
spawn as parallel; the user-facing documentation (not just this design)
must kill that intuition on the first page, and the §4.2 scheduling
rules are user documentation, not internals — programs observably
depend on them.

## 3. Isolation architecture

### 3.1 Rejected: one Runtime per task

The obvious first idea — give each task its own `Runtime` (own heap, own
object pool, own globals), reusing the existing multi-runtime isolation
work (#190, "values must not cross runtimes") — turns out not to work on
the platform this feature actually needs to run on.

`heap.zig`'s `State.init`, on `wasm32` targets, points every field at a
single **global static struct** (`g_wasm_backing`), sized once from the
build's preset config:

```zig
if (comptime builtin.target.cpu.arch == .wasm32) {
    self.heap = &g_wasm_backing.heap;
    self.obj_pool = &g_wasm_backing.obj_pool;
    ...
```

Two `Runtime`s on WASM would alias the exact same backing memory — not two
heaps, one heap stomped by two owners. #190's concurrent-runtime test is
native-only (two OS threads, each with its own allocator-backed heap);
WASM has never been exercised with more than one *live* runtime at a time.
So "task = separate Runtime" is a non-starter on the required target.

A bounded static *pool* of backing slots (turn `g_wasm_backing` into an
array, cap concurrent tasks at build time) was considered as a way to keep
this approach's physical isolation guarantee. Not chosen — see 3.2.

### 3.2 Chosen: one shared heap, owner-tagged objects

Instead: one heap, one object pool (as today), with every object tagged
with which task owns it. This is the harder option, chosen deliberately
over the physically-isolated alternative because it scales further (no
per-task static memory reservation for *heaps*, no duplicated
globals/library setup) and matches what WASM's memory model already looks
like — there's only ever one heap either way, so this stops fighting that
instead of working around it.

**The isolation guarantee is primarily compile-time, not runtime-checked.**
If a task body cannot capture outer locals at all (§3.3), and the *only*
ways data enters a task are its own spawn parameters and message payloads
(both deep-copied — §3.4), then there is no syntax by which a task could
reference another task's data in the first place. The owner-tag on each
object exists as a debug-build safety net — the same role
`-Dheap_paranoia` already plays for a different invariant — not as a
mandatory production gate. A runtime-checked invariant with one missed
call site is exactly how the stale-slice-after-compaction bug class
happened; this feature shouldn't lean on that same failure shape as its
main correctness mechanism.

**What this reuses, concretely:**
- *Owner tag*: one more parallel array (`obj_owner: []TaskId`), indexed
  identically to the existing `obj_live`/`obj_marked` arrays in
  `heap.zig`. Sweep and compaction must maintain it in lockstep — see
  §3.5.
- *Per-task state*: `vm_state.State` (stack, frames, temp roots, defer
  stack, call depth) already represents "one thread of execution" — it
  becomes instantiable N times instead of once. `chunk`/`globals`/`heap`/
  `fs_state` go back to being genuinely shared and process-wide, which is
  *simpler* than #190's model (fewer pointers to swap, since only `vs`
  changes per task instead of all five). Concretely: library/declaration
  access from inside a task needs no special mechanism at all under this
  architecture — there's exactly one shared `globals` table, so "ambient
  access" isn't a feature to build, it's just the normal state of
  affairs. (This supersedes an earlier line of thinking — under the
  now-rejected separate-Runtime model, ambient library access would have
  needed a cheap re-instantiation story, e.g. via GBC; under the chosen
  shared-heap model that whole question doesn't arise.)

  **Correction (0.2): the WASM static-backing problem does not vanish
  under this model — it moves.** `vm_state.zig` has its *own*
  `g_wasm_backing` (stack, frames, defer_stack, panic_frames), aliased by
  every `State.init` on wasm32 exactly the way heap.zig's is. N live
  per-task vm_states on WASM therefore need the §3.1 "bounded static
  pool" idea after all — just at vm_state granularity, which is far
  cheaper than whole heaps (a stack + frame array per slot, no heap or
  globals duplication). Consequence: **`MaxTasks` is a build-time
  constant on WASM**, sized like the other preset ceilings, and the
  per-task stack/frame arrays should get their own (smaller) config knobs
  rather than inheriting the main program's `max_stack`/`max_frames` —
  a worker task rarely needs the headroom `main` does. Native targets
  can allocate vm_states from the runtime allocator and don't need the
  cap, but should honor `MaxTasks` anyway so programs are portable.
- *Scheduling*: reuse #190's active-pointer-swap mechanism, narrowed to
  swapping `vs` alone.
- *Cross-task copy* (spawn arguments and messages): this is deep-clone,
  and Gengo already has it — `cloneValue`/`nativeClone` in
  `native/core.zig` (the engine of `std.core.clone`), complete with
  visit-tracking bookkeeping. Reuse it as-is. (0.1 claimed the clone
  could skip cycle bookkeeping because the compiler statically rejects
  cyclic struct/array/map *type* compositions; true, but irrelevant —
  the existing implementation already pays for visit tracking, works on
  cyclic *values* where they can arise, and there is no reason to write
  a second, weaker clone.)
- *Copy timing*: copy at the crossing point (spawn call, or `send`), not
  lazily at the receiving end — mirrors real Erlang (BEAM copies to the
  receiver's heap at send time) and avoids a sender mutating a message
  after "sending" it but before the receiver has actually dequeued it.

**Residual cost, worth naming honestly:** things cached per-`vm_state`
today (regex pattern cache, time/json/template singleton-type caches) are
per-task under this model, so each task lazily rebuilds its own the first
time it touches that feature. Not a correctness issue, just another data
point for the Ada-scale expectation in §2.

**Future optimization with direct Erlang precedent, explicitly out of
scope for v1:** immutable string *bytes* don't need copying — sharing the
underlying byte data across tasks while copying only the slice header is
exactly what BEAM does for large refc binaries. v1 copies everything for
uniformity; if message-heavy workloads show string copying to matter,
this is the known escape hatch, and it requires no semantic change
(strings are immutable values in Gengo, so sharing is unobservable).

### 3.3 No implicit capture, at all

A task body cannot reference any outer-scope local or variable — not even
a `const` one. `const` alone was considered and rejected: a `const`
*binding* can still point at a mutable array/struct/map that outer-scope
code mutates later, silently breaking the no-sharing guarantee. Rather
than build a deep-immutability checker, there is no implicit capture
whatsoever. All data a task needs comes in through one of two channels,
both deep-copied:
1. Its own spawn-time parameters (§8).
2. Message payloads via `receive()` (§5).

**Declarations are not data, and are exempt from this rule.** Top-level
`const`, `func`, `type`, and `subtype` (and capability modules, and
imported library modules) are ambiently visible inside a task body with
no ceremony, Ada-style. This is safe, not just convenient: per
`docs/language.md`, `pub var` and `pub name := value` are explicitly *not*
supported at module top level — only `const`/`func`/`type`/`subtype` can
be exported. So the existing global namespace can never hold shared
mutable data crossing a *module* boundary.

**Gap closed in 0.2 — same-module mutable globals.** The paragraph above
is true across modules but was silently wrong within one: a module's own
top level *can* declare mutable globals (`g := 10`, `var g int = 10` —
they compile to `def_global` and are freely reassignable). The globals
table is shared process-wide under §3.2, so a task body reading or
writing `g` would be shared mutable state — precisely what this whole
section exists to prevent. Therefore, explicitly: **inside a task body,
referencing a top-level binding is a compile error unless that binding is
a `const`, `func`, `type`, `subtype`, or module import.** The compiler
already tracks per-global const-ness (it's what powers the existing
assign-to-const compile errors), so this is a lookup at name-resolution
time, not new analysis. The error should name the offending global and
say why (`global 'g' is mutable and cannot be referenced inside a task
body; pass it as a spawn parameter instead`).

**Import bindings are implicitly const (0.3 — FINDINGS #1).** The rule
above collided head-on with the single most common line in the language:
`std := import("std")` opens essentially every existing program, and
`:=` is a mutable binding — taken literally, no task could call
`std.io.println`. Resolution: a top-level binding whose initializer is
an `import(...)` call is **implicitly const** — the compiler forbids
reassigning it (nobody reassigns an import; any such code is almost
certainly a bug being caught) and it thereby qualifies for the
declaration exemption above. `const std = import("std")` (already legal
today) becomes the documented style going forward, but the ubiquitous
`:=` form keeps working, inside tasks and out. The decl-site shape is
statically recognizable, so this is a resolution-time flag, not
analysis.

**"Top-level" is a position, not a keyword (0.3 — FINDINGS #10).** Task
types can be declared inside function bodies (type decls are legal
locals), where they sit next to `const` *locals* of the enclosing
function. Those are still banned — the exemption is for module-top-level
declarations only, and the no-capture rule covers const locals
explicitly (first paragraph of this section). So the compiler's check
distinguishes binding *position* (module scope vs function scope), not
binding *keyword*. Stated because "const is ambient" is the wrong
intuition the top-level case will otherwise teach.

Capability modules (fs/net/http/etc.) fit the exemption as before: each
task's Gengo-level binding for e.g. `cap:http` is its own object, but the
native resources underneath (io overrides, net handlers) are already
process-global by design — correct, and matches how Ada tasks share one
runtime environment.

### 3.4 Data crossing the boundary: sendability

Both spawn arguments and message payloads deep-copy via the clone
mechanism (§3.2), at the point of crossing (spawn call / `send`). No
reference sharing ever occurs across the isolation boundary.

**Not every value is meaningfully copyable, so "sendable" must be a
checked property, not an assumption.** Two classes of values break under
naive deep-copy:

1. **Closures.** A closure's captured upvalues are shared mutable cells;
   copying the closure but sharing the cells leaks mutable state across
   the boundary, and deep-copying the cells silently forks state the
   programmer believes is shared. Erlang sends funs because everything
   in Erlang is immutable; Gengo's closures are not. **Function-typed
   fields are not sendable.**
2. **Native-resource objects.** Compiled regexps, string builders, live
   iterators, template objects, FFI handles, net/fs handles — their
   payload is or wraps native state that either can't be duplicated or
   must not be (two owners of one socket). **None of these are
   sendable.**

Sendable, transitively: primitives (int/float/bool/rune/decimal/bigint),
strings, error values, enums, `ActorRef` (§7 — it's an ownerless handle,
copying it is trivial and correct), and arrays/maps/structs/variants/
named types whose components are themselves sendable.

**This is checkable entirely at compile time, at the declaration site.**
A task's message type and its spawn-parameter types are declared types;
walking a declared type for non-sendable components is the same shape of
recursive check the compiler already performs for cyclic-composition
rejection. Declaring `type W task M func(...)` where `M` or a parameter
type contains a func or native-resource type is a compile error at the
declaration, with the offending path named. Nothing needs checking at
send time beyond the runtime type gate in §5 — if only sendable types
can be *declared* as message types, only sendable values can arrive at a
`send` that passes the type gate.

### 3.5 GC and compaction integration (new in 0.2)

0.1 didn't address the collector at all; under a shared heap it is where
most of the real implementation risk lives.

**Root set.** Today `collectGarbage` roots exactly one `vm_state` — the
active one — plus globals, temp roots, the object-holding const-pool
entries, and the defer stack. With N tasks, every *live* task's vm_state
is a root source regardless of which one is currently running: its value
stack, frames, temp roots, and defer stack. Marking must iterate the
task table. A suspended task blocked in `receive()` is exactly a task
whose stack must survive collection.

**Mailboxes are roots.** §5 keeps mailboxes as native-side FIFOs,
deliberately outside Gengo array semantics — but the queued *messages*
are ordinary heap values. A mailbox invisible to the collector is a
use-after-free generator: message sits queued, GC runs, message swept,
receiver dequeues garbage. Every task's mailbox (and any pending
monitor-notification payloads, though under §6 those are just mailbox
entries) must be traced during marking. Same for the monitor registration
lists if they ever hold heap values (under the current design they hold
only task ids, which are not heap values — keep it that way).

**Compaction.** The managed-heap compactor rewrites object payload slices;
the project's stale-slice bug class exists precisely because a raw slice
captured across a compaction point dangles. Two new slice populations
appear with tasks: (a) every suspended task's stack/frames/defer values,
and (b) every mailbox slot. Both must be visited by compaction's fixup
pass exactly like the active stack is today. This is mechanical but
must be exhaustive — a missed population here is the §3.2 "runtime check
with one missed call site" failure shape, in its most dangerous form.

**Owner-tag maintenance.** `obj_owner` must be updated wherever
`obj_live`/`obj_marked` are: cleared on sweep, moved on compaction slot
reuse, stamped on allocation with the *currently running* task's id. The
"currently running task" is scheduler state, so allocation needs one
extra load; measure, but this should be noise.

**Owner-tag semantics, pinned (missing from the first 0.2 draft):**
- There is a reserved **`SharedOwner`** id for objects that are legally
  visible to every task: const-pool objects, type objects
  (struct/variant/named/enum/task types), values held by the shared
  globals table, the std module namespace objects, and capability module
  bindings. These are exempt from the check below. (Everything reachable
  this way is either immutable or covered by §3.3's mutable-globals ban,
  which is what makes the exemption sound.)
- **Clone-at-send allocations are stamped with the *receiver's* id**, not
  the naive "currently running task" (which is the sender mid-`send`).
  The message-clone path passes the target task id down to allocation
  explicitly; spawn-argument clones stamp the spawned task's id the same
  way. Without this override the debug net would false-positive on every
  message ever received.
- The debug check itself: a running task dereferencing an object owned by
  neither itself nor `SharedOwner` is a heap-paranoia-class violation.
  Like `-Dheap_paranoia`, it's a build-flag lane, not a production
  branch.

**When can GC even run?** Today: at allocation points and safepoints in
the dispatch loop, always with a coherent active vm_state. With tasks,
collection can still only trigger from the running task's execution — but
it must now be correct with respect to all *other* tasks being at
arbitrary suspension points. Since tasks only ever suspend at `receive()`
(a clean Gengo-frame boundary, per §4.1 never inside a reentrant native
callback), every suspended task is at a well-defined safepoint by
construction. This is a real simplification the cooperative model buys
and it should be asserted in debug builds: a task in the table that is
neither running nor parked at a receive/sleep boundary is a bug.

## 4. Scheduling

**Pure cooperative for v1.** A task runs until it returns, panics, or
blocks on `receive()` finding an empty mailbox. No forced preemption. This
is explicitly expected to improve later, but the shape "better" can
actually take is worth pinning down now so it doesn't get oversold:

The existing gas/`max_ops` counter is the natural hook for a future
version, but it can only safely force a yield at the top level of
`runInner`'s dispatch loop — not while a task is nested inside a native
callback's reentrant `run()` call (see §4.1). So future preemption really
means *the scheduler's request is honored at the next safe unwind point*,
not a true interrupt-anywhere. Still a real improvement over pure
run-to-completion, just not OS-thread-style preemption. And per §2, any
such change must stay deterministic (a fixed ops-per-slice quantum is
deterministic; wall-clock-based preemption is not and is off the table).

### 4.1 The reentrancy constraint on `receive()`

Verified directly in `vm.zig`: `callValue` (used by native higher-order
functions like `array.filter`/`array.map` to invoke a user-supplied
closure) calls `run()` — the same top-level dispatch entry point —
*recursively*, on the real native Zig call stack. Suspending mid-way
through such a call would require unwinding through native stack frames,
which needs real stackful coroutines/fibers — not practical in WASM (no
portable stack-switching).

Consequence: `receive()` may only be called from an ordinary Gengo call
chain within a task's own body — never from inside a closure handed to a
native higher-order function.

**Enforcement, tightened in 0.2.** 0.1 called this "a static, checkable
rule," which as stated it is not: if `receive()` were legal in any free
function a task body calls, the compiler would need whole-program
call-graph analysis to prove that function is never also reached from a
native callback. Two-layer rule instead:

1. **Lexical (compile time):** `receive()` is valid only lexically inside
   a `task` body — including nested blocks/loops, excluding nested
   function literals — the same scoping rule a bare `return` already has
   to its enclosing function. A helper function cannot call `receive()`;
   the task's own body is the only place suspension can appear. This is
   a real expressiveness restriction (no "receive helper" abstraction in
   v1) and it is accepted deliberately: it makes every suspension point
   syntactically visible in the one function that owns the task's
   lifecycle.
2. **Runtime backstop (debug builds):** the VM keeps a native-reentrancy
   depth (incremented around `callValue`-style nested `run()` entries);
   `receive()` panics if it fires with depth > 0. This should be
   unreachable given rule 1 — it exists to catch compiler bugs, in the
   same spirit as the owner-tag net in §3.2.

`send()` has no such restriction — see §5, it never blocks.

### 4.2 Scheduler specification (new in 0.2)

Left implicit in 0.1; pinned down because determinism (§2) requires it.

- One global **ready queue**, strict FIFO. Spawning appends the new task.
  A `send` that makes a blocked receiver runnable appends that receiver.
  Nothing ever jumps the queue.
- **Run until yield point** (0.3 — this was "run-to-block" in 0.2, and
  that version was wrong; see below). The running task keeps the engine
  until it returns, panics, sleeps, or calls `receive()`. **Every
  `receive()` is an unconditional yield point**: the task is appended to
  the ready queue (if its mailbox is non-empty) or parked (if empty),
  and the scheduler pops the next ready task and swaps `vs`. Sends do
  *not* transfer control (no Erlang-style reduction handoff): sender
  continues, receiver becomes ready.

  *Why receive must yield even on a non-empty mailbox* (FINDINGS #9,
  livelock traced in `task-examples/09`): under pure run-to-block, the
  requeue pattern §5 explicitly recommends — dequeue a message you're
  not waiting for, `self().send(msg)` it back, loop — spins forever:
  send never yields, receive on a non-empty mailbox never blocks, so a
  mailbox containing only requeued messages starves every other task
  *including the one that would send the awaited reply*. 0.2's scheduler
  turned 0.2's own recommended pattern into a hang. With receive as an
  unconditional yield, the requeue loop rotates through the ready queue
  each iteration, the reply-sending task gets its turn, and the loop
  terminates. Cost: one `vs`-pointer swap per receive, on a path that
  was never hot. Determinism is unaffected — the rotation order is
  exactly as fixed as before.
- **Sleep integrates with the existing suspension machinery.**
  `std.time.sleep` today sets `vm_state.sleep_deadline_ns` and suspends
  the whole runtime (`runUntilSuspend` returns `.suspended`; the host or
  `waitOutSuspension` resumes it). Under tasks this generalizes cleanly:
  a sleeping task is parked with its own deadline and the scheduler runs
  other ready tasks. Only when *no* task is ready does the runtime-level
  suspension fire, with deadline = the minimum over sleeping tasks. The
  host-facing contract (`.suspended` outcome + deadline) is unchanged —
  embedders don't see tasks at all.
- **Global-deadlock detection, a strength worth cashing in:** if no task
  is ready, none are sleeping, and every live task is blocked in
  `receive()`, no message can ever arrive again (single-threaded, no
  external event sources can enqueue — capability callbacks run *within*
  some task's execution). That is a provable permanent hang, and unlike
  Erlang the scheduler can see it. v1 should fail loudly: panic the
  program with a diagnostic listing each blocked task. Hanging silently
  helps nobody, and this check is a few lines in the scheduler idle path.
  (If a future capability ever injects messages from outside the
  scheduler — e.g. a net poller — this detection must be revisited; note
  it there, not here.)

## 5. Mailbox and messaging

- **Unbounded**, matching real Erlang. A bounded-mailbox-with-blocking-send
  design (Go-channel-style backpressure) was considered first and walked
  back after examining Erlang's actual semantics: Erlang mailboxes are
  unbounded by default (a well-known production overload risk, worked
  around with external tooling, not a language-level bound). Going
  unbounded for v1 accepts that same known tradeoff rather than solving it
  architecturally now; a future diagnostic (mailbox-length introspection)
  can be added without changing core semantics.
- **Native-side FIFO per task**, not a Gengo-level array value — avoids
  entangling the mailbox with GC-tracked array semantics; it only needs
  enqueue/dequeue. (But its contents are GC roots and compaction-visited —
  §3.5. "Not a Gengo value" must never mean "invisible to the
  collector.")
- **`receive()` is strict FIFO**, not Erlang's selective/skip-based
  receive. Always dequeues the head; you pattern-match on whatever you got
  via an ordinary exhaustive `switch`. Chosen deliberately over selective
  receive (scan for the first pattern-matching message, leave the rest in
  place) because: it's O(1) instead of O(mailbox size); it fits Gengo's
  existing exhaustive-switch-on-variant idiom directly with no new
  mechanism; and it avoids the exact wart Erlang had to retrofit a fix
  for — selective receive on the common "send request, wait for that
  specific reply" pattern is bad enough in naive BEAM that a special-case
  optimization had to be added for it. The cost: you lose "wait for a
  specific reply, ignore everything else for now" as a built-in pattern —
  you'd have to handle or explicitly requeue unrelated messages yourself.
  (0.3: the requeue idiom is *safe* only because §4.2 makes `receive()`
  an unconditional yield point — under 0.2's run-to-block it was a
  livelock, traced in `task-examples/09`. If §4.2's rule ever changes,
  this bullet's advice breaks with it.)
- **Ordering guarantee, stated explicitly (0.2):** all sends into one
  mailbox are delivered in global send order (trivially, since there is
  one scheduler and copy happens at send). This is strictly stronger than
  Erlang's pairwise-FIFO guarantee; programs may rely on it, and it falls
  out of §4.2 for free.
- **Copy-at-send**, not copy-at-receive (§3.2/§3.4).
- **`send` is runtime-type-checked against the target's declared message
  type — gap closed in 0.2.** 0.1 said type mismatches are "the receiving
  task's `switch` to handle," borrowing Erlang's rationale. That
  reasoning does not transplant: Erlang is dynamically typed and every
  receive pattern-matches defensively, but Gengo's `receive()` is
  *statically* typed as the task's declared message type, and the
  receiver's `switch` is exhaustive over that type *by construction* —
  a wrong-typed value arriving would break switch soundness, the exact
  guarantee the language sells. Since `ActorRef` stays non-generic (§7),
  the send site can't be checked statically; therefore `send` checks at
  runtime that the payload's type is the target's declared message type
  (one type-object pointer compare against the tag the task table stores
  per task — cheap) and **panics the sender** on mismatch. Panicking the
  sender is consistent with where Gengo already puts strict-typing
  failures (typed parameters panic at the call boundary, the crossing
  point where the mistake is attributable) — the receiver never observes
  anything outside its declared type.
- **`send` to a dead/terminated target: silent drop**, exactly matching
  real Erlang (`Pid ! Msg` always "succeeds," evaluates to the message,
  no error, regardless of whether the target exists). Deliberately *not*
  an ok/err return — keeping `send` unconditional and ceremony-free at
  every call site was judged more valuable than synchronous feedback for
  the common case, matching the tradeoff Erlang's own designers made.
  Death-awareness is monitor's job, not send's (§6). Precisely: while the
  `ActorRef`'s generation still matches the slot (target alive, or dead
  but slot not yet reused — the message-type tag is still present in
  either case), the type check runs and a mismatch panics; drop happens
  after the check. Once the slot has been reused (generation mismatch),
  there is nothing left to check against — the send is a plain silent
  drop. So a mis-typed send is *not* guaranteed to be diagnosed on every
  interleaving where the target is gone; it is guaranteed to be
  diagnosed on any run where the target is reachable, which is the run
  the programmer debugs. (A stale ref's mailbox no longer exists either
  way; a dead task's queued messages are discarded at death and
  reclaimed by GC.)
- **`send` never blocks**, so it has none of `receive()`'s reentrancy
  restriction (§4.1) — callable from anywhere, including native callback
  contexts.
- **`send` to a mailbox-less task panics the sender (0.3).** §8.2's
  mailbox-less tasks have provably no reader; queueing to one would be
  a silent, permanent leak (mailboxes are unbounded), so it fails loudly
  at the crossing point instead — same philosophy as the type check
  above.

### 5.1 Receive timeouts — deferred, but named (new in 0.2)

Erlang's `receive ... after Timeout` is not in v1, and the omission has a
real consequence worth stating rather than discovering later: a v1 task
cannot do timed periodic work while also listening for messages — blocked
in `receive()` it wakes only on a message; sleeping it can't receive. The
honest workarounds are a companion ticker task that sleeps and sends tick
messages (works today, composes from existing pieces), or waiting for a
`receive(timeout)` variant. When a timeout variant does land it should
return the existing optional shape (`?Msg`, null on timeout) rather than
invent a sentinel message, and it slots into §4.2's parking machinery as
"blocked with a deadline" — the same state sleeping tasks already occupy,
so the scheduler cost is nil. Deferred only because v1 doesn't need it to
be coherent, not because it's hard.

## 6. Death notification (`monitor`)

Minimal, **one-way** monitor only — no bidirectional/lethal `link`, no
supervision trees. `monitor(actor_ref)` (called as `worker.monitor()`)
registers the calling task as a watcher of the target (a small native-side
list per task, same non-Gengo-value treatment as the mailbox — and per
§3.5 it must hold only task ids, never heap values).

**Why monitor, not just a send-time error:** the two solve genuinely
different problems. A send-time error only tells you whether the target
was already dead *at the moment you tried to send* — it says nothing about
a target that was alive, accepted a message, and crashed while processing
it, which is arguably the more important case (a worker crashing mid-task,
not a caller talking to something already gone, is the scenario actor
isolation exists to help detect). Monitor covers that; a send-time error
alone cannot.

**Delivery mechanism:** when the watched task terminates (normal return or
uncaught panic), a down-notification is appended to the *end* of each
watcher's own mailbox — ordinary FIFO order, no priority jump, arriving
exactly the same way any other message would. This was chosen over a
separate `down`-shaped lifecycle hook (bypassing the mailbox entirely),
which was considered and rejected: it would be a genuine departure from
both Erlang and Akka precedent (both fold death notification into the
ordinary message-matching path), and it raises an ordering question
neither of those has to answer (what's a hook's ordering relative to
regular queued messages?) for no clear benefit.

**No missed-notification race**, unlike Erlang, which has to guard against
one because BEAM is genuinely concurrent. Scheduling here is fully
cooperative and centrally visible, so "target already dead when `monitor`
is called" is a plain state check, not a race — but the same *behavioral*
guarantee still holds: calling `monitor` on an already-dead target
immediately delivers the down-notification, so one is never silently
missed.

**Duplicate registration (pinned in 0.2):** `monitor()` on the same
target twice is idempotent — one registration, one notification. Erlang
gives each monitor call its own ref and its own message; that exists to
support demonitor-by-ref, which v1 doesn't have, so the simpler set
semantics win. If demonitor ever lands, revisit.

**Watcher dies before target:** delivery is just a send, and sends to
dead targets drop (§5) — so a dead watcher's registration needs no
eager cleanup for correctness; pruning it when the target eventually
delivers (or when the watcher's slot is reused) is a bookkeeping
detail, not a semantic one.

**Reason payload**: reuses whatever value `std.core.recover()` already
produces for an uncaught panic — no new error representation invented.
Normal return delivers a null reason; panic delivers the error value.
The `?error` field shape in §8's example is exactly this distinction.

**Unmonitored panic death is not silent (new in 0.2):** a task that dies
by uncaught panic with no watchers writes the same panic diagnostic to
stderr that an uncaught top-level panic writes today, then the program
continues. Swallowing a crash because nobody subscribed is hostile to
debugging; Erlang logs unlinked process crashes for the same reason. A
*monitored* panic death is the watcher's business and produces no
automatic output.

**Explicit opt-in required, checked at compile time.** A task's message
type must include a `Down`-shaped arm to call `monitor()` at all — calling
it otherwise is a compile error. This is consistent with Gengo never doing
implicit/hidden cases elsewhere (variant `switch` is already exhaustive by
construction), and it makes "this task can observe deaths" visible in its
own declared type rather than a fact buried in its body.

**Task 0 is exempt (0.3 — FINDINGS #4).** Main has no declared message
type, so the arm rule is unstatable for it — yet main monitoring a
worker is the most common pattern in every example written. Main's
mailbox is `any`-typed (§9), so the delivery always type-fits; the
down-notification arrives as a `std.task.DownInfo`-carrying value main
switches on like anything else. Consistent with §9's stance that typed
rigor is confined to declared tasks. (A mailbox-less task (§8.2)
cannot call `monitor()` at all — it has nowhere to receive the
notification; compile error, same shape as the missing-arm error.)

**Concrete "Down-shaped" proposal (new in 0.2 — resolves the §11 open
question in principle):** detection by *payload type*, not by arm name.
The std library declares a builtin struct — working name
`std.task.DownInfo`, fields `{ who ActorRef, reason ?error }` — and the
compile-time rule becomes: the message variant must contain exactly one
arm whose payload type is `DownInfo` (zero arms → `monitor()` is a
compile error at the call site; two or more → ambiguous, compile error at
the type declaration). The runtime constructs that arm for delivery. This
avoids both hazards of name-based detection: no collision with a user's
unrelated arm that happens to be called `Down`, and no magic identifier
whose misspelling silently disables the check. The arm's *name* stays the
user's choice (`Down`, `PeerDied`, whatever reads well in their switch).

**Deadlock**, mentioned for completeness though not decided as a v1
feature: bounded mailboxes would have introduced a real circular-wait risk
(this doesn't apply now that mailboxes are unbounded — flagged here only
because unbounded doesn't remove *all* forms of a task waiting forever,
e.g. `receive()` on a mailbox nothing will ever fill). §4.2's
global-deadlock detection covers the total-hang case; a *partial*
deadlock (two tasks waiting on each other while a third keeps the program
alive) remains undetected in v1, same as in every actor system.

## 7. Actor handles

`ActorRef` — a lightweight, ownerless handle value, conceptually an opaque
index into a process-wide task table. Safe to store, compare (`==` is
identity), or include in any message with no deep-copy concern, the same
way an `int`/`bool` needs no ownership tracking.

**Slot reuse and the ABA problem (gap closed in 0.2):** "opaque index
into a task table" is unsound by itself. Task dies, table slot is reused
for a new spawn, and a stale `ActorRef` held by anyone now silently
addresses the *new* task — sends intended for a dead worker arrive at an
unrelated one. Erlang pids carry serial/creation counters for exactly
this reason. `ActorRef` is therefore `{ slot index, generation }`; the
table bumps a slot's generation on reuse, and every deref (send, monitor)
compares generations — mismatch behaves as "target dead" (send drops
after its type check, monitor delivers the down-notification
immediately). With a u32 generation, wraparound is not a practical
concern at Ada scale; the pair still packs in 64 bits, value-sized.

**Zero value (0.3 — FINDINGS #6):** every Gengo type has one, and
`var partner ActorRef` before an introduction message arrives is real
code (`task-examples/02`). The zero `ActorRef` is the **null ref** —
reserved slot 0 / generation 0, never occupied by any task — and it
behaves as permanently dead: send drops, monitor delivers the
down-notification immediately. One caveat follows from §5's mechanics
and is stated so nobody rediscovers it: the null ref has no recorded
message type, so a send to it can never be type-checked — a mis-typed
send to a null ref is silently dropped, not diagnosed.

**`self()` — required, was missing entirely from 0.1:** without a way for
a task to name itself, the request/reply pattern is unwritable — a
requester cannot include a reply-to handle in its message, which makes
mailboxes write-only pipes and guts the model. `self()` is a contextual
builtin returning the current task's `ActorRef`, valid anywhere `send`
is (it never blocks, so it carries no §4.1 restriction; inside a native
callback it still answers "which task's execution am I inside," which is
well-defined under cooperative scheduling).

**Deliberately not generic** (`ActorRef[Worker]`). Matches Erlang's `Pid`,
which also isn't statically checked against what its target expects.
Mismatches are caught at the send boundary by the §5 runtime type check
(0.2 — this replaces 0.1's "receiver's switch handles it" rationale,
which was unsound; see §5). Static checking via generics remains
attractive later, but leans on Gengo's generics machinery in ways v1
shouldn't — and the runtime check means the door stays open: making
`ActorRef` generic later only *promotes* an existing runtime error to
compile time, breaking nothing.

## 8. Syntax

```gengo
type WorkerMsg variant {
    add(n int),
    reset,
    down(info std.task.DownInfo),
}

type Worker task WorkerMsg func(count int) {
    for {
        msg := receive()
        switch msg {
            case .add as a  { count += a }
            case .reset     { count = 0 }
            case .down as d { std.io.println("peer died") }
        }
    }
}

worker := Worker(10)
worker.send(WorkerMsg.add(5))
worker.monitor()
```

(0.3 — FINDINGS #11: arms are lowercase, matching the convention every
spec test already uses (`deny`, `ok`, `circle`); earlier drafts
capitalized them. The §6 payload-type rule means the down arm's *name*
carries no significance anyway.)

### 8.1 Rationale, and what was tried and rejected

`type Worker task WorkerMsg func(count int) { ... }` uses two pieces of
grammar that already exist, combined for a new kind:
- `type Name Kind [modifier] { body }` is the existing shape named types
  already use (`type Age int range 0..100`, `type Port int range
  1..65535 default 8080`). `task` is a new sibling to `struct`/
  `variant`/`interface`/`enum` under that same umbrella; the trailing
  modifier here names the message type. (`task` should be a *contextual*
  keyword — valid only in the kind position after `type Name` — following
  the precedent of the existing contextual clause words like `range`/
  `predicate`/`default`, so no user identifier breaks.)
- `func(params) { body }` is completely ordinary — the same shape used by
  predicate declarations (`type Port int predicate func(x) { ... }`) and
  by any function. No new grammar.

**There is no separate struct-like field block, and this was the hardest
part to land on.** `Worker` is not "fields plus a method." `count` is
simply an ordinary parameter/local of the one function that *is* the
task's entire behavior — it persists for the task's whole life for the
same reason any long-running, never-returning function's locals persist.
Nothing new semantically. This resolved a real problem with earlier
attempts: `name Type` is already valid Gengo syntax for both a struct
field and a typed local var decl, so any shape that put persistent
"fields" in the same block as executable statements (several were tried —
a `run`/`down` multi-clause form mimicking predicates incorrectly,
`func()` as a bare boundary marker, `func()` with empty parens nested
around a nested field+loop block) either invented a pattern that exists
nowhere else in the grammar, or left the field/local distinction resting
on implicit position alone with no precedent for that anywhere else in
the language. Recognizing that `count` is just a function parameter, not
a field, made the ambiguity disappear entirely rather than papering over
it.

**No `self`/receiver anywhere.** There is no method here — just a plain
function — so there's nothing to bind a receiver to. Parameters and
locals are referenced by bare name. (`self()` from §7 is a builtin call,
not a receiver — consistent with this.)

**`Worker(10)` requires no new call syntax at all.** This is the same
principle already used throughout Gengo: syntax that looks like an
ordinary call/construction compiles completely differently depending on
the type's *declared kind* (struct-literal vs. variant-arm construction
vs. named-type cast already all dispatch this way; operator-overload
dunders are the same idea for infix operators). A `spawn` keyword was
considered and dropped for exactly this reason — the compiler already
knows `Worker` is task-kind, so a call to it can simply mean "allocate a
task, deep-copy these arguments into its parameters, schedule it, return
its `ActorRef`" instead of "run synchronously and return a value," with
zero new grammar. Spawn arguments are type-checked like any call's
(existing machinery), plus §3.4's sendability rule on the parameter
types, checked once at the declaration.

**`worker.send(...)` / `worker.monitor()`** are ordinary methods on
`ActorRef`, dispatched the same way builtin string/bytes methods already
are.

**`receive()` is a contextual builtin**, valid only lexically inside a
task's own body (§4.1's tightened rule) — the same kind of contextual
validity a bare `return` already has to its enclosing function.

**None of `receive`/`send`/`monitor`/`self` being available without an
explicit declaration is hidden magic.** This directly matches existing
precedent: named range types automatically expose `.first`/`.last` as
built-in accessors purely from having a `range` clause, with no explicit
declaration anywhere (`type Port int range 1..65535`, then `Port.first`
just works). A type's declared kind and clauses granting built-in
operations is an established pattern here, not a new one.

**Task types have no other declared methods.** Since nothing external can
ever invoke anything on a task synchronously — communication is messages
only, which is a structural consequence of cooperative scheduling (a
method call implies executing in the caller's timeline, right now, which
would either reach into another task's execution out of turn or become a
disguised, dishonest version of `send`) — there is no `func (recv Worker)
helper()` mechanism for task types at all. Any internal decomposition a
task's behavior wants is ordinary free functions its body calls, not
additional methods. (Those free functions cannot `receive()` — §4.1 —
but can `send` and use `self()` freely.)

**Default values for parameters** (e.g. giving `count` a default so
`Worker()` works without an argument) are treated as an already-solved,
separate problem via the existing named-type/subtype `default` clause
machinery — not something task syntax needs to invent its own mechanism
for.

### 8.2 Mailbox-less tasks (new in 0.3 — FINDINGS #7)

Two of the first eight realistic examples written (`task-examples/05`'s
ticker, `08`'s one-shot computation) were tasks that never call
`receive()` — and both needed a dummy `variant { unused }` to satisfy
the grammar. Worse than ugly: a dummy message type advertises a mailbox
nobody will ever read, and §5's unbounded mailboxes make sending to one
a silent, permanent leak.

So the message type is **optional**: omitting it declares a mailbox-less
task —

```gengo
type Ticker task func(target ActorRef, interval_ms int) {
    for {
        std.time.sleep(interval_ms)
        target.send(CacheMsg.tick())
    }
}
```

Grammar stays unambiguous: the kind position after `task` is followed by
either a type name or `func`. Semantics of the omission: `receive()` in
the body is a compile error (there is no mailbox and no message type for
it to produce); `monitor()` likewise (§6 — nowhere to deliver); sends
*to* such a task's ref panic the sender (§5 — provably no reader, fail
at the crossing point rather than leak). The task can still `send`,
`self()`, and be monitored *by* others — one-shot workers reporting
completion via Down alone are a legitimate pattern.

## 9. The main program, and program lifecycle (new in 0.2)

0.1 never said what `main` (top-level code) *is* in this model, which
left the two most basic questions unanswerable: how does top-level code
ever get a result back out of a task, and when does a program with live
tasks terminate?

**Main is task 0.** Top-level program code runs as a task like any other:
it has a mailbox, an `ActorRef` (`self()` works at top level), it can
`monitor()`, and it can `receive()`. This is the Erlang-shell model and
it answers the result-collection question with no new mechanism — a task
replies to `self()`-carrying requests, main receives. Without this, tasks
are write-only from the program's perspective and the feature is
decorative.

The one wrinkle: main has no declared message type, so `receive()` at top
level types as `any`. 0.2 hand-waved what switching on that looks like;
every example with a receiving main hit it (FINDINGS #2), so 0.3 pins
the rule: **`switch` on an `any`-typed value whose runtime value is a
variant dispatches by arm at runtime, and the exhaustiveness obligation
is replaced by a mandatory `default` arm** — the same `default` the
value-switch grammar already has (`switch x { case 1 {...} default
{...} }`). Exhaustiveness is a static property of a statically known
variant type; when the static type is `any` the compiler cannot owe it,
so it demands the explicit catch-all instead. Arms that don't match the
runtime variant (or a non-variant value arriving) fall to `default`.
This also handles the mailbox reality that *different* variant types can
arrive in main's one mailbox (a reply type and a DownInfo-carrying type,
in the same program — `task-examples/01`).

That is a real, small loss of static safety, confined to main — accepted
for v1 over the alternatives (forcing every program that uses tasks to
declare a main message type is ceremony; forbidding main from receiving
guts the feature). A program wanting typed rigor at the top can define a
single-arm wrapper task and keep main trivial. Revisit if it stings.
(Implementation note: whether switch-on-any-variant exists today or is
new compiler work needs checking when implementation starts — the
`case .arm` form currently assumes a statically known variant type.)

**Termination: main's return ends the program, Go-style.** When task 0's
body finishes (or panics uncaught), the program is over: remaining tasks
are discarded — not run to completion, and (sharp edge, documented
deliberately) their pending `defer`s do not run, exactly as Go goroutines'
deferred calls don't run at `main` exit. The alternative —
run-until-quiescent — was considered and rejected: any server-shaped task
(`for { receive() }`) never quiesces, so that rule makes every program
with a long-lived worker unterminatable by construction. Under main-exits
rule, "wait for workers" is written explicitly with monitor/receive, which
is both visible and deterministic. Embedder-facing behavior of
`Runtime.run`/`runPath` is unchanged: returns when the program is over.

**Panic containment changes meaning slightly:** today an uncaught panic
tears down the run; under tasks, an uncaught panic in task N kills task N
(§6 — Down notifications, stderr diagnostic if unwatched), and only task
0's uncaught panic ends the program. The existing per-run error capture
(`last_runtime_*`) stays wired to task 0's outcome. `recover()` inside
any task works unchanged — panic unwinding is per-vm_state machinery
already.

## 10. Implementation mapping (new in 0.2)

Where each piece lands in the existing engine, and what it must not
disturb. Written to be checked against, not to schedule work.

- **Task body = ordinary `FuncObj`.** The behavior function compiles as a
  normal function object in the const pool; the task *type* is a new
  object kind (sibling of `struct_type`/`variant_type`) holding its name,
  the message-type reference, and a pointer to that FuncObj. Everything
  downstream then comes for free through the recently-unified machinery:
  `chunk.funcObjOfConst` learns one new shape (task type → behavior
  FuncObj), and the verifier's max_stack stamping, the fusion install
  phase, and defuse pass 3 all pick it up through that single function —
  the exact reason that consolidation was done. Adding the shape anywhere
  else is a bug by definition now.
- **Opcodes**: spawn (call-shaped, arg-count operand) and receive need
  ops — take them from the reserved slots per the opcode-layout scheme;
  core-range values are wire-stable, so append in the reserved core
  space, not the fused range. `send`/`monitor`/`self` fit the existing
  native-method dispatch on `ActorRef` values and likely need no opcodes
  at all. (No opcode here is a perf claim — they're semantic; the
  "justify new opcodes with cycle counts" rule is about fusion, and
  fusing anything task-related is explicitly out of scope until profiles
  exist.)
- **GBC**: the task-type const needs a serialization form when GBC lands
  (#5). Nothing about tasks changes wire-stability of existing core ops.
  Defuse/differential testing keeps working because scheduling is
  deterministic (§2) — a differential run with tasks compares identical
  interleavings by construction.
- **Task table**: fixed-size (power-of-two per the engine-audit sizing
  constraint), slots = {generation, state, vm_state ptr/slot, mailbox,
  monitor list, message-type tag}. On wasm32 the vm_state backing is a
  static pool sized by `MaxTasks` (§3.2 correction). Native targets
  allocate per spawn but respect `MaxTasks` for portability. Spawn
  beyond capacity: runtime error at the spawn site (panics the spawner) —
  consistent with `TooManyGlobals`-class resource limits.
- **Chunk verifier**: task bodies are functions found from the const pool
  like any other, so BFS coverage and max_stack stamping need no new
  verifier passes — only the `funcObjOfConst` shape addition above. The
  smaller per-task stack ceilings (§3.2) mean frame-entry capacity checks
  compare against the *task's* stack size, not the global one: the
  `max_stack` a function was stamped with is per-function and
  size-agnostic, so this is a scheduler-side check at spawn/frame-entry,
  not a verifier change.
- **What must not regress**: single-task programs (every existing
  program) must compile to byte-identical bytecode and run through the
  scheduler's fast path with no measurable dispatch cost. The hot-loop
  constraints from the engine audit (no errdefer in dispatch, TOS
  type-state locality) bound what the yield/swap points are allowed to
  touch. Task-table walking happens only in GC, scheduling, and
  spawn/death — never per-instruction.

## 11. Open / explicitly deferred questions

- ~~Exact compile-time check for the `Down`-shaped arm requirement~~ —
  resolved in principle by the §6 payload-type proposal
  (`std.task.DownInfo`, exactly-one-arm rule); still needs wording in
  type-checker terms once implementation starts.
- Whether/how a task can be told to stop from outside (today: only
  monitor gives outside visibility into a task ending; nothing external
  can request one to end). Erlang's answer is `exit/2` signals; a
  v2-shaped answer here might be a conventional shutdown message arm,
  which needs no engine support at all — worth trying conventions before
  mechanisms.
- Mailbox introspection/diagnostics (current length, etc.) as a future
  mitigation for unbounded growth (§5).
- `receive(timeout)` (§5.1) — deferred, design sketched.
- How the spec tests for tasks themselves wait on timed behavior
  (FINDINGS #8): testing a ticker/TTL without `receive(timeout)` means
  main must out-wait wall-clock sleeps, which CI will hate. Determinism
  (§2) permits injected/virtual ticks instead; decide the mechanism
  during implementation planning, before the first timed spec test is
  written.
- Future scheduling improvements beyond pure-cooperative v1: quantum
  must be deterministic (§4), yield honored at safe points only (§4.1).
- Whether capability event sources (net accept loops, http serving)
  should eventually pump the scheduler — i.e., tasks + long-blocking
  native IO currently means one task's blocking call stalls everyone,
  which is honest cooperative behavior but limits server-shaped uses.
  Any change here interacts with §4.2's deadlock detection (external
  message injection breaks its "no external sources" premise) and must
  keep determinism opt-out explicit. Deliberately not designed yet.
- String-byte sharing as a copy optimization (§3.2) — do nothing until
  message-heavy profiles exist.
- Whether GBC maturity matters here at all — likely not, given the
  chosen shared-heap architecture (§3.2) doesn't need per-task
  reinitialization of anything; flagged only because it was a live
  concern under the rejected separate-Runtime approach and shouldn't be
  assumed still relevant without re-checking if the architecture changes
  again. §10 records the one real GBC touchpoint (task-type const
  serialization).
