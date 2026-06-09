# Chapter 11: The Host Environment and Capabilities

In this chapter, we explore how Gengo scripts interact with the world. We discuss the **capability system**: Gengo’s mechanism for granting access to files, network connections, and system resources. This design ensures scripts remain safe and predictable, even when performing powerful real-world work.

## The Principle of Least Privilege

In most languages, a program has "ambient access" to your computer. A Python script can read your files, open your webcam, or delete your data (assuming your account has permission). In software engineering, this is a massive security risk. Gengo follows the **Principle of Least Privilege**: a script starts with zero access. It cannot see your files, talk to the internet, or even see the system clock unless the host explicitly grants permission.

## The SE Angle: Security as Architecture

Security is not a feature you add later with a firewall; it must be built into the architecture. Gengo’s capability system is a primary example of this. We do not rely on complex OS permissions; we build security into the language's module system. You cannot "accidentally" leak data to the internet if your script lacks the `cap:http` capability. This allows a host to run untrusted logic—such as a customer's custom pricing script—with total confidence that it cannot hijack the server.

## Language Form: Importing Capabilities

A **capability** is an opt-in integration accessed with the `cap:` prefix.

### Enabling Capabilities
When running via the Gengo CLI, you must explicitly enable each capability using the `--cap` flag:

```bash
gengo --cap fs --cap http script.gengo
```

If a script attempts to `import("cap:fs")` without the flag, it fails with a `CapabilityNotAvailable` error.

### Common Capabilities
*   **`cap:fs` (Filesystem)**: Read-only access to files.
*   **`cap:http` (HTTP Client)**: Allows making web requests.
*   **`cap:net` (Network)**: Low-level socket access for custom protocols.

## Examples

### Example 1: Loading Configuration
Using `cap:fs` to read a local JSON file.

```gengo
std := import("std")
fs  := import("cap:fs")

const PATH := "./settings.json"

if fs.exists(PATH) {
    raw := fs.read(PATH)
    config := std.json.parse(raw)
    std.io.println("User:", config["user"])
}
```

### Example 2: Web Requests
Using `cap:http` to fetch external data.

```gengo
std  := import("std")
http := import("cap:http")

resp := http.get("https://api.example.com/status")
if resp.ok {
    std.io.println("Status:", resp.body)
}
```

## Stepwise Example: Remote Policy Checker

**The Problem**: Check if a user is authorized by consulting a local blacklist and a remote service.
**The Engineering Take**: This script requires `fs` and `http`. If either fails (missing file or network down), we must default to a "denied" state for safety.

```gengo
std  := import("std")
fs   := import("cap:fs")
http := import("cap:http")

func is_authorized(user_id string) bool {
    // 1. Local Check
    if fs.exists("blacklist.txt") {
        list := fs.read("blacklist.txt")
        if std.string.contains(list, user_id) { return false }
    }
    
    // 2. Remote Check
    url := "https://auth.internal/check?id=" + user_id
    resp := http.get(url)
    
    if resp.ok {
        data := std.json.parse(resp.body)
        return data["allowed"] == true
    }
    
    return false // Default to false on any failure
}

if is_authorized("u-123") {
    std.io.println("Access Granted.")
}
```

## Pitfalls

### The Forgotten Flag
You will inevitably spend time wondering why a script fails, only to realize you forgot the `--cap` flag. The error message will tell you exactly what is missing.

### Jailbreak Attempts
Gengo respects boundaries. Even with `cap:fs`, you cannot read any file on the system; the host typically restricts the script to a specific directory. Path climbing (e.g., `../../etc/passwd`) will be blocked by the host.

### Blocking the Host
Gengo is a scripting engine; the host usually waits for your script to finish. If you make a very slow network request, you might "hang" the host application. Be mindful of resource usage when using system capabilities.

---

### Summary

- **Sandbox by Design**: Scripts start with zero access.
- **Explicit Grant**: Capabilities must be enabled by the host or CLI.
- **Least Privilege**: Only import what is absolutely necessary.
- **Security is Architecture**: Isolation is a fundamental feature of the engine.

---

### Exercises

1. Write a script that reads a list of filenames from `files.txt` and prints the size of each file (refer to the documentation for `cap:fs`).
2. What happens if you try to `import("cap:http")` and run Gengo without the flag? Observe the error.
3. Why does Gengo restrict filesystem access to read-only? What risks would "write" access introduce for an embedded engine?
