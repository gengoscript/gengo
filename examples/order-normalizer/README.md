# Order normalizer

A multi-tenant ingestion example where each merchant supplies a small
Gengoscript program that normalizes incoming order data into one canonical
shape.

This demonstrates a use case where Gengoscript fits well:

* customer-specific logic changes often
* the host must stay in control of lookups and resource usage
* invalid domain values should fail at the normalization boundary
* one tenant's buggy script must not affect the others

The host application:

* runs each merchant script in its own isolated WASM engine
* exposes a tiny `host:catalog` module for SKU and country lookups
* enforces an instruction budget per merchant
* treats runtime failures as isolated per-merchant failures

The scripts:

* validate quantities, weights, currencies, and countries with named types
* adapt merchant-specific quirks such as legacy statuses and unit conversion
* normalize into canonical scalar fields that the host can read back

Why the example uses getter functions after `normalize()` succeeds:

* the current public embedding helpers move scalars across the boundary cleanly
* complex engine-owned values are not yet ergonomic to pass back to JS hosts
* this example keeps the script logic realistic while staying runnable today

## Build and run

Build the WASM engine first:

```bash
zig build -Dpreset=dev engine-build
```

Then run:

```bash
node examples/order-normalizer/order_normalizer.js
```

## What it shows

* `acme_eu.gengo`: a straightforward EU merchant policy
* `globex_legacy.gengo`: legacy status names plus ounce-to-gram conversion
* `buggy_partner.gengo`: compiles, then panics at runtime
* `runaway_partner.gengo`: loops forever until the instruction budget stops it
