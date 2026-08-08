# Task Examples — Findings

What fell out of writing realistic programs against the 0.2 design
(`../task-actor-design.md`). Numbered; the example files reference these
by number. Ordered by how much they matter, not by discovery order.

**Status (design rev 0.3):** all findings resolved or acknowledged —
#1 adopted (§3.3, implicit-const imports), #2 adopted (§9,
switch-on-any + mandatory default), #3 acknowledged, no change (§8.1
honesty note stands via 07), #4 adopted (§6, task-0 exemption),
#5 adopted (§2, user-docs mandate), #6 adopted (§7, null ref),
#7 adopted (§8.2, mailbox-less tasks), #8 moved to §11 open questions
(deterministic tick injection), #9 adopted (§4.2, receive is an
unconditional yield point), #10 adopted (§3.3, position-not-keyword
wording), #11 adopted (§8, lowercase arms).

## 1. The universal import idiom collides with the mutable-globals ban

`std := import("std")` is line 1 of **249 of 250** spec-test programs —
and `:=` is a *mutable* binding, which §3.3 bans from task bodies. Taken
literally, no existing program's import style lets a task call
`std.io.println`. This is the single biggest ergonomic landmine found.

Resolution space (pick one, put it in the doc):
- **(a) Require `const std = import("std")` for task visibility.** Works
  today (verified against the current compiler), zero engine work, but
  breaks the idiom used by essentially all existing code and every doc
  example — a migration/teachability cost.
- **(b) Treat `x := import(...)` as implicitly const.** The decl site is
  statically recognizable; the compiler forbids reassigning such a
  binding (arguably nobody reassigns an import anyway) and then it
  qualifies for §3.3's exemption. Small compiler special case, saves the
  idiom.
- **(c) Exempt import bindings from the ban without const-ness.** Unsound
  — `lib = something_else` inside/outside a task would smuggle mutable
  state. Rejected; listed for completeness.

Recommendation: (b), with (a) as the documented style going forward.

## 2. Main's `any`-typed receive is weaker than it looked in the doc

§9 accepts that top-level `receive()` types as `any`. The examples show
what that means concretely: `switch` over a variant value the compiler
can't type — so either the language needs switch-on-`any` with runtime
arm dispatch and **no exhaustiveness check** (a soundness-adjacent
special case existing switch doesn't have), or main must cast
(`ResultMsg(msg)`-style) before switching, which is ceremony §9 wanted
to avoid. Every example file with a main that receives (01, 02, 04, 05,
06, 08) hits this. The doc hand-waved it; the examples say it needs a
real answer before implementation. The "single-arm wrapper task" escape
in §9 helps nothing here — main still receives *something*.

## 3. Exhaustiveness × phases = quadratic ceremony (accepted, but see it)

07_state_machine: 4 arms × 3 phases = 12 cases, most of them "can't
happen here" drops. This is §5's FIFO+exhaustive choice working exactly
as designed — every ignored message is a visible decision — but the
examples make the cost concrete in a way the doc's prose didn't.
No change recommended; the doc should show this honestly rather than
only the 3-arm happy case.

## 4. What does the Down-arm rule mean for main?

§6: calling `monitor()` requires the caller's *declared message type* to
contain a `DownInfo` arm. Main has no declared message type — yet main
monitoring a worker is the single most common pattern in these examples
(01, 02, 03). The rule as written is either vacuously satisfied or
unsatisfiable for task 0. Needs one sentence in the doc; suggested:
task 0 is exempt from the arm check (its mailbox is `any`-typed, so the
delivery always type-fits), which is consistent with §9's "typed rigor
is confined to declared tasks."

## 5. Cooperative ≠ concurrent-looking, and interleaving intuition lies

08_oneshot: "spawn three jobs" runs them strictly sequentially at main's
first block — nothing overlaps, ever. 03_monitor_crash: whether a
`.stop` lands before or after a down-notification depends on precise
run-to-block scheduling that takes real thought to trace even in a
20-line program. Neither is a design flaw — determinism is the feature —
but user-facing docs must kill the "spawn = parallel" intuition early,
and the §4.2 scheduling rules need to be *user* documentation, not just
design documentation, because programs observably depend on them.

## 6. `ActorRef` needs a zero value

02_pingpong: `var partner ActorRef` before the introduction message
arrives. Every Gengo type has a zero value (`zero_struct`, 0, "", etc.);
the doc never says what an unset `ActorRef` is. Natural answer: the
null ref — generation 0 / reserved slot, behaves as permanently dead
(send drops after type-check-if-possible, monitor delivers Down
immediately). Needs a line in §7, and it interacts with the send
type-check: a zero ref has no message type recorded, so sends to it can
never be type-checked — fine, but say so.

## 7. Tasks that never receive still must declare a message type

05 (Ticker) and 08 (FibJob) both needed a dummy `variant { unused }` to
satisfy `type Name task MsgType func(...)`. Ugly, and worse than ugly:
a dummy message type advertises a mailbox that will never be read —
send to it and the message queues forever (silent leak, §5 unbounded).
Proposal: make the message type optional — `type FibJob task func(n int,
reply ActorRef) { ... }` declares a mailbox-less task where `receive()`
is a compile error and *sends to its ref panic the sender* (there is
provably no reader; silence would be the §5 leak). Grammar stays
unambiguous (the kind position is followed by either a type name or
`func`).

## 8. Timed behavior is untestable ergonomically without §5.1

05_ticker_ttl: testing expiry requires main to out-wait the TTL, but
main can neither `receive(timeout)` nor sleep-and-drain. The companion-
ticker workaround composes for *tasks* but main ends the program by
returning (§9). Not an argument to pull §5.1 into v1 by itself, but
"how do the spec tests for tasks themselves wait for timed behavior?"
needs an answer during implementation planning — likely deterministic
tick injection rather than wall-clock sleeps, which determinism (§2)
makes possible and CI will demand anyway.

## 9. The requeue pattern is a livelock — most important finding

09_requeue_livelock, full trace in the file. §5 sells requeueing
("handle or explicitly requeue unrelated messages yourself") as the
escape hatch for losing selective receive. Under §4.2's run-to-block
rule the obvious requeue loop — `receive()`, not the droid I'm looking
for, `self().send(msg)`, loop — **spins forever**: send never yields,
receive on a non-empty mailbox never blocks, so a mailbox containing
only requeued messages starves every other task, including the one that
would have sent the awaited reply. The design currently recommends a
pattern its own scheduler turns into a hang.

Options:
- **(a) Make `receive()` an unconditional yield point** (append self to
  ready queue, run scheduler, even when the mailbox is non-empty).
  Deterministic (round-robin stays fixed), fixes the livelock (the
  pricer gets its turn between spins — the loop terminates), costs one
  vs-pointer swap per receive. Changes §4.2's run-to-block wording.
- (b) Keep run-to-block, delete the requeue advice, document "wait for
  a specific reply" as unwritable in v1 without protocol discipline
  (dedicated reply arms + state, as 09's `waiting` flag *attempts*).
  Honest but grim — the pattern is common and users will write 09's
  loop anyway.
- (c) A `yield()` builtin and require manual insertion. Maximally
  explicit, maximally footgunned — forgetting it reproduces the hang.

Recommendation: (a). It's the only option where the natural code is
also the correct code, and it preserves determinism. §4.2 and §5 both
need the corresponding edits.

## 10. "Outer const local" vs "top-level const" needs a precise line

99(a): §3.3 exempts top-level `const` declarations but bans capturing
outer locals *including const ones*. A task type declared inside a
function (legal — type decls can be local) sits next to const *locals*
of that function: same keyword, opposite legality, and the compiler
must distinguish binding *position* (module top level vs function
scope), not binding *kind*. Implementable — scope depth is known at
resolution — but the doc should state the rule in those terms, because
"const is ambient" (wrong) is the intuition users will form from the
top-level case.

## 11. Cosmetic: the doc's arm naming fights the codebase's convention

Spec tests uniformly use lowercase variant arms (`deny`, `ok`, `circle`);
the design doc's examples use capitalized (`Add`, `Reset`, `Down`).
These examples follow the codebase (lowercase). The doc should switch —
`case .down as d` is what real programs will look like, and the
`DownInfo`-by-type rule (§6) already freed the arm name from any
significance.
