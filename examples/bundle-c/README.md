# bundle-c

A C embedding example showing how to use module bundles — Gengoscript's
mechanism for shipping a multi-file library as a single distributable artifact.

The example implements a quiz grader.  The grading logic lives in a two-module
library (`lib/scoring/`); the host loads it as a bundle and calls a single
`evaluate` function for each student.

## Layout

```
examples/bundle-c/
├── main.c               C host: loads bundle, calls evaluate()
├── quiz.gengo           entry script: imports from the bundle
└── lib/
    └── scoring/
        ├── grade.gengo  maps percentages to letter grades
        └── calc.gengo   computes scores, calls into grade
```

`calc.gengo` imports `grade.gengo` with a relative path (`./grade`).
`quiz.gengo` imports the bundle modules with full paths (`scoring/calc`).

## Prerequisites

Build the shared library first:

```sh
cd ../..
zig build -Doptimize=ReleaseFast
```

## Running

**Development mode** — modules loaded directly from the source directory:

```sh
make run
```

**Production mode** — modules loaded from a prebuilt zip bundle:

```sh
make run-zip
```

Expected output:

```
bundle: lib/scoring/ (directory)

Quiz results
============
  Alice: 92% (A) - PASS
  Bob: 76% (C) - PASS
  Carol: 68% (D) - PASS
  Dave: 97% (A) - PASS
  Eve: 0% (F) - FAIL
  Frank: 100% (A) - PASS
```

## How the bundle is loaded

In **development** mode the host calls `engine_load_bundle_dir` so changes to
the `.gengo` files take effect without rebuilding a zip:

```c
engine_load_bundle_dir(engine, "scoring", 7, "lib/scoring", 11);
```

In **production** mode the zip is read into memory and passed to
`engine_load_bundle`:

```c
engine_load_bundle(engine, "scoring", 7, zip_data, (int32_t)zip_len);
```

Either way the import paths in the scripts are identical — no code change is
needed to switch modes.

## Building the zip

The Makefile creates `scoring.zip` from the source files:

```sh
make scoring.zip
# or implicitly via: make run-zip
```

The `zip` command is run from inside `lib/scoring/` so the entries are stored
as `grade.gengo` and `calc.gengo` (no extra path prefix):

```
Archive:  scoring.zip
  adding: grade.gengo
  adding: calc.gengo
```

See [docs/module-bundles.md](../../docs/module-bundles.md) for a full guide.
