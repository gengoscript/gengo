# JSON schema validation

An alternative to declarative schema validators (JSON Schema, Zod, Joi) for
hosts that already embed Gengoscript: the validation rules are a small
Gengoscript program instead of a schema document.

This is the same constraint mechanism as `examples/firmware-gate-c` — named
types with `range`/`predicate` constraints — applied to a different shape of
input. firmware-gate-c validates fixed, already-typed scalar arguments from a
C call site. This example validates an arbitrary JSON document: it parses the
body with `std.json.parse`, walks it field by field, and reports every
violation rather than failing on the first one.

## What it shows

* `std.json.parse` turning a request body into a generic value
* Named-type `range`/`predicate` constraints doing the actual constraint
  checking — the same mechanism as policy/rule examples elsewhere in this repo
* `defer` + `recover` converting a constructor's `TypeError` panic into a
  plain per-field error message, instead of failing the whole request
* The host reading back a JSON array of error strings via a getter function,
  the same pattern used in `examples/order-normalizer`

## Why not just use a schema document?

A declarative schema (JSON Schema, Zod, ...) is portable and has tooling
(codegen, docs, form generation) that a Gengo script can't replicate. What
Gengo buys you instead is arbitrary validation logic in the same place as the
shape constraints — cross-field rules, lookups, business logic — without
reaching for a second DSL on top of the schema language. Reach for this when
your "schema" already needs to be more than shape and range checks; reach for
a schema document when you need that portability.

## Build and run

Build the WASM engine first:

```bash
zig build -Dpreset=1m engine-build
```

Then run:

```bash
node examples/json-schema-validation/validate.js
```

## Files

* `schema.gengo`: the validator — named-type constraints plus per-field
  checks that recover constructor panics into messages
* `validate.js`: a Node host that runs several requests (valid, multiple
  violations, missing fields, wrong types) through the validator
