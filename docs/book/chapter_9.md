# Chapter 9: Modules and the Standard Library

In this chapter, we discuss how to organize code into reusable, manageable units. We move from single scripts to systems divided across multiple files. We also explore the Gengo standard library and how to interact with functionality provided by the host application.

## Modularity and the Battle Against Mess

As a program grows, it becomes impossible to manage if every line of code lives in a single file. **Modularity** is the practice of dividing a program into independent, self-contained units called **modules**.

Each module should have a single, well-defined responsibility. If a module handles both user validation and database connections, it is doing too much. Splitting them makes your code easier to read, test, and reuse.

## The SE Angle: Simplicity is a Feature

In many modern languages, modularity involves massive overhead: package managers, build tools, lock files, and thousands of third-party dependencies. Gengo takes a different path.

Because Gengo runs *inside* a host, its module system is intentionally simplified. There are no external packages to download; there are only the files on your disk and the modules provided by the host. This predictability is a design choice. It eliminates "supply chain attacks" and ensures that Gengo scripts remain portable, secure, and easy to audit.

## Language Form: Imports and Exports

### The Standard Library (`std`)
Everything starts with the standard library, organized into namespaces like `io`, `math`, `json`, and `time`.

```gengo
std := import("std")
std.math.abs(-5)
```

### Source Modules and `pub`
You can import other `.gengo` files using relative paths. By default, everything in a file is private. To make a function or constant visible to an importer, you must mark it with the **`pub`** keyword.

**util.gengo**:
```gengo
pub const PI := 3.14159
pub func double(n int) int { return n * 2 }
```

**main.gengo**:
```gengo
util := import("./util")
std.io.println(util.double(5))
```

### Host Modules (`module:`)
The host application can expose its own tools to your script using the `module:` prefix.

```gengo
db := import("module:database")
user := db.find_user(123)
```

## Examples

### Example 1: JSON Processing
JSON is the standard for data exchange. Gengo provides tools to parse and stringify it.

```gengo
std := import("std")

raw := '{"name": "Mikael", "active": true}'
data := std.json.parse(raw)

std.io.println("Name:", data["name"])
```

### Example 2: Time and Durations
Gengo provides a `time` module for handling timestamps.

```gengo
std := import("std")

now := std.time.now()
std.io.println("Current Timestamp:", now)
```

## Stepwise Example: A Modular Validator

**The Problem**: Keep business rules in one file and processing logic in another.
**The Engineering Take**: Separating rules from logic allows you to update your domain model without touching the code that executes it.

**rules.gengo**:
```gengo
type Age int range 0..120
pub func is_valid_age(a int) bool {
    return a >= 18 && a <= 120
}
```

**main.gengo**:
```gengo
std := import("std")
rules := import("./rules")

users := [ { "name": "Alice", "age": 25 }, { "name": "Bob", "age": 15 } ]

for u in users {
    if rules.is_valid_age(u["age"]) {
        std.io.println(u["name"], "is valid.")
    }
}
```

## Pitfalls

### The Missing `pub`
If you forget to mark a declaration as `pub`, it remains invisible to other files. Gengo will report a compile-time error if you attempt to access it.

### Circular Imports
If Module A imports Module B, and Module B imports Module A, you have created a circular dependency. Gengo does not allow this. Keep your module structure as a clean hierarchy (a tree), not a spiderweb.

---

### Summary

- **Modularity**: Your primary weapon against complexity.
- **`std`**: The built-in toolkit for common tasks.
- **`pub`**: The gatekeeper for module visibility.
- **Host Modules**: How your script interacts with the larger application.

---

### Exercises

1. Create a `math_util.gengo` module with geometry functions. Import and use them in a main script.
2. Explore the `std.string` module and write a script that converts a list of names to all-caps.
3. Why is a simple, file-based module system more secure than a global package manager for an embeddable language?
