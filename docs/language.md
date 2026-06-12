# Gengoscript Language Guide

This page describes the public language model of Gengoscript. It is intended to help readers write and review scripts, not to serve as an internal implementation dump.

For library functions, see `stdlib.md`. For embedding and capability control, see `embedding.md`.

## Design Shape

Gengoscript is a small host-embedded language with:

- explicit imports;
- nominal types for domain modelling;
- bounded execution under host control; and
- no ambient access to the machine.

The syntax is intentionally compact and broadly familiar to anyone who has used Go-like languages.

## Modules and Imports

Imports are explicit:

```gengo
std  := import("std")
http := import("cap:http")
db   := import("host:db")
math := import("./math")
```

Kinds of import:

- `std` for the standard library;
- `cap:*` for host-enabled capabilities such as HTTP or filesystem access;
- `host:*` for host-defined modules; and
- relative imports such as `./math` for source modules.

Built-ins are accessed through namespaces such as `std.io.println(...)` and `std.core.len(...)`. Legacy global forms such as `println(...)` are not supported.

## Values

The language includes:

- `int`
- `float`
- `bool`
- `string`
- `rune`
- `null`
- `error`
- arrays
- maps
- structs
- functions

Strings are UTF-8. `std.core.len(s)` counts Unicode code points, while `std.core.bytelen(s)` counts bytes.

Numeric types do not mix implicitly: `int` and `float` cannot be combined in
arithmetic or ordering comparisons (`1.5 + 1` and `1.5 > 1` are both type
errors). Convert one side explicitly — `1.5 > float(1)` or write the literal
as `1.0`. The same rule applies to named types: an `Age` only mixes with an
`Age` (or its subtypes), never with a bare `int`.

## Variables and Constants

Common declaration forms:

```gengo
name := "gengo"
const limit := 10
count int = 3
const port Port = Port(443)
```

Assignment uses `=`. Compound assignment such as `+=` and `-=` is supported. `const` bindings cannot be reassigned, though mutable values stored inside them may still be mutated.

## Literals

Strings:

```gengo
"escaped"
'raw'
```

Multiline raw strings use a Zig-style `\\` prefix per line:

```gengo
msg :=
    \\Hello
    \\World
```

Rune literals use backticks:

```gengo
`A`
`å`
`🙂`
```

## Collections

Arrays:

```gengo
nums := [1, 2, 3]
std.io.println(nums[0])
```

Maps:

```gengo
user := {name: "Ada", active: true}
std.io.println(user.name)
```

Structs:

```gengo
type User struct {
    name string
    age  int
}

u := User{ name: "Ada", age: 37 }
```

Arrays and strings support slicing with `a:b`, `:b`, and `a:`.

## Control Flow

Conditionals:

```gengo
if score >= 10 {
    return "ok"
} else {
    return "retry"
}
```

Conditions are `bool`-only: `if`, `!`, `&&`, `||`, and template `{{if}}`
reject every other type (`if 1 { }` is a runtime type error — there is no
truthiness). Named types over `bool` participate through their base, the
same way named ints participate in arithmetic. For everything else, write
a comparison or convert explicitly with `std.conv.to_bool`.

Loops:

```gengo
for i := 0; i < 3; i++ {
    std.io.println(i)
}
```

Iteration:

```gengo
for item in items {
    std.io.println(item)
}
```

Pattern-based branching uses `switch`.

## Functions

Functions are declared with `func`:

```gengo
func add(a int, b int) int {
    return a + b
}
```

Gengoscript supports closures, methods, and multi-value returns. Functions may be exported from a source module with `pub`.

## Named Types

Named types are central to the language. They let scripts model domain rules directly instead of treating everything as unstructured maps and validating later.

Named scalar types:

```gengo
type UserId string
type Port int range 1..65535
type Hour int cycle 0..23
```

Range types reject out-of-range values at construction time:

```gengo
type Severity int range 0..5

s := Severity(3)   // ok
// Severity(9)     // runtime range error
```

Cycle types wrap through their declared domain during arithmetic:

```gengo
type Hour int cycle 0..23

h := Hour(23)
std.io.println(h + Hour(1))  // 0
```

Subtypes allow narrower domains inside an existing named type:

```gengo
type Percent int range 0..100
subtype PassingGrade Percent range 60..100
```

## Enums and Variants

Enums provide closed sets of values:

```gengo
type Mode enum { dev, staging, production }
```

Variants model tagged alternatives:

```gengo
type Event variant {
    Metric  { name string, value int },
    Ping,
    Error   { message string },
}
```

Use `switch` to branch on variant values:

```gengo
switch ev {
    case Event.Metric:
        return ev.name
    case Event.Error:
        return ev.message
    default:
        return "ok"
}
```

## Capability Imports

Capabilities are not available unless the host enables them.

Current public capability modules:

- `cap:http`
- `cap:fs`
- `cap:net`

If a script imports a capability the host has not enabled, compilation fails. Filesystem access is further restricted to host-registered mounts.

## Host Modules

Host-defined modules let the embedding application expose a narrow integration surface:

```gengo
db := import("host:db")
```

Scripts can call only the functions the host registered. There is no ambient reflection or implicit access to host functionality.

## Errors and Runtime Behaviour

Gengoscript distinguishes:

- compile errors;
- runtime errors; and
- first-class `error` values created inside the language.

The host may also enforce:

- an instruction budget;
- heap limits;
- frame and stack limits; and
- capability restrictions.

These limits are part of normal embedding, not exceptional deployment machinery.

## Practical Reading Order

If you are new to the language:

1. read `tutorial-first-script.md`;
2. return here for the main language model; and
3. use `stdlib.md` as the function reference while writing scripts.
