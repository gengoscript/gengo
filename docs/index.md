# Gengoscript Docs

Gengoscript is a small embeddable scripting language for host applications that need user-defined logic without giving scripts ambient access to the machine.

The public documentation is split by task:

1. Start with `quickstart.md` if you want to build the project and run a script.
2. Read `tutorial-first-script.md` for a short guided example.
3. Use `language.md` and `stdlib.md` as the main language references.
4. Use `embedding.md`, `engine-api.md`, and `host-abi.md` when integrating Gengoscript into a host.
5. Read `security.md` before embedding untrusted scripts in production.

For repository readers, `language.md` and `stdlib.md` are the main
human-readable references, while `../tests/spec/` is the executable
conformance suite that pins down edge-case behaviour.

This directory is the source set for `docs.gengoscript.org`.

Project-internal material lives outside the public docs:

- `../dev-docs/index.md`
- `../archive/README.md`
