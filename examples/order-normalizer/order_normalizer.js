'use strict';
/**
 * order_normalizer.js — Multi-tenant order normalization via Gengoscript.
 *
 * A SaaS ingestion service receives messy partner records from many merchants.
 * Each merchant supplies a small Gengoscript script that adapts their input
 * conventions into one canonical internal shape.
 *
 * What this demonstrates:
 *   - customer-authored normalization logic without host redeploys
 *   - domain validation at the script boundary with named types
 *   - host-owned lookups exposed through a tiny module
 *   - per-merchant isolation and budget enforcement
 *   - realistic failure modes: reject, runtime panic, runaway script
 *
 * Build first:
 *   zig build -Dpreset=dev engine-build
 *
 * Run:
 *   node examples/order-normalizer/order_normalizer.js
 */

const fs = require('node:fs');
const path = require('node:path');
const { Engine } = require('../release-gate/gengo_engine');

const WASM_PATH = path.join(__dirname, '..', '..', 'build', 'gengo-engine.wasm');
const SCRIPT_DIR = path.join(__dirname, 'scripts');

const SKU_IDS = new Map([
  ['SKU-RED-42',  10042],
  ['SKU-BLUE-99', 10999],
  ['A-100',       50100],
  ['A-200',       50200],
]);

const ALLOWED_COUNTRIES = new Set([
  'SE', 'NO', 'DK', 'FI', 'DE', 'NL', 'US',
]);

function readScript(name) {
  return fs.readFileSync(path.join(SCRIPT_DIR, name), 'utf8');
}

class MerchantNormalizer {
  #engine;
  #merchant;

  constructor(engine, merchant) {
    this.#engine = engine;
    this.#merchant = merchant;
  }

  static async create(merchant, scriptFile, maxOps = 300_000) {
    const engine = await Engine.load(WASM_PATH, { maxOps });

    engine.registerModule('catalog', [
      {
        name: 'sku_id',
        arity: 1,
        fn: ([item]) => SKU_IDS.get(item) ?? 0,
      },
      {
        name: 'country_allowed',
        arity: 1,
        fn: ([country]) => ALLOWED_COUNTRIES.has(country),
      },
    ]);

    const result = engine.run(readScript(scriptFile));
    if (!result.ok) {
      engine.free();
      throw new Error(`[${merchant}] compile error: ${result.error}`);
    }

    return new MerchantNormalizer(engine, merchant);
  }

  normalize(record) {
    const result = this.#engine.call(
      'normalize',
      record.external_order_id,
      record.status,
      record.item,
      record.qty,
      record.weight_raw,
      record.currency,
      record.country,
    );

    if (!result.ok) {
      return { ok: false, kind: 'runtime_error', detail: result.error };
    }
    if (result.value !== true) {
      const reason = this.#readString('last_reason');
      return { ok: false, kind: 'reject', detail: reason || 'rejected' };
    }

    return {
      ok: true,
      normalized: {
        merchant: this.#merchant,
        order_id: this.#readString('last_order_id'),
        sku_id: this.#readNumber('last_sku_id'),
        quantity: this.#readNumber('last_quantity'),
        weight_grams: this.#readNumber('last_weight_grams'),
        currency: this.#readString('last_currency'),
        country: this.#readString('last_country'),
      },
    };
  }

  destroy() {
    this.#engine.free();
  }

  #readString(name) {
    const out = this.#engine.call(name);
    return out.ok ? out.value : `<error: ${out.error}>`;
  }

  #readNumber(name) {
    const out = this.#engine.call(name);
    return out.ok ? out.value : NaN;
  }
}

const MERCHANTS = [
  {
    merchant: 'acme-eu',
    script: 'acme_eu.gengo',
    budget: 300_000,
    records: [
      {
        external_order_id: 'PO-88421',
        status: 'READY',
        item: 'SKU-RED-42',
        qty: 2,
        weight_raw: 950,
        currency: 'EUR',
        country: 'SE',
      },
      {
        external_order_id: 'PO-88422',
        status: 'READY',
        item: 'UNKNOWN-SKU',
        qty: 1,
        weight_raw: 500,
        currency: 'EUR',
        country: 'SE',
      },
    ],
  },
  {
    merchant: 'globex-legacy',
    script: 'globex_legacy.gengo',
    budget: 300_000,
    records: [
      {
        external_order_id: 'GX-1200',
        status: 'APPROVED',
        item: 'A-100',
        qty: 3,
        weight_raw: 12,
        currency: 'USD',
        country: 'US',
      },
      {
        external_order_id: 'GX-1201',
        status: 'PENDING',
        item: 'A-200',
        qty: 4,
        weight_raw: 8,
        currency: 'USD',
        country: 'US',
      },
    ],
  },
  {
    merchant: 'buggy-partner',
    script: 'buggy_partner.gengo',
    budget: 300_000,
    records: [
      {
        external_order_id: 'BUG-1',
        status: 'READY',
        item: 'SKU-BLUE-99',
        qty: 1,
        weight_raw: 200,
        currency: 'EUR',
        country: 'DE',
      },
    ],
  },
  {
    merchant: 'runaway-partner',
    script: 'runaway_partner.gengo',
    budget: 100_000,
    records: [
      {
        external_order_id: 'LOOP-1',
        status: 'READY',
        item: 'SKU-BLUE-99',
        qty: 1,
        weight_raw: 200,
        currency: 'EUR',
        country: 'DE',
      },
    ],
  },
];

function rule() {
  return '─'.repeat(80);
}

function formatRecord(record) {
  return [
    `id=${record.external_order_id}`,
    `status=${record.status}`,
    `item=${record.item}`,
    `qty=${record.qty}`,
    `weight_raw=${record.weight_raw}`,
    `currency=${record.currency}`,
    `country=${record.country}`,
  ].join(' ');
}

async function runMerchant(config) {
  let normalizer;
  try {
    normalizer = await MerchantNormalizer.create(config.merchant, config.script, config.budget);
  } catch (err) {
    console.log(`[${config.merchant}]`);
    console.log(`  ${err.message}`);
    console.log();
    return;
  }

  console.log(`[${config.merchant}]  budget: ${config.budget.toLocaleString()} ops`);

  for (const record of config.records) {
    const result = normalizer.normalize(record);
    console.log(`  input   ${formatRecord(record)}`);

    if (!result.ok) {
      if (result.kind === 'reject') {
        console.log(`  reject  ${result.detail}`);
      } else {
        const firstLine = String(result.detail).split('\n')[0];
        console.log(`  error   ${firstLine}`);
        console.log(`  (merchant script isolated — host keeps processing others)`);
      }
      continue;
    }

    const n = result.normalized;
    console.log(
      `  accept  merchant=${n.merchant} order_id=${n.order_id} sku_id=${n.sku_id} qty=${n.quantity} weight_grams=${n.weight_grams} currency=${n.currency} country=${n.country}`,
    );
  }

  normalizer.destroy();
  console.log();
}

async function main() {
  console.log();
  console.log('Order normalization — customer-authored ingestion scripts via Gengoscript');
  console.log(rule());
  console.log('Each merchant script normalizes its own input quirks into one canonical host shape.');
  console.log('The host owns SKU lookups, country allowlists, isolation, and execution budgets.');
  console.log();

  for (const merchant of MERCHANTS) {
    await runMerchant(merchant);
  }

  console.log(rule());
  console.log('Host process still running. Broken merchant scripts stay isolated.');
  console.log();
}

main().catch(err => {
  console.error(err.message);
  process.exit(1);
});
