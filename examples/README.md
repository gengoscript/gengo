# Examples

Each example embeds Gengoscript into a different host language or system, to
show what a real integration looks like rather than a toy snippet. Most
follow the same shape: the host loads a script into an isolated engine
instance, calls into it with typed arguments, and treats compile errors,
runtime panics, and runaway scripts as host-recoverable failures, not crashes.

| Example | Host | Demonstrates |
|---|---|---|
| [`firmware-gate-c`](firmware-gate-c) | C | Policy/rollout rules over fixed scalar args; `range`/`predicate` named types; `defer`/`recover` turning a constraint violation into a soft deny |
| [`sqlite-policy`](sqlite-policy) | C (SQLite extension) | Validation enforced at the database layer via `BEFORE INSERT`/`BEFORE UPDATE` triggers |
| [`mosquitto-acl`](mosquitto-acl) | C (Mosquitto plugin) | ACL/auth decisions for an MQTT broker; fail-closed on error; live policy reload via SIGHUP |
| [`json-schema-validation`](json-schema-validation) | Node.js | An alternative to declarative schema validators — parses an arbitrary JSON document and reports every field violation, not just the first |
| [`order-normalizer`](order-normalizer) | Node.js | Multi-tenant ingestion: one script per merchant, host-owned lookups via a registered module, per-tenant isolation and instruction budgets |
| [`release-gate`](release-gate) | Node.js | A deployment policy gate; the script calls back into the host through a registered `pipeline` module |
| [`billing-plugins`](billing-plugins) | Python | Per-merchant discount logic, each in its own isolated engine instance |
| [`embed-host`](embed-host) | Zig | Embedding via the native `api.Runtime` surface directly, no C ABI boundary |

## Picking an example to start from

- **Host language**: each example only depends on the engine surface for its
  language — WASM + a small wrapper for JS, the C ABI for C, the native Zig
  API for Zig, ctypes for Python.
- **Validation/constraint logic** (a policy, a permission check, a request
  validator): start from `firmware-gate-c` or `json-schema-validation` —
  named-type `range`/`predicate` constraints plus `defer`/`recover` is the
  core pattern in both.
- **Per-tenant or per-script isolation** (many independently-authored
  scripts, each untrusted relative to the others): start from
  `order-normalizer` or `billing-plugins`.
- **Host-to-script callbacks** (the script needs to call back into host
  logic, not just receive arguments and return a value): start from
  `release-gate` or `order-normalizer`'s `host:catalog` module.

## Building

Most examples need a build artifact first:

```bash
zig build -Dpreset=dev engine-build   # WASM engine, for JS hosts
zig build -Dpreset=dev engine-native  # shared library, for C/Python hosts
```

`embed-host` builds directly against the Zig package and needs neither.

See each example's own README (where present) for exact run instructions.
