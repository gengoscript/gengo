# Gengoscript Language Guide

This page describes the public language model of Gengoscript. It is meant to
be read by humans first, but it is also written to be mechanically clear:
examples are concrete, terminology is consistent, and edge cases are called
out where they change how code behaves.

For library functions, see `stdlib.md`. For embedding and capability control, see `embedding.md`.

Within this repository, the executable conformance suite in `tests/spec/` is
the final authority on language behaviour. This guide tracks that surface.

## Design Shape

Gengoscript is a capability-bounded, host-embedded language. It is designed
to be integrated into a larger application — think policy enforcement,
user-defined logic, or plugin-style scripting — not to stand alone. Scripts
are contained: every import, every capability, and every allocation budget
comes from the host. The language itself has no file system, no network, and
no system calls. If a script needs those, the host decides whether to provide
them.

The syntax is compact and broadly familiar to anyone who has used
Go-like languages. The type system leans on nominal types (named wrappers
around scalars, structs, enums, and variants) so that domain rules can be
expressed directly in types rather than pushed into runtime validation.

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

### Exporting from Modules

A source module can export functions, values, and types with `pub`:

```gengo
// geometry/shapes.gengo
pub const version := "v1"
pub func origin() Point { return Point{ x: 0, y: 0 } }
pub type Point struct { x int, y int }
pub type Distance int
```

### Module-Qualified Types

Once imported, the alias can be used to name the module's exported types in function signatures, struct fields, and variable declarations:

```gengo
geo := import("./geometry/shapes")

func make_point(x int, y int) geo.Point {
    return geo.Point { x: x, y: y }
}

func scale(d geo.Distance, factor int) geo.Distance {
    return geo.Distance(int(d) * factor)
}

type Segment struct { a geo.Point, b geo.Point }

var origin geo.Point = geo.Point { x: 0, y: 0 }
d := geo.Distance(10)
```

### Import Sandboxing (CLI)

When running a script with the native CLI or the WASM binary, file imports are restricted to the script's own directory by default. Imports that escape with `../` are rejected:

```bash
# blocked — outside the script's directory
t := import("../shared/utils")
```

To allow additional directories, pass `--modules` (repeatable):

```bash
gengo --modules /app/shared --modules /app/lib script.gengo
```

Embedded runtimes created through the Zig API are unrestricted unless `source_root` is set explicitly in the config.

## Values

The value types fall into three groups. Scalar types hold a single value:

- `int`, `float`, `decimal`, `bigint`, `bool`, `string`, `rune`, `null`, `error`

Collection types hold multiple values:

- arrays, maps, structs, tuples

Tuple values exist, but they are a narrow surface today: scripts mainly see
them when a multi-value return is captured into a single variable rather than
destructured. There is no separate tuple literal or tuple type declaration
syntax documented for general use.

Functions are values too — they can be passed around, assigned, and closed
over.

Strings are UTF-8. `std.core.len(s)` counts Unicode code points, while
`std.core.bytelen(s)` counts bytes.

Optional types use `?T`. A value of type `?T` is either `null` or a `T`:

```gengo
var name ?string
name = "Ada"
name = null
```

The `??` (null-coalescing) operator returns the left-hand side if it is not
`null`, otherwise it evaluates and returns the right-hand side:

```gengo
label := name ?? "anonymous"
```

The right-hand side is only evaluated when the left-hand side is `null`
(short-circuit). `??` is right-associative: `a ?? b ?? c` is `a ?? (b ?? c)`.

A key design rule: **numeric types do not mix implicitly**. `int` and `float`
cannot be combined in arithmetic or ordering comparisons (`1.5 + 1` and
`1.5 > 1` are both type errors). Convert one side explicitly —
`1.5 > float(1)` or write the literal as `1.0`. The same rule applies to
named types: an `Age` only mixes with an `Age` (or its subtypes), never with
a bare `int`. This is intentional — it prevents the kind of subtle precision
loss and domain confusion that plague languages with implicit numeric
coercion.

`bigint` is the arbitrary-precision integer type. Construct it with
`bigint(...)` from an `int`, a whole-number `float`, or a decimal string:

```gengo
x := bigint(42)
y := bigint("99999999999999999999999999999999")
z := 1 + bigint(2)     // mixed int + bigint promotes to bigint
```

`bigint` supports integer arithmetic, comparison, unary `-`, `div`, `rem`,
`mod`, and exponentiation with `**`. It does not implicitly mix with `float`.

## Variables and Constants

Common declaration forms:

```gengo
name := "gengo"
const limit := 10
var count int = 3
const port Port = Port(443)
```

How each form works:

- `name := value` — declares a mutable variable, type is inferred from the
  initializer.
- `const name := value` — immutable binding. The variable cannot be
  reassigned, though the value itself (e.g. an array or struct) can still be
  mutated.
- `var name Type = value` — mutable with an explicit type annotation. The
  initializer may be omitted, in which case the variable gets the zero value
  (e.g. `0` for `int`, `""` for `string`, `null` for optional types). For a
  named scalar type with a declared `default`, that default value is used
  instead of the base type's zero value.
- `const name Type = value` — typed immutable binding.

Assignment uses `=`. Compound assignment forms (`+=`, `-=`, `*=`, `/=`) are
supported for numeric types.

Bitwise operators work on integer types (`int` and named integer types):

| Operator | Meaning |
|----------|---------|
| `&` | Bitwise AND |
| `\|` | Bitwise OR |
| `^` | Bitwise XOR |
| `~` | Bitwise NOT (complement) |
| `<<` | Left shift |
| `>>` | Right shift |

Bitwise compound assignment forms are also supported: `&=`, `|=`, `^=`, `<<=`, `>>=`.

Integer division and remainder use keyword operators, following Ada/Pascal convention:

| Operator | Meaning | Example |
|----------|---------|---------|
| `div` | Integer division: truncates toward zero for `int`; floor (rounds toward −∞) for `float` | `7 div 2` → `3`, `-7.0 div 2.0` → `-4.0` |
| `rem` | Remainder, sign follows the dividend | `7 rem 3` → `1`, `-7 rem 3` → `-1` |
| `mod` | Mathematical modulo, result always non-negative when divisor is positive | `7 mod 3` → `1`, `-7 mod 3` → `2` |

`/` divides floats (or integer-to-float when both sides are the same named float type). For integer truncating division use `div`; for float floor division also use `div`. All three keyword operators work on named numeric types.

Identifier rules follow Go: the first character must be a Unicode letter or
underscore; subsequent characters may be Unicode letters, decimal digits, or
underscores. Identifiers are not normalized — two identifiers that differ at
the byte level are distinct even if they look the same on screen.

One gotcha: **type names cannot be shadowed**. No variable, function,
parameter, receiver, named return, or loop variable may share a name with a
primitive type or any declared type (`var bool bool` and `func string() {}`
are compile errors).

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

Integer literals can be written in decimal, hexadecimal, binary, or octal.
Digit separators (`_`) are allowed in all bases:

```gengo
x := 255
x := 0xFF
x := 0b1111_1111
x := 0o377
```

Floating-point literals support scientific notation:

```gengo
f := 1.5e2    // 150.0
f := 2.5e-1   // 0.25
```

## Explicit Conversions

Gengoscript uses explicit conversion syntax rather than implicit coercion.
The general form is `TypeName(value)`:

```gengo
n := int(3.9)          // 3
f := float(true)       // 1.0
b := bool(2)           // true
s := string(`A`)       // "A"
x := bigint("123456")
```

Named types use the same syntax for construction and re-boxing:

```gengo
type UserId string
type Age int range 0..100

id := UserId("u-1")
age := Age(42)

raw_id := string(id)
raw_age := int(age)
```

Important distinctions:

- Built-in casts and named-type constructors are part of the language.
- `std.conv.*` functions are library helpers with slightly different
  behaviour and coverage.
- `std.conv.to_string(null)` returns `""`, but `string(null)` is a runtime
  `TypeError`.
- Constructing a named type still enforces its `range`, `cycle`,
  `predicate`, and `default` rules where applicable.

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
    name string,
    age  int,
}

u := User{ name: "Ada", age: 37 }
```

Fields typed as `[]T`, `[K]V`, or `?T` are heap-referenced and can safely reference the enclosing struct type, enabling recursive data structures:

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

Mark a field `const` to make it read-only after construction:

```gengo
type Point struct {
    const x int,
    const y int,
}

p := Point{ x: 3, y: 4 }
// p.x = 5  // compile error: cannot assign to const field
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

An `if` may include an init statement before the condition, scoped to the branch:

```gengo
if result := lookup(key); result != null {
    std.io.println(result)
}

if const x := parse(input); x > 0 {
    return x
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

A second variable captures the index (for arrays) or key (for maps):

```gengo
for i, item in items {
    std.io.println(i, item)
}

for k, v in lookup {
    std.io.println(k, v)
}
```

`break` exits a loop early; `continue` skips to the next iteration:

```gengo
for x in data {
    if x < 0 { continue }
    if x > 100 { break }
    std.io.println(x)
}
```

Value-based branching uses `switch`:

```gengo
switch status {
    case 200 { return "ok" }
    case 404 { return "not found" }
    default  { return "unknown" }
}
```

A case may carry a `when` guard: the case matches only if its pattern matches
*and* the guard expression evaluates to `bool(true)`. A failed guard falls through to the
next case, so cases are tested top to bottom:

```gengo
switch port {
    case 80, 443 when port == 443 { return "https" }
    case 80, 443                  { return "http" }
    case port when port > 1024    { return "unprivileged" }
    default                       { return "privileged" }
}
```

Pattern-based branching uses `switch` (see [Enums and Variants](#enums-and-variants)).

## Functions

Functions are declared with `func`:

```gengo
func add(a int, b int) int {
    return a + b
}
```

Trailing parameters may declare a default value with `=`. Callers can omit
any suffix of defaulted parameters:

```gengo
func greet(name string, greeting string = "Hello") string {
    return greeting + " " + name
}

greet("World")           // "Hello World"
greet("World", "Hi")     // "Hi World"
```

Default values must be literals (number, string, bool, or `null`). All
parameters after the first defaulted one must also have defaults.

Variadic parameters use `...` and must appear last:

```gengo
func sum(base int, ...rest int) int {
    total := base
    for x in rest { total += x }
    return total
}
```

The variadic parameter is an array value inside the function. It may be empty.

Multi-value return types are written in parentheses:

```gengo
func min_max(a int, b int) (int, int) {
    if a < b { return a, b }
    return b, a
}

lo, hi := min_max(7, 3)  // destructure into two variables
std.io.println(lo, hi)
```

If a call returning multiple values is assigned to a single variable, the
values are captured as a tuple:

```gengo
pair := min_max(7, 3)
std.io.println(std.core.len(pair))   // 2
```

This is currently the main user-facing way tuple values appear in scripts.

Named returns declare local result variables in the function signature. A bare
`return` returns their current values:

```gengo
func divide(a float, b float) (result float, err ?error) {
    if b == 0 {
        err = std.core.error("division by zero")
        return
    }
    result = a / b
    return
}
```

Functions, types, and variables may be exported from a source module with `pub`. Closures capture variables from the enclosing scope by reference.

Methods use a receiver in front of the function name. Structs, named scalar
types, enums, and variants can all have methods:

```gengo
type Meters int

func (m Meters) doubled() Meters {
    return Meters(int(m) * 2)
}
```

Method-call syntax is sugar for passing the receiver as the first argument:
`x.f(y)` and `Type.f(x, y)` mean the same thing.

Receivers are values, not implicit references. Reassigning receiver fields
inside a method does not mutate the caller's variable unless the receiver
contains shared heap-backed state that the method mutates explicitly.

Named returns also let a `defer` modify the function's return value before it exits:

```gengo
func safe_div(a int, b int) (result int) {
    defer func() {
        e := std.core.recover()
        if std.core.is_error(e) {
            result = 0
        }
    }()
    result = a div b
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

Instance methods can be deferred directly:

```gengo
func with_report() {
    var conn Database = open(":memory:")
    defer conn.close()
    conn.exec("INSERT ...")
}
```

When the base name refers to a type (not an instance), the first argument to the method call is promoted to receiver position:

```gengo
func with_report() {
    var conn Database = open(":memory:")
    defer Database.close(conn)
    conn.exec("INSERT ...")
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

Named scalar types may also declare a default value. A `var` declaration with
no initializer uses that default:

```gengo
type Port int range 1..65535 default 443
type Enabled bool default true

var p Port
var on Enabled
```

Range types reject out-of-range values at construction time:

```gengo
type Severity int range 0..5
type Port     int range 1..65535
type Byte     int range 0x00..0xFF
type Flags    int range 0b0000..0b1111

s := Severity(3)   // ok
// Severity(9)     // runtime range error
```

Range bounds can be written in any numeric base. The type object exposes
`.first` and `.last` as named values at the declared bounds:

```gengo
std.io.println(Port.first)   // Port(1)
std.io.println(Port.last)    // Port(65535)
```

Named numeric types also expose `.succ(value)` and `.pred(value)` on the type
object. Range types step by one and clamp to the declared domain; cycle types
step by one and wrap:

```gengo
type Step int range 1..100
type Hour int cycle 0..23

std.io.println(Step.succ(Step(50)))   // 51
std.io.println(Step.pred(Step(50)))   // 49
std.io.println(Hour.succ(Hour(23)))   // 0
std.io.println(Hour.pred(Hour(0)))    // 23
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

Subtypes inherit the parent type's methods. That inheritance is transitive
across subtype chains.

Enum subtypes narrow the member set instead:

```gengo
type Days enum { mon, tue, wed, thu, fri, sat, sun }
subtype Weekend Days { sat, sun }
```

Predicate types attach an arbitrary boolean check to a named scalar type. The predicate fires every time a value is constructed or cast into the type. If it returns `false`, the script panics:

```gengo
type Port      int   predicate func(x) { return x >= 1 and x <= 65535 }
type Tag       string predicate func(s) { return std.core.len(s) > 0 }
type EventCode int   predicate func(x) { return x rem 2 == 0 }

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

### Named Error Types

An error type is a named `error` type. It lets callers distinguish failure
causes by type rather than by string matching:

```gengo
type NotFound error
type PermissionDenied error

func lookup(key string) (string, error) {
    if key == "missing"  { return "", NotFound("no row") }
    if key == "secret"   { return "", PermissionDenied("forbidden") }
    return key, std.core.error("")
}
```

Named errors are ordinary `error` values: `std.core.is_error` returns `true`,
`string(e)` returns the message, and they pass typed function parameters that
expect `error`. The type is inspectable with `.type`:

```gengo
_, e := lookup("missing")

switch e.type {
    case NotFound         { std.io.println("not found") }
    case PermissionDenied { std.io.println("denied") }
    default               { std.io.println("other") }
}

std.io.println(e.type == NotFound)           // true
std.io.println(e.type == PermissionDenied)   // false
std.io.println(string(e))                    // no row
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

Enums model a fixed set of values. Use them when a value must be one of a
known list and nothing else:

```gengo
type Mode enum { dev, staging, production }

env := Mode.staging
```

Members can be assigned explicit integer representation values. Unspecified
members increment from the previous value (starting at 0):

```gengo
type Status enum { pending = 0, active = 1, done = 2 }
type Color  enum { red = 10, green = 20, blue = 30 }
type Flags  enum { none = 0, read = 1, write = 2, exec = 4 }
```

Every enum value has a `.name` property (the member name as a string) and,
when the type has representation values, a `.int` property:

```gengo
s := Status.active
std.io.println(s.name)   // "active"
std.io.println(s.int)    // 1
```

The type object exposes `.first` and `.last` for the boundary members, and
`.from_int` for reverse lookup. `from_int` returns `?T` — null if no member
has that value:

```gengo
std.io.println(Status.first)          // pending
std.io.println(Status.last)           // done

s := Status.from_int(2)               // done
std.io.println(Status.from_int(99))   // null
```

Enum values expose `.ordinal`, and the type object exposes `succ(...)` and
`pred(...)` helpers:

- `T.succ(v)` — the next member, wrapping from the last back to the first.
- `T.pred(v)` — the previous member, wrapping from the first back to the last.
- `v.ordinal` — the 0-based position of this member in declaration order, independent of any representation value.

```gengo
type Day enum { mon, tue, wed, thu, fri, sat, sun }

std.io.println(Day.succ(Day.fri))    // sat
std.io.println(Day.succ(Day.sun))    // mon  (wraps)
std.io.println(Day.pred(Day.mon))    // sun  (wraps)
std.io.println(Day.wed.ordinal)   // 2
```

Variants model tagged unions — a value that can be one of several shapes,
each with its own fields. They are the natural way to represent success
vs. failure, different kinds of events, or parse results:

```gengo
type Event variant {
    Metric  { name string, value int },
    Ping,
    Error   { message string },
}
```

A variant arm with no fields (like `Ping` above) is just a tag. Arms with
fields carry their own data.

Single-payload arms may also be written with parentheses, which is concise
when the arm carries exactly one value:

```gengo
type Result variant {
    ok(value int),
    err(msg string),
    pending,
}
```

Use `switch` to branch on which variant arm you have. Case arms are matched
with a `.arm_name` prefix and the body in braces. An `as binding` clause
names the payload inside the case body:

```gengo
switch ev {
    case .Metric { return ev.name }
    case .Error  { return ev.message }
    default      { return "ok" }
}

// binding a single-payload arm:
switch r {
    case .ok as v   { return v }
    case .err as msg { return msg }
    case .pending   { return "pending" }
}
```

A variant `switch` inside a function is **exhaustive**: every arm must be
covered by at least one unguarded case, or the switch must have a `default`.
A missing arm is a compile error (`NonExhaustiveSwitch`). Variant switches at
the top level of a script are not checked for exhaustiveness.

Variant cases accept `when` guards too, and the guard sees the `as` binding.
A guarded case does not fully cover its arm, so exhaustiveness requires each
arm to have an unguarded case (or the switch a `default`):

```gengo
switch r {
    case .err as msg when std.core.len(msg) > 0 { return "error: " + msg }
    case .err       { return "error" }
    case .ok as v   { return v }
    case .pending   { return "pending" }
}
```

## Comparing by Type

Any value can be compared against a type name at runtime using `.type`:

```gengo
type Age int range 0..150
type Cat struct { name string }
type Result variant { ok(value int), err(msg string) }

a := Age(5)
c := Cat{ name: "tom" }
r := Result.ok(1)

if a.type == Age   { std.io.println("named type") }
if c.type == Cat   { std.io.println("struct") }
if r.type == Result { std.io.println("variant") }

switch c.type {
    case Cat { std.io.println("it's a cat") }
}
```

`.type` is intentionally restricted — it is **not** a general expression.
It is only valid directly compared with `==`/`!=` (on either side: `a.type
== Age` and `Age == a.type` both work), or as a `switch` scrutinee. It
cannot be assigned to a variable, passed as an argument, or chained further
(`x.type.foo` is a compile error), and a `switch x.type { }` cannot mix in
variant-arm patterns (`case .arm_name`). The right-hand side must be a
concrete type: a primitive (`int`, `float`, `bool`, `string`, `rune`,
`decimal`, `bigint`, `error`, `map`) or a declared named/struct/enum/variant type —
**not** an interface, since interfaces are method-set constraints, not
concrete runtime types, so `.type` can never equal an interface name.

The result of a `.type` comparison is an ordinary `bool`, freely usable
anywhere a `bool` is — including combined with `and`/`or`.

## Interfaces

An interface declares a set of methods. Any value whose type implements
those methods satisfies the interface automatically — there is no explicit
`implements` declaration. This works for structs, named types, enums, and
variants alike.

Use interfaces when you want to write a function that accepts any type
with a certain behaviour, without caring about its concrete type:

```gengo
type Adder interface {
    add(float) float
}

type Acc struct { total float }

func (a Acc) add(x float) float {
    return a.total + x
}

// sum accepts anything that can add.
func sum(a Adder) float {
    return a.add(1.0)
}

std.io.println(sum(Acc{ total: 5.0 }))  // 6.0
```

Method parameters in an interface can be written as bare types
(`add(float)`) or name-type pairs (`add(x float)`); the names are
documentation only and do not affect satisfaction.

## Generic Types

Struct and variant types can be parameterised with one or more type
parameters, written in `[T]` after the type name:

```gengo
type Stack[T] struct {
    items []T,
}

type Result[T, E] variant {
    ok(value T),
    err(e E),
}
```

Instantiate a generic type by supplying concrete type arguments wherever the
type is used. Each distinct combination of arguments is a separate concrete
type:

```gengo
s := Stack[int]{ items: [] }
s2 := Stack[string]{ items: ["hello", "world"] }

r  := Result[int, string].ok{ value: 42 }
r2 := Result[int, string].err{ e: "not found" }
```

This instantiation is compile-time and concrete. `Stack[int]` and
`Stack[string]` are different runtime types, not one shared erased container
type.

Pattern matching works the same as for non-generic variants. The `as`
binding names the payload directly:

```gengo
switch r {
    case .ok as v  { std.io.println(v) }    // v is the int 42
    case .err as e { std.io.println(e) }
}
```

Generic types can reference other generic types in their field definitions.
When the outer type is instantiated the inner type argument is substituted
automatically:

```gengo
type Wrapper[T] struct { inner Stack[T] }

w := Wrapper[int]{ inner: Stack[int]{ items: [1, 2, 3] } }
std.io.println(std.core.len(w.inner.items))   // 3
```

Type parameters may also carry optional constraints using the same `:`
syntax described below for generic functions.

### Generic Functions

Functions can also take type parameters using the same `[T]` syntax:

```gengo
func identity[T](x T) T {
    return x
}

func map_array[T, U](xs []T, f func(T) U) []U {
    result := []
    for x in xs {
        result = std.core.append(result, f(x))
    }
    return result
}
```

Call a generic function by passing arguments directly — type arguments are
inferred from context:

```gengo
n  := identity(42)
s  := identity("hello")

nums    := [1, 2, 3]
doubled := map_array(nums, func(x int) int { return x * 2 })
```

Explicit type arguments are also accepted and their count is validated:

```gengo
n  := identity[int](42)
doubled := map_array[int, int](nums, func(x int) int { return x * 2 })
```

Inference works from ordinary value arguments and from generic return
positions:

```gengo
type Box[T] struct { val T }

func boxed[T](x T) Box[T] {
    return Box[T]{ val: x }
}

a := identity(42)     // T = int
b := boxed("world")   // T = string
```

If you write explicit type arguments, the count must match the declaration.
For example, `identity[int, string](42)` fails with `WrongTypeArgCount`.

Generic functions use **erased** type parameters at runtime: the compiled
function body treats type-parameter-typed arguments as `any`. The type
arguments at the call site are not reified as runtime values. Concrete types
still matter at the call boundary and in instantiated return types like
`Box[int]`.

Generic type instantiations are available wherever the compiler encounters
them, even if the first occurrence sits in a branch that is not taken at
runtime:

```gengo
type Box[T] struct { val T }

func make_box[T](x T, skip bool) Box[T] {
    if skip {
        return Box[T]{ val: x }
    }
    return Box[T]{ val: x }
}
```

### Generic Constraints

Type parameters may carry built-in constraints using `:` syntax:

```gengo
func sum[T: numeric](xs []T, zero T, add func(T, T) T) T {
    total := zero
    for x in xs { total = add(total, x) }
    return total
}

func max_of[T: ordered](a T, b T) T {
    if a > b { return a }
    return b
}
```

Constraints are enforced when explicit type arguments are written. Inferred
calls (no `[T]`) skip the check. Three built-in constraints are available:

| Constraint   | Accepted types |
|:-------------|:---------------|
| `numeric`    | `int`, `float`, `decimal`, `rune`, and named subtypes of those |
| `ordered`    | Everything `numeric` accepts, plus `string` and named string subtypes |
| `comparable` | Any type (same as no constraint; useful as documentation) |

Examples:

```gengo
type Score int
type Label string

func add_two[T: numeric](a T, b T) T { return a + b }
func pick_larger[T: ordered](a T, b T) T {
    if a > b { return a }
    return b
}

std.io.println(add_two[int](3, 4))             // 7
std.io.println(add_two[Score](Score(10), Score(20))) // 30
std.io.println(pick_larger[Label](Label("a"), Label("z")))
```

An unknown constraint name such as `Hashable` is a compile-time error
(`UnexpectedToken` in the current implementation). A mismatched explicit
constraint instantiation such as `add_two[bool](true, false)` fails with
`ConstraintViolation`.

### Generic Type Aliases

A named alias gives a concrete generic instantiation a shorter name:

```gengo
type IntStack Stack[int]
type StringResult Result[string, error]
```

The alias is fully transparent: `IntStack` and `Stack[int]` refer to the
same runtime type and may be used interchangeably as field types, function
parameters, and struct literals.

```gengo
s := IntStack{ items: [1, 2, 3] }   // same as Stack[int]{ items: ... }

func peek(s IntStack) int {
    return s.items[0]
}

assert s.type == IntStack            // true — alias resolves to "Stack[int]"
```

Alias arguments must be concrete (no type parameters). Aliases of
generic types cannot be defined inside a generic body. `type BadAlias Stack[T]`
outside a generic scope fails with `UnknownType`.

## Capability Imports

Capability imports are how a script asks for access to host resources. The
host decides which capabilities to enable; a script cannot bypass that
decision. If a script imports a capability the host has not enabled,
compilation fails.

Current public capability modules:

- `cap:http` — outgoing HTTP requests
- `cap:fs` — filesystem access (restricted to host-registered mounts)
- `cap:net` — raw socket operations
- `cap:env` — read-only access to process environment variables

Each capability module exposes a well-defined API. A script that only
imports `std` and its own relative modules cannot touch the network or
disk at all, even if the host itself has those resources.

## Host Modules

Host modules let the embedding application expose custom functions to
scripts through the `host:` import prefix. Unlike capabilities, which
provide standard APIs, host modules are whatever the application decides:

```gengo
db    := import("host:db")
cache := import("host:cache")
```

The host registers each module with a name and a set of functions. A script
can call only the functions the host explicitly registered — there is no
reflection, no access to the host's internals beyond what the host chooses
to expose. This makes host modules a natural boundary for passing in
application-specific data or operations that do not fit into the capability
model.

## Errors and Runtime Behaviour

Three kinds of things can go wrong:

- **Compile errors** — the script won't run. Typing mistakes, missing
  imports, type mismatches. Caught before any code executes.
- **Runtime errors** — the script started but panicked. Division by zero,
  out-of-bounds access, a `range` or `predicate` violation. These unwind
  through `defer` frames and can be caught with `recover()`.
- **First-class `error` values** — created explicitly inside the language
  with `std.core.error(msg)`. These are ordinary values that can be checked
  and passed around, not panics.

On top of these, the host may enforce resource budgets — instruction
limits, heap size caps, maximum call depth — that stop misbehaving scripts
before they can consume too much. These limits are a normal part of
embedding, not a sign that something is broken.

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

`assert condition` panics with `AssertionFailed` if the condition is `false`. An optional message value (any type) gives a clearer failure reason:

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
