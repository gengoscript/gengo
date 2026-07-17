# Module Bundles

A module bundle is a zip file containing `.gengo` source files that an
embedding host registers under a name.  Scripts import from it with plain
`import("name/path")` paths — no special prefix is required and no other
engine configuration is needed.

Bundles are the recommended way to ship a multi-file Gengoscript library as
part of a compiled host binary or alongside a deployed application.

---

## What a bundle is

At runtime a bundle is a named collection of source modules.  Internally the
engine stores up to 64 files per bundle.  The physical format is either:

- a standard ZIP file (`engine_load_bundle`) — use this in production
- a directory on the host filesystem (`engine_load_bundle_dir`) — use this
  during development so changes take effect without rebuilding a zip

Both produce identical import paths in Gengoscript; no script changes are
needed when switching between the two.

---

## Authoring a library

Organise source files in a directory tree.  The tree's root becomes the bundle
root; the relative paths of the files become the module paths within the bundle.

```
lib/mylib/
├── utils.gengo       → importable as mylib/utils
└── net/
    ├── http.gengo    → importable as mylib/net/http
    └── url.gengo     → importable as mylib/net/url
```

Modules within the bundle can import each other with relative paths:

```gengo
// inside net/http.gengo
url := import("./url")        // resolves to mylib/net/url
util := import("../utils")    // resolves to mylib/utils
```

An entry script outside the bundle uses absolute bundle paths:

```gengo
http := import("mylib/net/http")
```

---

## Building a zip bundle

### CLI builder

The native CLI can build a portable application or library bundle directly.
Each `--root` gives files a stable archive-relative prefix; use several roots
when an application shares source with other directories.

```sh
gengo bundle \
  --root app=./app \
  --root shared=./shared \
  --entry app/main.gengo \
  --exclude '**/*_test.gengo' \
  -o build/demo.zip
```

This stores `app/main.gengo` and `shared/...` in the ZIP, along with a
`gengo.manifest` containing the entrypoint. `--entry` is an archive-relative
source path and must be included by the selected roots and filters. The host
chooses the bundle's registered name, so registering this archive as `demo`
makes its entry module importable as `demo/app/main`.

`--include` and `--exclude` are repeatable glob filters for paths relative to
each root. By default all `.gengo` files are included; exclusions win. A
positional directory is also accepted and uses its basename as the root name:

```sh
gengo bundle app shared --entry app/main.gengo -o build/demo.zip
```

The command writes standard stored ZIP files, compatible with
`engine_load_bundle` and the TypeScript SDK. It does not assign a host bundle
name or run the entrypoint: that remains the embedding application's job.

### Other ZIP tools

Create the zip from inside the library root so entries are stored without the
bundle name prefix.  Given the layout above:

```sh
cd lib/mylib
zip -r ../../mylib.zip .
```

The zip entries must be relative to the bundle root.  The name used when
loading (`"mylib"`) is prepended automatically by the engine at import time, so
entries like `net/http.gengo` become importable as `mylib/net/http`.

If your tool adds a leading `./`, the engine strips it during loading.

---

## Loading a bundle (C API)

### Production: load from zip

```c
/* Read the zip into memory, then register it. */
char   *zip_data = read_file("mylib.zip", &zip_len);
int32_t rc = engine_load_bundle(engine,
                                "mylib", 5,
                                zip_data, (int32_t)zip_len);
free(zip_data);
if (rc != 0) { /* handle error */ }
```

### Development: load from directory

```c
int32_t rc = engine_load_bundle_dir(engine,
                                    "mylib", 5,
                                    "lib/mylib", 9);
if (rc != 0) { /* handle error */ }
```

`engine_load_bundle_dir` is available on native targets only.  On WASI it
returns `-5` (`GENGO_BUNDLE_ERR_INVALID`).

### Return codes

| Code | Meaning                                      |
|------|----------------------------------------------|
| `0`  | Success                                      |
| `-1` | Invalid engine handle                        |
| `-2` | Bundle table full (limit: 32 per engine)     |
| `-3` | File table full (limit: 64 files per bundle) |
| `-4` | File too large (limit: 64 KiB per file)      |
| `-5` | Invalid zip data, path, or bundle name       |

---

## Loading a bundle (TypeScript SDK)

```ts
const zip = await fetch("/bundles/mylib.zip").then(r => r.arrayBuffer());
engine.loadBundle("mylib", new Uint8Array(zip));
```

Remove all bundles at once:

```ts
engine.clearBundles();
```

---

## Import resolution order

When a script calls `import("some/path")` the engine searches in this order:

1. Standard library (`std`, `cap:*`, `host:*`)
2. Host modules registered with `engine_register_module`
3. Import loader callback (if set via `engine_set_import_loader`)
4. **Module bundles** (checked in registration order)
5. Sources registered with `engine_add_source`

If no source is found the compiler emits an error.

---

## Limits

| Resource               | Limit            |
|------------------------|------------------|
| Bundles per engine     | 32               |
| Files per bundle       | 64               |
| File size              | 64 KiB           |
| Bundle name length     | 63 bytes         |
| Module path length     | 127 bytes        |
| Supported compression  | store, deflate   |

---

## Complete C example

See [`examples/bundle-c/`](../examples/bundle-c/) for a working host that:

- loads a two-module scoring library as a bundle
- switches between directory mode (development) and zip mode (production)
  based on a command-line argument
- calls an `evaluate` function for each student and prints results

```c
/* Development */
engine_load_bundle_dir(engine, "scoring", 7, "lib/scoring", 11);

/* Production */
engine_load_bundle(engine, "scoring", 7, zip_data, zip_len);
```

---

## Best practices

**Keep `engine_load_bundle_dir` in development, `engine_load_bundle` in
production.**  The directory form reads files at load time, so edits are
visible immediately without restarting the host.  The zip form loads
everything at once and is self-contained.

**One bundle per logical library.**  Bundles share the same engine-wide
namespace, so keep related modules together under a single bundle name.

**Bundle names are part of the public API.**  Once scripts use
`import("mylib/...")`, changing the bundle name is a breaking change.

**Pre-load bundles before running any script.**  Bundle registration must
happen before the first `engine_run` call that imports from the bundle.
Bundles cannot be added incrementally after a script has started.

**`engine_clear_bundles` does not reset the script state.**  It only removes
the registered source files; compiled modules already loaded into the VM
continue to work.  Call it between full engine resets (`engine_reset`) if you
need to swap out a bundle.
