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

Identifiers may contain Unicode letters and decimal digits, following the same rules as Go: the first character must be a Unicode letter or underscore, and subsequent characters may be Unicode letters, decimal digits, or underscores. Identifiers are not normalized — two visually identical identifiers that differ at the byte level are distinct.

Type names cannot be shadowed: no variable, function, parameter, receiver,
named return, or loop variable may be named after a primitive type or any
declared type (`var bool bool` and `func string() {}` are compile errors).

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
user := {"name": "Ada", "active": true}
std.io.println(user.name)
```

Map keys are expressions: quote string keys (`"name"`), or use a variable
to key dynamically (`{k: 1}` uses the *value* of `k`). A bare identifier
in key position is a variable reference, not a string.

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

Conditions are `bool`-only: `if`, `not`, `and`, `or`, and template `{{if}}`
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

Named returns let a `defer` modify the function's return value before it exits:

```gengo
func safe_div(a int, b int) (result int) {
    defer func() {
        e := std.core.recover()
        if std.core.is_error(e) {
            result = 0
        }
    }()
    result = a / b
    return result
}
```

## Defer and Recover

`defer` schedules a function call to run when the enclosing function returns, even during a panic unwind. Deferred calls run in LIFO order.

```gengo
func with_cleanup() {
    defer std.io.println("cleanup")
    std.io.println("body")
    // prints: body, then cleanup
}
```

`std.core.recover()` catches a panic from inside a `defer` function and stops the unwind. It returns the panic payload (an `error` value), or `null` if no panic is in progress.

```gengo
core := std.core

func attempt(x int) (ok bool) {
    defer func() {
        e := core.recover()
        if core.is_error(e) {
            ok = false
        }
    }()
    _ = someOperation(x)
    return true
}
```

`recover()` only has effect when called directly inside a `defer` function during an active panic. Calling it outside a defer, or after the panic has already been recovered, returns `null`.

## Named Types

Named types are central to the language. They let scripts model domain rules directly instead of treating everything as unstructured maps and validating later.

Named scalar types:

```gengo
type UserId string
type Port int range 1..65535
type Hour int cycle 0..23
```

Fixed-point decimal types store an exact scaled integer. The number after `decimal` is the scale (decimal places):

```gengo
type Money decimal 2

m := Money(9.99)     // stored as 999 internally
std.io.println(m)    // prints: 9.99

type Percent decimal 2 range 0..1
p := Percent(0.50)
```

Decimal types support the same arithmetic, range, predicate, and subtype features as integer named types. They do not mix with bare `float` or `int`.

Range types reject out-of-range values at construction time:

```gengo
type Severity int range 0..5

s := Severity(3)   // ok
// Severity(9)     // runtime range error
```

Cycle types wrap through their declared domain during arithmetic. `cycle`
works on any numeric base — `int`, `float`, or `decimal`.

```gengo
type Hour int cycle 0..23

h := Hour(23)
std.io.println(h + Hour(1))  // 0
```

Integer cycles are discrete: the domain is `max - min + 1` inclusive steps,
so `cycle 0..23` has 24 distinct values and 23 + 1 wraps to 0. Float and
decimal cycles are continuous instead: the endpoints are the same point, so
`max` itself wraps to `min`:

```gengo
type Degrees float cycle 0.0..360.0

std.io.println(Degrees(360.0))            // 0 — max wraps to min
std.io.println(Degrees(350.0) + Degrees(20.0))  // 10
```

Subtypes allow narrower domains inside an existing named type. Any scalar
named type can be a parent; `range`/`cycle` constraints require a numeric
parent:

```gengo
type Percent int range 0..100
subtype PassingGrade Percent range 60..100

type UserId string
subtype AdminId UserId    // distinct name, substitutable for UserId

type Flag bool
subtype Strict Flag       // works in conditions like its parent
```

Enum subtypes narrow the member set instead:

```gengo
type Days enum { mon, tue, wed, thu, fri, sat, sun }
subtype Weekend Days { sat, sun }
```

Predicate types attach an arbitrary boolean check to a named scalar type. The predicate fires every time a value is constructed or cast into the type. If it returns `false`, the script panics:

```gengo
type Port      int   predicate func(x) { return x >= 1 and x <= 65535 }
type Tag       string predicate func(s) { return std.core.len(s) > 0 }
type EventCode int   predicate func(x) { return x % 2 == 0 }

p := Port(8080)    // ok
// Port(0)         // runtime predicate violation
// EventCode(3)    // runtime predicate violation
```

The predicate parameter name is arbitrary; the compiler infers its type from the base type and requires a `bool` return. The predicate is a closure and may close over variables and functions from the enclosing scope:

```gengo
max_retries := 5

type RetryCount int predicate func(n) { return n >= 0 and n <= max_retries }
```

Predicates work on any scalar base type (`int`, `float`, `string`, `bool`, `rune`). They cannot be declared on collection types, enums, or variants.

### Predicate Custom Messages

A predicate may declare a custom failure message that replaces the generic
"predicate failed" runtime error:

```gengo
type PositiveInt int predicate func(x) { return x > 0 } message "must be positive"

// PositiveInt(-1)   // runtime error: PositiveInt(-1): must be positive
```

### Predicate Inheritance

Subtypes inherit the parent’s predicate. A subtype with its own predicate
must satisfy *both* the parent and the subtype checks:

```gengo
type UserId string predicate func(s) { return std.core.len(s) > 0 }
subtype AdminId UserId predicate func(s) { return std.string.starts_with(s, "admin:") }

a := AdminId("admin:42")   // ok
// AdminId("")             // fails parent predicate (empty string)
// AdminId("user:42")      // fails subtype predicate (wrong prefix)
```

### Named String Concatenation

Values of the same named string type can be concatenated with `+`, preserving
the named type:

```gengo
type Html string

h1 := Html("<p>")
h2 := Html("hi</p>")
std.io.println(h1 + h2)           // prints: <p>hi</p>
std.io.println(Html("<hr>") + Html("<br>"))
```

### Named Array and Map Types

A named type can also wrap an array or map, using the same bracket syntax as
struct fields and `var` declarations:

```gengo
type Points []int
type Scores map[string]int   // or: type Scores [string]int

p := Points([1, 2, 3])
s := Scores({"alice": 100})
```

`[]T` is the only array spelling. `[K]V` and `map[K]V` are both valid map
spellings with identical meaning — `map` is optional, not required.

A bracketed type with nothing after the closing `]` (`[K]` with no `V`) is a
compile error rather than being read as "array of `K`". This is deliberate:
that shape is what a forgotten map value type looks like, and silently
reinterpreting it as an array would hide exactly that mistake. Write `[]K`
if you actually want an array of `K`.

Mixing different named string types or a named type with a bare string is a
`TypeError`.

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

## Comparing by Type

A union-typed value (`int|string`, or a wider union) can be compared by its
runtime type with `.type`:

```gengo
type Person struct { id int|string }
p := Person{ id: 42 }

if p.id.type == int { std.io.println("numeric id") }

switch p.id.type {
    case int { std.io.println("numeric id") }
    case string { std.io.println("string id") }
}
```

`.type` is intentionally restricted — it is **not** a general expression.
It is only valid directly compared with `==`/`!=` (on either side: `p.id.type
== int` and `int == p.id.type` both work), or as a `switch` scrutinee. It
cannot be assigned to a variable, passed as an argument, or chained further
(`x.type.foo` is a compile error), and a `switch x.type { }` cannot mix in
variant-arm patterns (`case .arm_name`). The right-hand side must be a
concrete type: a primitive (`int`, `float`, `bool`, `string`, `rune`,
`decimal`, `error`, `map`) or a declared named/struct/enum/variant type —
**not** an interface, since interfaces are method-set constraints, not
concrete runtime types, so `.type` can never equal an interface name.

The result of a `.type` comparison is an ordinary `bool`, freely usable
anywhere a `bool` is — including combined with `and`/`or`.

## Interfaces

Interfaces declare method sets; any value whose type has the methods
satisfies the interface — structs, named types, enums, and variants alike.

```gengo
type Adder interface {
    add(float) float
}

type Acc struct { total float }

func (a Acc) add(x float) float {
    return a.total + x
}

func sum(a Adder) float {
    return a.add(1.0)
}
```

Method parameters in an interface are written as bare types (`add(float)`)
or `name type` pairs (`add(x float)`); the names are documentation only.

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

## Testing

Test blocks are first-class syntax. They live at the top level of a script alongside regular declarations:

```gengo
std := import("std")

func add(a int, b int) int {
    return a + b
}

test "add is commutative" {
    assert add(1, 2) == add(2, 1)
}

test "add with zero" {
    assert add(5, 0) == 5
    assert add(0, 5) == 5
}
```

`assert condition` panics with `AssertionFailed` if the condition is `false`. An optional message string gives a clearer failure reason:

```gengo
test "range check" {
    assert x >= 0, "x must be non-negative"
}
```

**Normal execution skips test blocks.** Running `gengo script.gengo` executes the script body but ignores all `test` blocks entirely. No test code runs, and no test infrastructure is paid for.

**`--test` activates them:**

```bash
gengo script.gengo --test
```

Each test block runs in order. Results go to stderr:

```text
PASS: add is commutative
PASS: add with zero
PASS: range check

3 passed, 0 failed
```

A failing test reports the error name and message:

```text
FAIL: range check: AssertionFailed: x must be non-negative

2 passed, 1 failed
```

The process exits non-zero if any test fails.

## Practical Reading Order

If you are new to the language:

1. read `tutorial-first-script.md`;
2. return here for the main language model; and
3. use `stdlib.md` as the function reference while writing scripts.
