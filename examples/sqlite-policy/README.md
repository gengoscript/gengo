# SQLite policy (C)

SQLite runs in every phone, browser, and embedded device.  This example
registers a Gengoscript validation function directly into SQLite so that
BEFORE INSERT / BEFORE UPDATE triggers enforce your business rules at the
database layer — not in application code scattered across multiple callers.

The validation logic lives in `validate.gengo`.  Change the rules, restart
the process.  No schema migration, no application redeployment, no
recompilation.

## What it shows

* SQLite custom functions (`sqlite3_create_function`) backed by Gengo
* BEFORE INSERT and BEFORE UPDATE triggers using `WHEN gengo_validate(...) = 0`
* One Gengo engine loaded once, called many times per insert
* Rejection reasons surfaced to the caller after a failed write
* Fail-closed: a broken policy script blocks all writes

## Build

Build the native engine first:

```bash
zig build -Dpreset=1m engine-native
```

Then build the example:

```bash
cd examples/sqlite-policy
make
```

## Run

From the `examples/sqlite-policy` directory:

```bash
./sqlite_policy
```

To use a different policy script:

```bash
./sqlite_policy /path/to/validate.gengo
```

## How it works

Two SQLite functions are registered against the Gengo engine:

| Function | Arguments | Returns |
|---|---|---|
| `gengo_validate` | `amount_cents, currency, qty` | 1 (accept) or 0 (reject) |
| `gengo_reject_reason` | — | last rejection message |

The BEFORE INSERT trigger uses `gengo_validate` in its WHEN clause:

```sql
CREATE TRIGGER orders_bi BEFORE INSERT ON orders
WHEN gengo_validate(NEW.amount_cents, NEW.currency, NEW.qty) = 0
BEGIN
  SELECT raise(abort, 'order validation failed');
END;
```

SQLite evaluates the WHEN expression first.  When `gengo_validate` returns 0
it also stores the reason inside the engine.  The trigger body fires
`raise(abort, ...)` to block the write.  The application then calls
`SELECT gengo_reject_reason()` to retrieve the human-readable reason.

```
INSERT amount_cents=0 ...
  -> REJECTED  amount out of range (1 to 100,000,000 cents)

INSERT currency=BTC ...
  -> REJECTED  unsupported currency: BTC
```

## Changing the rules

Open `validate.gengo` and edit the allowed currencies, ranges, or add new
checks.  The next process start picks up the new rules automatically — no
other file needs to change.
