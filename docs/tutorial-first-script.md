# Gengoscript Tutorial: an approval policy

You will build one small approval policy from a print statement to a
host-callable, budgeted, multi-file script. Every command below runs from the
repository root and uses an installed `gengo`; for a source checkout,
substitute `./zig-out/bin/gengo`.

## 1. Print a value

Create `tutorial/main.gengo`:

```gengo
std := import("std")
std.io.println("Ada: approved")
```

Run it with `gengo tutorial/main.gengo`. It prints:

```text
Ada: approved
```

`import("std")` accesses the standard library; `std.io.println` writes a
line. You now have a runnable script.

## 2. Introduce variables and a function

Replace `tutorial/main.gengo` with this complete file:

```gengo
std := import("std")

func message(name string) string {
    return name + ": approved"
}

name := "Ada"
std.io.println(message(name))
```

Run the same command. The output is still `Ada: approved`. `name` is a
variable; `message` declares input and return types, then returns a string.

## 3. Make the policy callable

Hosts call exported functions, so change the file to:

```gengo
std := import("std")

pub func evaluate(name string, raw_score int) string {
    if raw_score >= 60 {
        return name + ": approved"
    }
    return name + ": review"
}

std.io.println(evaluate("Ada", 91))
```

It prints `Ada: approved`. `pub` makes `evaluate` available through the
embedding API. A host supplies `name` and `raw_score`; the script returns a
decision instead of reading ambient input.

## 4. Protect the score boundary

Raw integers can represent impossible scores. Add a named range type:

```gengo
std := import("std")

type Score int range 0..100

pub func evaluate(name string, raw_score int) string {
    if raw_score < 0 or raw_score > 100 {
        return "invalid score"
    }
    score := Score(raw_score)
    if score >= Score(60) {
        return name + ": approved"
    }
    return name + ": review"
}

std.io.println(evaluate("Ada", 91))
std.io.println(evaluate("Ada", 101))
```

Run it. The exact output is:

```text
Ada: approved
invalid score
```

The validation happens before `Score(raw_score)`. Constructing `Score(101)`
directly would fail its range contract. You have learned when to validate
untrusted input and when to rely on a named type.

## 5. Use a collection

Add a collection of recent scores without changing the public function:

```gengo
std := import("std")

type Score int range 0..100

pub func evaluate(name string, raw_score int) string {
    if raw_score < 0 or raw_score > 100 {
        return "invalid score"
    }
    score := Score(raw_score)
    recent := [Score(72), Score(91), score]
    if std.core.len(recent) != 3 {
        return "invalid score"
    }
    if score >= Score(60) {
        return name + ": approved"
    }
    return name + ": review"
}

std.io.println(evaluate("Ada", 91))
std.io.println(evaluate("Ada", 101))
```

The output is unchanged. Arrays preserve order; `std.core.len` returns their
element count. A common mistake is to compare a `Score` directly to `60`;
write `Score(60)` because named and base numeric types do not mix implicitly.

## 6. Move policy code into a module

Create `tutorial/policy.gengo`:

```gengo
type Score int range 0..100

pub func evaluate(name string, raw_score int) string {
    if raw_score < 0 or raw_score > 100 {
        return "invalid score"
    }
    score := Score(raw_score)
    if score >= Score(60) {
        return name + ": approved"
    }
    return name + ": review"
}
```

Then replace `tutorial/main.gengo` with:

```gengo
std := import("std")
policy := import("./policy")

pub func evaluate(name string, raw_score int) string {
    return policy.evaluate(name, raw_score)
}

std.io.println(evaluate("Ada", 91))
std.io.println(evaluate("Ada", 101))
```

Run `gengo tutorial/main.gengo`. It prints the same two lines as
before. `./policy` resolves next to `main.gengo`; only `pub` names from the
module are visible to its importer.

## 7. Add a test block

Replace `tutorial/main.gengo` with this complete file:

```gengo
std := import("std")
policy := import("./policy")

pub func evaluate(name string, raw_score int) string {
    return policy.evaluate(name, raw_score)
}

test "approval policy" {
    assert(evaluate("Ada", 91) == "Ada: approved")
    assert(evaluate("Ada", 101) == "invalid score")
}

std.io.println(evaluate("Ada", 91))
std.io.println(evaluate("Ada", 101))
```

The complete final project is also checked by the documentation CI fixture at
`tools/site-builder/fixtures/tutorial/`. Test blocks describe assertions for
the test runner; normal CLI execution still prints:

```text
Ada: approved
invalid score
```

## 8. Call it from a host and set a budget

The exported `evaluate` function is the host boundary. For a TypeScript/WASM
host, load both source files and call it after successful compilation:

```ts
engine.addSource("tutorial/policy.gengo", policySource);
const result = engine.runPath(mainSource, "tutorial/main.gengo");
if (!result.ok) throw new Error(result.message);
const decision = engine.call("evaluate", [gstr("Ada"), gnum(91)]);
```

Use a finite instruction budget in a production host. The Zig embedding API
uses `max_ops` at runtime creation:

```zig
var rt = try api.Runtime.init(.{
    .allow_io = false,
    .max_ops = 10_000,
});
defer rt.deinit();
```

The budget limits VM instructions, not time spent in a host callback. Continue
with `typescript-sdk.md`, `embedding.md`, or `engine-api.md` for a complete
integration, and read `security.md` before running untrusted scripts.
