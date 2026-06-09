# Appendices

This section is for reference. Use it when you need to look up a command, a syntax rule, or a definition without digging through the chapters.

## Appendix A: Installation and CLI Reference

### Installation

If you’re working on a real project, Gengo is probably already built into your host application. But if you want to run the examples in this book on your own, you’ll need the Gengo CLI.

1.  **Prerequisites**: You’ll need the **Zig** compiler (we’re using version 0.16.0).
2.  **Get the Source**: `git clone https://github.com/gengoscript/gengo.git`
3.  **Build**:
    ```bash
    cd gengo
    zig build -Dpreset=dev cli
    ```
4.  **Test it**: `./zig-out/bin/gengo --version`

### CLI Reference

*   **`gengo <file.gengo>`**: Run a script.
*   **`gengo`**: Start the REPL. Great for testing small snippets.
*   **`--cap <name>`**: Enable a capability (e.g., `fs`, `http`).
*   **`--max-ops <N>`**: Set the instruction budget. If the script takes more than N steps, it’s killed.
*   **`--backend <embedded|host>`**: Choose how the code runs.

---

## Appendix B: Quick Syntax Reference

### Bindings
*   `x := 5` (Variable)
*   `const y := 10` (Constant)
*   `z int = 15` (Explicitly typed)

### Control Flow
*   `if / else if / else`
*   `switch / case / default`
*   `for condition { ... }`
*   `for i := 0; i < 10; i++ { ... }`
*   `for item in collection { ... }`

### Types
*   `type Name int range 1..10`
*   `type Name int cycle 0..23`
*   `type Name struct { field type }`
*   `type Name variant { arm { data type }, arm2 }`
*   `type Name interface { method() type }`

---

## Appendix C: Standard Library (The `std` Namespace)

*   **`std.io`**: Printing to the host (`println`).
*   **`std.core`**: The essential toolkit (`len`, `append`, `has`, `error`, `recover`).
*   **`std.conv`**: Turning strings into numbers and vice versa.
*   **`std.math`**: The usual suspects (`abs`, `pow`, `sqrt`).
*   **`std.string`**: Slice, dice, and transform text.
*   **`std.json`**: Parse and stringify with ease.
*   **`std.time`**: Because time is harder than it looks.

---

## Appendix D: Common Errors (And what they really mean)

*   **`TypeError`**: You tried to mix things that don't belong together. Check your types.
*   **`RangeError`**: You tried to force a value into a type that won't accept it.
*   **`PredicateViolation`**: Your custom validation logic said "No."
*   **`AssignToConst`**: You tried to change something you promised would stay the same.
*   **`CapabilityNotAvailable`**: You forgot the `--cap` flag.
*   **`InstructionBudgetExceeded`**: Your script ran too long. Check for infinite loops.

---

## Appendix E: Glossary (Engineer's Edition)

*   **Abstraction**: Hiding the messy details so you can focus on the big picture.
*   **Assertion**: A "this should never happen" check. If it fails, your code has a bug.
*   **Binding**: Giving a value a name so you can find it again.
*   **Capability**: An explicit permission. Gengo's way of keeping you safe.
*   **Contract**: An agreement between two parts of a program. Usually enforced by types.
*   **Decomposition**: Breaking a big problem into small, manageable pieces.
*   **Invariant**: A rule that must **always** be true for your data to be valid.
*   **Spiral Method**: Learning by circling back to concepts with more depth each time.

---

## Appendix F: Suggested Projects

1.  **A Unit Converter**: Build a system that handles multiple units (meters, feet, etc.) using custom types to prevent accidental mixing.
2.  **A Policy Engine**: Use `cap:fs` to read a set of business rules from a file and apply them to a stream of data.
3.  **A Weather CLI**: Use `cap:http` to fetch real-time weather and use a `variant` type to represent different conditions (Sun, Rain, Snow).
4.  **A Simple Linter**: Write a Gengo script that analyzes *other* Gengo scripts for common mistakes.
