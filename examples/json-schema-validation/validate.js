'use strict';
/**
 * validate.js — JSON request validation via Gengoscript, as a schema
 * validator alternative.
 *
 * Instead of a declarative schema (JSON Schema, Zod, Joi), the validation
 * rules are a small Gengoscript program: named types carry the range and
 * predicate constraints, and a `validate` function walks the parsed
 * document, recovering each field's type panic into a plain error message
 * so the host gets every violation, not just the first one.
 *
 * What this demonstrates:
 *   - std.json.parse turning a request body into a generic value
 *   - named-type range/predicate constraints doing the actual constraint
 *     checking (same mechanism as examples/firmware-gate-c)
 *   - defer + recover converting a TypeError panic into a soft per-field
 *     error message, collected across all fields
 *   - the host reading back a JSON array of error strings via a getter,
 *     the same pattern used in examples/order-normalizer
 *
 * Build first:
 *   zig build -Dpreset=dev engine-build
 *
 * Run:
 *   node examples/json-schema-validation/validate.js
 */

const fs = require('node:fs');
const path = require('node:path');
const { Engine } = require('../release-gate/gengo_engine');

const WASM_PATH = path.join(__dirname, '..', '..', 'build', 'gengo-engine.wasm');
const SCHEMA_PATH = path.join(__dirname, 'schema.gengo');

const REQUESTS = [
  {
    label: 'valid',
    body: { name: 'Ada Lovelace', age: 36, email: 'ada@example.com', role: 'admin' },
  },
  {
    label: 'multiple violations',
    body: { name: 'Bob', age: 200, email: 'not-an-email', role: 'superuser' },
  },
  {
    label: 'missing fields',
    body: { name: 'Cleo' },
  },
  {
    label: 'wrong types',
    body: { name: 42, age: 'old', email: 'cleo@example.com', role: 'member' },
  },
];

async function main() {
  const engine = await Engine.load(WASM_PATH);
  const result = engine.run(fs.readFileSync(SCHEMA_PATH, 'utf8'));
  if (!result.ok) {
    console.error(`schema compile error: ${result.error}`);
    process.exit(1);
  }

  console.log('JSON request validation via Gengoscript');
  console.log('─'.repeat(80));

  for (const req of REQUESTS) {
    const json = JSON.stringify(req.body);
    const { ok, value: valid, error } = engine.call('validate', json);
    console.log(`[${req.label}] ${json}`);

    if (!ok) {
      console.log(`  engine error: ${error}`);
      console.log();
      continue;
    }

    if (valid) {
      console.log('  valid');
    } else {
      const errorsJson = engine.call('errors_json');
      const errors = JSON.parse(errorsJson.value);
      for (const e of errors) console.log(`  invalid: ${e}`);
    }
    console.log();
  }

  engine.free();
}

main().catch(err => {
  console.error(err.message);
  process.exit(1);
});
