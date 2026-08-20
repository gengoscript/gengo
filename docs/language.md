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
- source imports, either relative (`./math`) or registered package names
  (`acme/math`).

Source import resolution is deterministic. The engine tries the exact path,
then the path plus `.gengo`, then the path plus `/mod.gengo`. Extensions are
therefore optional in source code. A resolved source path identifies one
module for a compilation: importing that same resolved path more than once
does not compile a second independent module.

```gengo
local_math := import("./math")       // ./math.gengo or ./math/mod.gengo
pkg_math   := import("acme/math")    // registered acme/math.gengo or acme/math/mod.gengo
```

Bare source imports resolve only through registered source tables, source
providers, or package roots. They do not grant host access. `host:*` remains
the explicit namespace for host-registered modules, while `cap:*` remains the
explicit, policy-gated namespace for capabilities.

Built-ins are accessed through namespaces such as `std.io.println(...)` and `std.core.len(...)`. Legacy global forms such as `println(...)` are not supported.

### Exporting from Modules

A source module can export constants, functions, and types with `pub`:

```gengo
// geometry/shapes.gengo
pub const version := "v1"
pub func origin() Point { return Point{ x: 0, y: 0 } }
pub type Point struct { x int, y int }
pub type Distance int
```

`pub` is valid only at a module's top level. It applies to `const`, `func`,
`type`, and `subtype`; `pub var` and `pub name := value` are not supported.
An imported module exposes only its `pub` declarations. Its private helpers
remain usable by code in that module, but access such as `geometry.helper()`
is a compile error.

### Dependency Order and Cycles

Before compiling a source module, the compiler discovers and compiles its
source dependencies. This lets a module refer to the exported declarations of
an imported module regardless of where the `import(...)` expression appears
in the source file.

Source-import cycles are rejected at compile time with `ImportCycle`. For
example, if `a.gengo` imports `b.gengo` and `b.gengo` imports `a.gengo`, the
program does not run. Restructure shared declarations into a third module.

The compiler currently establishes dependency compilation order, but the
language does not yet promise a separate cross-module order for observable
top-level initialization. Keep module initialization independent of ordering;
put order-sensitive work behind an exported function called by the root
script. This is a documented limitation, not an invitation to rely on the
current bytecode layout.

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

- `int`, `float`, `bigint`, `bool`, `string`, `rune`, `null`, `error`

Fixed-point decimals are currently declared through named decimal types such
as `type Money decimal 2`. Although decimal values have a runtime type name,
the current compiler does not accept `decimal` as a standalone variable type;
see `known-limitations.md`.

Collection types hold multiple values:

- arrays, maps, structs, tuples

Tuple values exist, but they are a narrow surface today: scripts mainly see
them when a multi-value return is captured into a single variable rather than
destructured. There is no separate tuple literal or tuple type declaration
syntax documented for general use.

Functions are values too — they can be passed around, assigned, and closed
over.

### Evaluation Order

Gengoscript evaluates expression operands from left to right. This applies to
binary operators, function-call arguments, array elements, and each map key
followed by its corresponding value. A call evaluates its callee before its
arguments. `&&`, `||`, and `??` are the exceptions: their right operand is
evaluated only when needed.

For an indexed assignment such as `target[index] = value`, the target and
index are evaluated before `value`; the write happens after all three have
been evaluated. In a multi-assignment, the complete right-hand side is
evaluated before any target is assigned.

Do not rely on a particular map iteration order or mutate a map while
iterating it; neither behaviour is specified yet.

### Copying, Aliasing, and Mutation

Assignments of scalar values copy the value. Strings are immutable. Arrays,
maps, and array slices are reference-backed: assigning one to another aliases
the same mutable collection, and an index or map write through either name is
visible through the other. Array slicing also aliases the source array.

```gengo
std := import("std")

items := [1]
other_items := items
other_items[0] = 3
std.io.println(items[0]) // 3

scores := {"Ada": 1}
other_scores := scores
other_scores["Ada"] = 9
std.io.println(scores["Ada"]) // 9

prefix := items[0:1]
prefix[0] = 7
std.io.println(items[0]) // 7
```

Struct assignment and value receivers copy the struct's direct fields. A
field that itself holds an array, map, closure, or other reference-backed
value still refers to the same underlying value after that copy. Function
arguments follow the same rule. Closures capture enclosing variables by
reference, so a closure observes a later assignment to a captured variable.

Use `std.core.clone` when an independent, deep copy is required. It is the
explicit copying operation; ordinary collection assignment is not a clone.

Strings are UTF-8. `std.core.len(s)` counts Unicode code points, while
`std.core.bytelen(s)` counts bytes.

### Strings, Runes, and Bytes

String indexing, slicing, and `for`-in iteration use rune (Unicode code
point) positions, not byte offsets. An indexed string expression returns a
single-rune string, not a `rune` numeric value. Bounds are zero-based and a
bad index or slice boundary raises `IndexOutOfBounds`.

```gengo
std := import("std")
s := "åäö"

std.io.println(std.core.len(s))     // 3 runes
std.io.println(std.core.bytelen(s)) // 6 UTF-8 bytes
std.io.println(s[1])                // ä
std.io.println(s[1:3])              // äö

for i, ch in s {
    // i is a rune index; ch is a one-rune string.
    std.io.println(i, ch)
}
```

Rune literals use backticks, for example `` `å` ``. A typed declaration can
convert an integer Unicode code point to `rune`; converting that rune to
`string` produces its UTF-8 encoding:

```gengo
var letter rune = 229
text := string(letter) // "å"
```

There is no supported callable `rune(...)` conversion at present, and a
string does not implicitly convert to a rune. Use indexing when the string is
known to contain at least one rune, or keep the text as a string.

The language string operations validate UTF-8 when they need rune boundaries:
`len`, indexing, slicing, and iteration raise `TypeError` for malformed
UTF-8. Binary strings created by `std.bytes` may contain arbitrary bytes; use
only `std.bytes` operations with those values unless the bytes are known to
be valid UTF-8. `std.bytes` positions and lengths are always byte offsets.

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

### Named Scalar Execution Model

Named scalar types are nominal at the language level, but `int`, `float`,
`bool`, and `rune` named values are represented by their base value at runtime.
For example, `Meters(5)` is a bare runtime integer, not an allocating wrapper.
The compiler retains the `Meters` identity while compiling the expression and
uses it to reject invalid mixing, select statically known methods, and emit
validation after an operation that produces another `Meters` value — all
without ever unwrapping to a boxed representation.

Constraints are therefore explicit bytecode at the point where a result is
created: range and cycle normalization use `validate_named_range`; predicates
use `check_named_predicate`. This keeps language-level nominal typing intact
without making ordinary scalar arithmetic rediscover type identity in the VM.

This applies to values flowing through locals, fields, function returns,
typed arrays/maps, static method calls, unary and bitwise operations, shifts,
and supported `std.math` intrinsics. A shift count is an `int`-based value
(plain or named); the left operand determines the named result type.

`decimal`, `string`, named arrays/maps, native values, and dynamically typed
boundaries may still carry runtime named objects because their behaviour needs
runtime identity or extra representation data. Dynamically typed scalar
values report their base runtime type; when the compiler knows an expression's
named scalar type, `.type` and `std.core.type_of(...)` emit that declared name
as a compile-time string constant.

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

### Zero Values

An initializer may be omitted only from a mutable `var` declaration. The
implemented zero values are:

| Declared type | Value without an initializer |
|---|---|
| `int`, `float`, `bigint` | `0` |
| `bool` | `false` |
| `string` | `""` |
| `rune` | code point `0` |
| `[]T`, `[K]V`, named array/map types | a non-null empty collection |
| `?T`, `error`, interface type, function type | `null` |
| struct type | a struct whose fields have their own zero values |
| enum type | its first declared member |
| named scalar | its declared `default`, otherwise its base zero value, subject to its constraints |

A constrained named scalar may therefore have no usable implicit zero. For
example, `type Id int range 1..100; var id Id` is rejected because `0` is
outside the declared range. Supply an initializer or declare a valid
`default`. Variant types are not currently accepted as a `var` declaration
type, so they have no documented implicit zero value.

Assignment uses `=`. Compound assignment forms (`+=`, `-=`, `*=`, `/=`) are
supported for numeric types.

### Scope and Name Resolution

A module-level declaration belongs to that source module. A block introduces
a nested local scope; function parameters, named returns, `:=` bindings, and
loop bindings are local to the function or block that declares them. A local
binding may shadow an outer local or module-level name. Once the nested scope
ends, the outer binding is visible again.

Within one local scope, declaring the same binding name twice is a compile
error. A local binding is visible only after its declaration. Named functions
are different: their declarations are collected before function bodies are
compiled, so functions can call later-declared functions and can be
recursive. The conformance suite covers this forward-reference rule.

Avoid depending on forward references between module-level mutable values.
The compiler has a pre-scan for global declarations, but initialization is
still emitted in source order; write a declaration before code that needs its
value.

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

### Operator Precedence

The following table is in descending precedence. Operators on the same row are
left-associative unless the table says otherwise. `=` and compound assignments
are statements, not expression operators.

| Operators | Associativity |
|---|---|
| calls `()`, indexing/slicing `[]`, field and method access `.` | left |
| unary `-`, `~`, `not` | right (prefix) |
| `**` | right |
| `*`, `/`, `div`, `rem`, `mod` | left |
| `+`, `-` | left |
| `<<`, `>>` | left |
| `&` | left |
| `^` | left |
| `\|` | left |
| `<`, `<=`, `>`, `>=` | left |
| `==`, `!=` | left |
| `and` | left, short-circuiting |
| `or` | left, short-circuiting |
| `??` | right, short-circuiting |

The symbolic forms `&&` and `||` are not supported; use `and` and `or`. This
follows the same keyword-operator convention as `div`/`rem`/`mod` above,
extended to boolean logic and negation (`not`) for one concrete reason:
`&`/`|`/`^`/`~` already have separate, real meanings as *bitwise* operators
on `int`. Making `&&`/`||` mean boolean AND/OR while single `&`/`|` mean
bitwise AND/OR is the exact C-family trap where a doubled-vs-single symbol
is the only signal separating "wrong type entirely" from "silently wrong
answer" — a single dropped character changes behavior instead of failing to
compile. Word operators for boolean logic remove that adjacent-symbol
hazard entirely; bitwise operators keep their symbols since there's no
boolean-vs-bitwise collision to avoid on `&`/`|`/`^`/`~` alone.
Parenthesize expressions when a reader could reasonably mistake the grouping.

## Lexical Structure

Source text is UTF-8. An identifier starts with a Unicode letter or `_` and
continues with Unicode letters, Unicode decimal digits, or `_`. Identifiers
are case-sensitive and are not normalized: two spellings that differ in their
UTF-8 bytes are different names even if they look alike.

The reserved keywords are:

```text
and as assert break case const continue defer div else enum false for func
if import in interface mod not null or pub rem return struct subtype switch
test trap true type var variant when
```

`range`, `cycle`, `clamp`, `default`, `predicate`, and `message` are contextual
keywords. They have their special meaning only in a type declaration or
`switch` clause and can otherwise be used as ordinary identifiers. All other
keywords above are reserved everywhere.

Whitespace separates tokens. `//` starts a line comment and `/* ... */`
starts a block comment; block comments may span lines. An unterminated block
comment consumes the rest of the file rather than producing a separate lexical
error. A `#!` line is ignored only when it is the first two bytes of a source
file, allowing a script shebang.

Malformed UTF-8 where the lexer expects an identifier is an `InvalidChar`
compile error. Strings are byte sequences: a double-quoted `\xHH` escape can
intentionally create bytes that are not valid UTF-8. Rune-aware string
operations then reject those bytes as described in [Strings, Runes, and
Bytes](#strings-runes-and-bytes).

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

Double-quoted strings process these escapes: `\n`, `\r`, `\t`, `\\`, `\"`,
`\'`, `\xHH` (one byte), `\uHHHH` (one Unicode code point), and `\UHHHHHHHH`
(one Unicode code point). `\u` and `\U` are encoded as UTF-8. An unknown
one-character escape drops the backslash and keeps that character; do not use
unknown escapes as a portability mechanism. A double-quoted string cannot
contain an unescaped newline.

Single-quoted strings are raw byte strings. Backslashes are ordinary bytes,
and the quote character ends the string; use a double-quoted string when an
embedded quote or escape is required. Single-quoted strings also cannot span a
newline.

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

A rune literal must contain exactly one Unicode code point. It has no escape
syntax: write the code point itself, or construct a `rune` from an integer in a
typed declaration when appropriate.

Integer literals can be written in decimal, hexadecimal, binary, or octal.
Digit separators (`_`) are allowed in all bases:

```gengo
x := 255
x := 0xFF
x := 0b1111_1111
x := 0o377
```

Floating-point literals support scientific notation. Numeric separators are
accepted in the integral and fractional decimal parts, but not in the
exponent:

```gengo
f := 1.5e2    // 150.0
f := 2.5e-1   // 0.25
```

The lexer has one numeric-literal token. Whether an unsuffixed numeric literal
is accepted as an `int`, `float`, or a named decimal value is decided by the
surrounding type rule; there is no separate decimal literal suffix. A numeric
literal that overflows or does not match its required type is a compile error.

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

An array literal can also be prefixed with an explicit element type — Go-
style composite-literal syntax — equivalent to (and desugars to exactly the
same construction as) `var xs []Type = [elem, ...]`:

```gengo
xs := []int{1, 2, 3}
pts := []Point{Point{x: 1, y: 2}, Point{x: 3, y: 4}}
empty := []int{}
```

Maps:

```gengo
user := {"name": "Ada", "active": true}
std.io.println(user.name)
```

Map keys are expressions: quote string keys (`"name"`), or use a variable
to key dynamically (`{k: 1}` uses the *value* of `k`). A bare identifier
in key position is a variable reference, not a string.

Map lookup never raises an error for an absent key: `m[key]` evaluates to
`null`. Use `std.core.has(m, key)` when `null` is also a meaningful stored
value. `std.core.delete(m, key)` removes a key and returns its former value,
or `null` when absent.

Map key acceptance is currently runtime-defined rather than restricted by a
separate language-level “comparable key” rule. Primitive and enum keys are
supported; do not use mutable arrays, maps, structs, closures, or other
composite values as portable map keys. Typed maps still check their declared
key and value types when values cross a typed boundary.

Arrays use zero-based, non-negative integer indices. Reading or writing an
index outside `0 .. len-1` is a runtime `IndexOutOfBounds` panic. A slice
allows an end index equal to `len`, but both bounds must be non-negative and
the start must not exceed the end. `std.core.append` returns an array value;
assign its result when growing an array.

Iteration visits the collection representation currently held when the loop
starts. Map entry order is deliberately unspecified and can change when keys
are inserted or deleted. Do not mutate a map’s membership during `for`-in;
the current iterator retains an internal entry slice and the resulting
behaviour is not a language guarantee.

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

`else if` chains are limited to 256 levels. Beyond that the compiler returns
`NestingTooDeep`. Refactor very deep chains into a `switch` or a helper
function.

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

### Function Declarations Are Immutable

`func name(...)` declares an immutable binding, as in Go — assigning to the
name afterwards is a compile error:

```gengo
func fib(n int) int {
    if n < 2 { return n }
    return fib(n - 1) + fib(n - 2)
}

// fib = 5   // compile error: cannot assign to function 'fib';
//           // func declarations are immutable
```

For a reassignable function-valued binding, use the variable form:

```gengo
handler := func(x int) int { return x }
handler = func(x int) int { return x * 2 }   // ok — := is a mutable binding
```

Immutability is what makes the compile-time call checking below sound: call
sites are validated against the declared signature, which the binding can
never change out from under them. It also makes declared functions the
faster form — the runtime skips per-call argument and return type checks
that the compiler already proved.

### Compile-Time Type Checking

When both sides of a type judgement are visible to the compiler, mismatches
are compile errors instead of runtime errors:

```gengo
func f(x int) int { return x }

// f("hi")       // compile error: cannot pass string to parameter of
//               // type int; convert explicitly

func g() int {
    // return "oops"   // compile error: cannot return string from
    //                 // function returning int; convert explicitly
    return 1
}
```

This applies to direct calls of declared functions — including recursive
calls inside the function's own body — and to `return` statements in
functions with a single primitive return type. Values the compiler cannot
type statically (an `any` value, a map lookup, a call through a mutable
`:=` binding) are still checked at runtime exactly as before; the compiler
only rejects earlier what would have failed later.

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
parameters after the first defaulted one must also have defaults. Integer
defaults are parsed exactly as `i64` values; there is no intermediate `f64`
conversion, so integer defaults larger than 2^53 are represented precisely.

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

Functions, constants, and types may be exported from a source module with
`pub`. Closures capture variables from the enclosing scope by reference.

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

### Operator Overloading

A struct type (or a named type over a base that doesn't already have the
operator built in — see below) can overload an operator by declaring a
method with one of eight reserved names. No new keyword — these are ordinary
method declarations:

```gengo
type Vec2 struct { x float, y float }

func (a Vec2) __add__(b Vec2) Vec2 {
    return Vec2 { x: a.x + b.x, y: a.y + b.y }
}

func (v Vec2) __neg__() Vec2 {
    return Vec2 { x: -v.x, y: -v.y }
}

a := Vec2 { x: 1.0, y: 2.0 }
b := Vec2 { x: 3.0, y: 4.0 }
c := a + b     // compiles to a.__add__(b)
d := -a        // compiles to a.__neg__()
```

| Operator | Method |
|---|---|
| `+` | `__add__(other T) T` |
| `-` (binary) | `__sub__(other T) T` |
| `*` | `__mul__(other T) T` |
| `/` | `__div__(other T) T` |
| `rem` | `__rem__(other T) T` |
| `-` (unary) | `__neg__() T` |
| `==` (and `!=`) | `__eq__(other T) bool` |
| `< > <= >=` | `__compare__(other T) int` |

These reserved names are the one deliberately non-Go-shaped corner of the
syntax — Go has no operator overloading to model this on. Gengo doesn't
gate them behind an `operator` modifier keyword the way Kotlin does: there's
no separate `impl`/trait-block boundary here (a method is always declared
right alongside its receiver type, unlike Rust's `impl Trait for Type`
elsewhere), so there's no coherence problem a keyword would need to guard
against, and the eight names are distinctive enough that nobody collides
with them by accident the way a bare `add`/`eq` method name might. Reserved
double-underscore names, not a keyword, are simply the smaller mechanism
that already covers the actual risk.

`__compare__` backs all four ordering operators at once — return a negative
number, zero, or a positive number the way `strcmp`-style comparisons do,
and `<`/`>`/`<=`/`>=` are derived by comparing that result against `0`.
`!=` is derived from `__eq__` the same way.

The parameter type must be exactly the receiver's own type — there is no
asymmetric-operand form (`Vec2 + float`, say). Gengo has no method
overloading anywhere, so allowing one would require exactly the overloading
the language doesn't have.

A named type may declare a dunder too, but only for an operator its base
doesn't already implement — `type Meters int` already has working `+`, so
`func (a Meters) __add__(b Meters) Meters {...}` is a compile error. Some
bases have partial gaps worth knowing about: `decimal` has no working
`rem` or ordering (`< > <= >=`) today, so `__rem__`/`__compare__` are open
on a decimal-based named type even though `__add__`/`__eq__` are not; a
struct's default `==` is reference identity (two separately-built literals
with the same fields are not `==` unless a method's receiver is the same
value), so `__eq__` is always open on a struct — declaring it upgrades `==`
to real structural comparison.

A type whose `__compare__`/`__eq__` is declared also satisfies the
`ordered`/`comparable` generic constraints (see Generic Types), so it can be
passed to a `[T ordered]`-constrained function. This works both when the
compiler can see the concrete type directly, and inside the generic
function's own body operating on the type parameter — the latter is
resolved at runtime rather than compile time, since the type is erased
until the call is actually made.

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

`std.core.recover()` catches a panic from inside a `defer` function and stops
the unwind. It returns the original panic payload, which can be an `error` or
another value, or `null` if no panic is in progress.

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

`recover()` only has effect during an active panic that's currently unwinding through a `defer` call — directly inside the deferred function itself, or in any plain function it calls. Calling it with no panic in progress, or after the panic has already been recovered, returns `null`.

### Trap Results

`trap` is a special name permitted in a multi-value declaration. Its value is
checked after assignment: `null` continues normally, while any non-null value
starts a panic unwind with that value as the payload. This makes functions
that return `(value, ?error)` convenient to use with `defer`/`recover`:

```gengo
std := import("std")

func divide(a float, b float) (float, ?error) {
    if b == 0.0 { return 0.0, std.core.error("division by zero") }
    return a / b, null
}

func report() {
    defer func() {
        payload := std.core.recover()
        if payload != null { std.io.println("failed:", payload) }
    }()

    answer, trap := divide(10.0, 0.0)
    std.io.println(answer) // unreachable when trap is non-null
}
```

`trap` is only valid as one target in a `:=` multi-value declaration; it is
not an ordinary variable and cannot be assigned later. A non-error payload is
legal, so callers must not assume `std.core.is_error(recover())` is always
true.

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

The clause words `range`, `cycle`, `clamp`, `default`, `predicate`, and `message`
are contextual: they act as keywords only in their clause positions inside
a `type` or `subtype` declaration (and `default` in `switch` bodies), and
are ordinary identifiers everywhere else:

```gengo
type Port int range 1..65535 default 8080

range := 10          // fine — 'range' is just a name here
message := "hello"   // fine
```

Only `type` and `subtype` themselves are reserved words of this family.
Because the language is newline-insensitive, a statement that *begins* with
a clause word directly after a type declaration is disambiguated by what
follows the word (an assignment or access operator means it is an
identifier). The rare unresolvable forms — such as a bare call statement
`range(...)` on the line directly after a type declaration — are rejected
with a parse error rather than silently reinterpreted; reorder the
statements to resolve.

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
object. Range types step by one and raise a runtime range error if the result
would fall outside the declared domain; cycle types step by one and wrap;
clamp types step by one and saturate at the nearest bound instead of erroring:

```gengo
type Step int range 1..100
type Hour int cycle 0..23
type Bounded int clamp 1..100

std.io.println(Step.succ(Step(50)))      // 51
std.io.println(Step.pred(Step(50)))      // 49
// Step.succ(Step(100))                  // runtime range error — 101 is out of bounds
std.io.println(Hour.succ(Hour(23)))      // 0
std.io.println(Hour.pred(Hour(0)))       // 23
std.io.println(Bounded.succ(Bounded(100)))  // 100 — saturates instead of erroring
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

`clamp` is a third domain mode: instead of raising a range error or wrapping,
an out-of-bounds value saturates to the nearest bound. It works on any
numeric base — `int`, `float`, `decimal`, or `rune` — and is inherited by
subtypes the same way `range`/`cycle` are:

```gengo
type Percent int clamp 0..100

std.io.println(Percent(150))   // 100
std.io.println(Percent(-10))   // 0
std.io.println(Percent(50))    // 50
```

Clamping only affects the `min..max` bound; a `predicate` on the same type
still runs afterward, checking the clamped result rather than the original
value. A `default` value is still validated strictly against the range at
compile time — `clamp` does not relax that check:

```gengo
type EvenPercent int clamp 0..100 predicate func(x) { return x rem 2 == 0 }

std.io.println(EvenPercent(200))   // 100 — clamps to 100, which is even
// EvenPercent(99)                 // predicate failure — 99 is in range, not clamped, and odd
```

Subtypes allow narrower domains inside an existing named type or enum. The
parent must itself be a named scalar type or an enum declared with `type`
(or another `subtype` of one — subtyping chains); `range`/`cycle`
constraints additionally require a numeric parent. A struct, interface,
variant, or generic type cannot be a subtype parent — there is no notion of
narrowing one of those — and naming one is a compile error rather than
being silently accepted:

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

### Constructing Variant Values

A no-payload arm is a bare value; a record arm (`{ ... }`-declared, zero or
more named fields) is always constructed with a brace literal, the same way
a struct is:

```gengo
p := Event.Ping                            // no-payload arm
e := Event.Metric{ name: "req", value: 1 } // record arm — brace literal only
```

A single-payload arm — the `ok(value int)` shape above — accepts **either**
spelling: a positional call, or a brace literal naming the field:

```gengo
r := Result.ok(42)
r := Result.ok{ value: 42 }   // equivalent
```

Both forms compile to the same construction and are fully interchangeable;
neither is deprecated. Prefer the call form for a quick single value and the
brace form when the field name adds clarity, or when constructing a generic
variant, where the brace form is more common in this codebase's own examples
(see [Generic Types](#generic-types)) — but either works on either kind of
variant. This does not extend to record arms: `Event.Metric(1)` is not
accepted (`ArityMismatch`) because a record arm's construction is always
name-directed, never positional.

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

A variant `switch` is **exhaustive**: every arm must be covered by at least
one unguarded case, or the switch must have a `default`. A missing arm is a
compile error (`NonExhaustiveSwitch`) at both top level and inside functions.

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

Type parameters may also carry optional constraints using the same syntax
described below for generic functions.

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

Type parameters may carry built-in constraints, written as a second
identifier directly after the type parameter name — space syntax, the same
convention as every other type annotation in the language (`x int`, a
struct field, a function parameter):

```gengo
func sum[T numeric](xs []T, zero T, add func(T, T) T) T {
    total := zero
    for x in xs { total = add(total, x) }
    return total
}

func max_of[T ordered](a T, b T) T {
    if a > b { return a }
    return b
}
```

> **Known limitation — inferred constraints are not checked.** Constraints are
> enforced when explicit type arguments are written. Inferred calls (no
> `[T]`) skip the check, even when inference determines a type that does not
> satisfy the declared constraint. This is an implementation limitation, not
> a guarantee. Write explicit type arguments when constraint enforcement is
> required.

For example, the inferred call below currently succeeds, whereas
`identity_numeric[bool](true)` fails with `ConstraintViolation`:

```gengo
func identity_numeric[T numeric](x T) T { return x }

ok := identity_numeric(true) // currently accepted; bool is not numeric
```

Three built-in constraints are available:

| Constraint   | Accepted types |
|:-------------|:---------------|
| `numeric`    | `int`, `float`, `decimal`, `rune`, and named subtypes of those |
| `ordered`    | Everything `numeric` accepts, plus `string` and named string subtypes, plus any type declaring `__compare__` (see Operator Overloading) |
| `comparable` | Any type (same as no constraint; useful as documentation) |

Examples:

```gengo
type Score int
type Label string

func add_two[T numeric](a T, b T) T { return a + b }
func pick_larger[T ordered](a T, b T) T {
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
  through `defer` frames and can be caught when `recover()` is called by a
  deferred function.
- **First-class `error` values** — created explicitly inside the language
  with `std.core.error(msg)`. These are ordinary values that can be checked
  and passed around, not panics.

On top of these, the host may enforce resource budgets. Exceeding an
instruction limit raises the recoverable runtime panic
`InstructionBudgetExceeded`; allocation exhaustion and configured stack/frame
limits also stop execution. A VM operation budget does not measure work done
inside a host callback, filesystem driver, or network handler. These limits
are a normal part of embedding, not a sign that something is broken.

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
