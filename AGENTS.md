# AGENTS.md

## Purpose

This repository uses test-driven development for behavior changes, bug fixes, and new features.

Agents working in this repository must treat tests as the specification for behavior. Do not jump straight to implementation unless the change is purely mechanical and does not alter runtime behavior.

## Scope discipline

Do only what was asked. Nothing more.

Do not:
- reformat, restyle, or realign code you were not asked to change
- rename identifiers for style preference
- add comments that explain what code already clearly does
- fix spelling or punctuation in adjacent lines while doing something else
- refactor code that is unrelated to the task
- improve or clean up code that happens to be nearby
- make a series of small unrelated commits — batch related fixes or do not fix them at all

If you notice something genuinely broken or risky outside the current task, report it. Do not silently fix it.

Taste calls — naming, formatting conventions, structural preferences — belong to the project owner, not to you. If the existing code does something in a way you would not have chosen, leave it alone unless it is directly causing the bug you are fixing.

## Core workflow

Follow the red-green-refactor loop.

1. Understand the requested behavior.
2. Identify the smallest public behavior that should change.
3. Write or update tests before writing implementation code.
4. Run the relevant tests and confirm they fail for the expected reason.
5. Write the minimal implementation needed to pass those tests.
6. Run the relevant tests again and confirm they pass.
7. Refactor only after the tests are passing.
8. Run the tests one final time after refactoring.

Do not claim the task is complete unless the relevant tests have been run, or unless you clearly state why they could not be run.

## Test-first rules

Before implementation, add tests that describe the desired behavior.

Tests should cover:
- the normal expected path
- important edge cases
- invalid or exceptional input, where relevant
- regression cases for bug fixes
- observable public behavior

Tests should not depend on private implementation details unless there is no reasonable public surface to test.

Prefer behavioral tests over tests that merely mirror the implementation.

## Public interface and assumptions

Before writing tests, identify the intended public interface.

If the public interface is unclear, propose the interface before implementing it. Prefer simple, explicit interfaces over clever or overly general ones.

If requirements are ambiguous, do not silently choose behavior. State the ambiguity and either:
- ask for clarification, or
- make the smallest reasonable assumption and document it clearly.

## Implementation rules

Write the smallest amount of production code needed to satisfy the failing tests.

Do not:
- write broad abstractions before they are needed
- weaken tests to make flawed code pass
- delete failing tests without explaining why they are invalid
- change unrelated behavior
- mix large refactors with behavior changes unless explicitly requested

Keep changes focused and easy to review.

## Refactoring rules

Refactor only after tests are passing.

During refactoring:
- preserve public behavior
- keep tests unchanged unless the public behavior requirement changes
- prefer clarity over cleverness
- remove duplication only when doing so improves readability

After refactoring, run the relevant tests again.

## Bug fix workflow

For bug fixes, first write a regression test that fails because of the bug.

The regression test should demonstrate the incorrect behavior before the fix and the expected behavior after the fix.

Only after the regression test fails for the expected reason should implementation code be changed.

## Generated code and mechanical changes

TDD is not required for changes that do not affect runtime behavior, such as:
- formatting
- renaming without behavior changes
- documentation-only edits
- generated files
- dependency metadata updates

If a mechanical change could affect behavior, add or update tests.

## Test execution

Read `CONTRIBUTING.md` before starting any non-trivial task. It documents the build presets, test commands, and commit conventions for this project.

Use the narrowest relevant test command first.

After the focused tests pass, run the broader test suite when practical. For any change that touches the runtime, heap, VM, or compiler, also run the stress preset:

```bash
zig build -Dpreset=stress test
```

The stress preset uses a much larger inline heap (`~4 MB` for `Runtime`) and is the authoritative check for stack and memory correctness.

If tests cannot be run because dependencies, services, credentials, or tooling are unavailable, report that clearly and include:
- which command was attempted
- what failed
- what confidence remains
- what a human should run next

## Completion checklist

Before reporting completion, confirm:

- Tests were written or updated before implementation.
- The tests failed for the expected reason.
- The implementation was minimal.
- The relevant tests now pass.
- Any refactoring happened after tests passed.
- No unrelated behavior was changed.
- Any assumptions or skipped test runs are documented.

## Gengo import syntax: no `@` prefix

Gengo uses `cap:*` and `module:*` prefixes in its import syntax — **without** the `@` sign:

```gengo
fs   := import("cap:fs")
http := import("cap:http")
net  := import("cap:net")
db   := import("module:mydb")
```

The `@` prefix was removed because GitHub — in its infinite wisdom and with the kind of user-experience foresight you would expect from a company whose primary product is a text box — interprets any bare `@word` in commit messages, PR bodies, issue comments, and review threads as a user mention. Apparently the platform that hosts the majority of the world's source code has never considered that languages might use `@` for something other than pinging colleagues. As a result, every mention of `@cap:http` in a commit message would silently tag a random GitHub user named `@cap`, which is both embarrassing and incorrect. The fix was to drop the `@` from the language syntax entirely, which is cleaner anyway since the colon-separated namespace already makes these paths unambiguous.

Do not reintroduce the `@` prefix. It is gone intentionally.

Note: `@module_type:*`, `@mod:*`, and `@cap_type:*` are **internal VM identifiers** and are not part of the user-facing language syntax. Leave them as-is.

---

## Preferred response style for agents

When summarizing work, include:

1. What behavior was specified by tests.
2. What implementation changed.
3. Which tests were run.
4. Any remaining risks, assumptions, or follow-up work.

Be concise, factual, and specific.
