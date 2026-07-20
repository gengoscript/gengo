# Gengoscript Documentation

Gengoscript is a small embeddable scripting language. Start with
`project-status.md` for compatibility and release status.

## Start here

1. `quickstart.md` — build from zero and run a first script.
2. `tutorial-first-script.md` — learn the language through a guided example.
3. `project-status.md` — version identity, compatibility, and source authority.
4. `cli.md` — CLI flags, REPL, diagnostics, and exit status.

## Language and library

- `language.md` — guide and current language reference.
- `stdlib.md` — `std` namespaces.
- `capabilities.md` — capability-module imports and operations.
- `capability-matrix.md` — external authority and availability by host.

## Host integration and security

- `embedding.md` — Zig runtime embedding.
- `engine-api.md` — C-compatible native and WASM engine API.
- `host-abi.md` — ValueWire ABI, ownership, and known decimal limitation.
- `typescript-sdk.md` — browser and Node.js SDK.
- `security.md` — threat model and deployment controls.
- `known-limitations.md` — current implementation and compatibility limits.
- `error-catalogue.md` — compile errors, runtime panics, and diagnostics.
- `changelog.md` — released and pending changes.

The passing conformance suite is the primary semantic authority. Documentation
does not override it when a discrepancy is recorded.

Contributor and project-internal material — the documentation audit trail,
open engine items, and architecture references — lives outside this public
set, in `../dev-docs/index.md`.
