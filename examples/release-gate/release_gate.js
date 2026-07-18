'use strict';
/**
 * release_gate.js — Safe release policy via Gengoscript scripting.
 *
 * A release pipeline needs to decide whether a deployment is allowed.
 * Each team writes a Gengoscript script that encodes their own rules. The pipeline
 * evaluates each script in an isolated WASM engine — a policy script cannot
 * reach the filesystem, the network, or any host state the platform has not
 * explicitly provided. A buggy or malicious policy cannot crash the evaluator.
 *
 * The policy script can also call back into the host via a registered module.
 * Here the host exposes a `pipeline` module with two functions:
 *   - pipeline.is_approved(env)        → bool
 *   - pipeline.has_role(actor, role)   → bool
 *
 * The script receives whatever the host decides to pass. Nothing else is
 * reachable — no network, no secrets, no other engine instances.
 *
 * Build the WASM engine first:
 *   zig build -Dpreset=dev engine-build
 *
 * Then run:
 *   node examples/release-gate/release_gate.js
 */

const path   = require('node:path');
const { Engine } = require('./gengo_engine');

const WASM_PATH = path.join(__dirname, '..', '..', 'build', 'debug', 'gengo-engine.wasm');

// ---------------------------------------------------------------------------
// Release policy scripts
//
// Each script must export:
//   pub func allow_deploy(env string, branch string, tests_passed bool, actor string) bool
//
// The `pipeline` host module is available for callbacks into the host.
// Scripts cannot reach anything the host has not explicitly registered.
// ---------------------------------------------------------------------------

// Standard policy: uses the pipeline host module to check approvals and roles.
const POLICY_STANDARD = `\
pipeline := import("host:pipeline")

pub func allow_deploy(env string, branch string, tests_passed bool, actor string) bool {
    if pipeline.has_role(actor, "bot") { return false }
    if env == "production" {
        return branch == "main" &&
               tests_passed &&
               pipeline.is_approved(env) &&
               pipeline.has_role(actor, "engineer")
    }
    if env == "staging" {
        return tests_passed && pipeline.has_role(actor, "engineer")
    }
    return true
}
`;

// A policy with a runtime bug: accesses index 0 of an empty slice.
// Compiles fine but panics when called. The evaluator catches the error
// and continues — the bug is isolated to this policy.
const POLICY_BUGGY = `\
pub func allow_deploy(env string, branch string, tests_passed bool, actor string) bool {
    overrides := []
    return overrides[0] == actor
}
`;

// A policy that loops forever.
// The instruction budget stops it and returns an error to the caller.
const POLICY_RUNAWAY = `\
pub func allow_deploy(env string, branch string, tests_passed bool, actor string) bool {
    n := 0
    for true { n += 1 }
    return false
}
`;

// ---------------------------------------------------------------------------
// Host-side state (what the pipeline module exposes to policy scripts)
//
// In a real system these would come from a database, a secrets manager,
// or an approval service. Here they are simple in-memory maps.
// ---------------------------------------------------------------------------

const APPROVALS = new Map([
  ['production', true ],
  ['staging',    true ],
  ['dev',        true ],
]);

const ACTOR_ROLES = new Map([
  ['alice',      'engineer'],
  ['bob',        'engineer'],
  ['carol',      'manager' ],
  ['deploy-bot', 'bot'     ],
]);

// ---------------------------------------------------------------------------
// ReleaseGate — evaluates a policy against a deployment request
// ---------------------------------------------------------------------------

class ReleaseGate {
  #engine;
  #name;

  constructor(engine, name) {
    this.#engine = engine;
    this.#name   = name;
  }

  static async create(name, policySource, maxOps = 500_000) {
    const eng = await Engine.load(WASM_PATH, { maxOps });

    // Register the host module before running the script so the compiler
    // can resolve `import("pipeline")` during compilation.
    eng.registerModule('pipeline', [
      {
        name: 'is_approved',
        arity: 1,
        fn: ([env]) => APPROVALS.get(env) === true,
      },
      {
        name: 'has_role',
        arity: 2,
        fn: ([actor, role]) => ACTOR_ROLES.get(actor) === role,
      },
    ]);

    const result = eng.run(policySource);
    if (!result.ok) {
      eng.free();
      throw new Error(`[${name}] compile error: ${result.error}`);
    }

    return new ReleaseGate(eng, name);
  }

  evaluate(env, branch, testsPassed, actor) {
    const result = this.#engine.call('allow_deploy', env, branch, testsPassed, actor);
    if (!result.ok) return { allowed: false, error: result.error };
    return { allowed: result.value === true };
  }

  get name() { return this.#name; }

  destroy() { this.#engine.free(); }
}

// ---------------------------------------------------------------------------
// Demo
// ---------------------------------------------------------------------------

const SCENARIOS = [
  //  env            branch             tests   actor
  ['production',  'main',           true,  'alice'     ],  // passes all checks
  ['production',  'feature/auth',   true,  'alice'     ],  // wrong branch
  ['production',  'main',           false, 'alice'     ],  // tests failed
  ['production',  'main',           true,  'carol'     ],  // manager, not engineer
  ['production',  'main',           true,  'deploy-bot'],  // bot role blocked
  ['staging',     'feature/auth',   true,  'alice'     ],  // staging OK
  ['staging',     'feature/auth',   false, 'alice'     ],  // staging needs tests
  ['dev',         'local-test',     false, 'alice'     ],  // dev is open
];

const POLICIES = [
  ['standard_policy', POLICY_STANDARD, 500_000],
  ['buggy_policy',    POLICY_BUGGY,    500_000],
  ['runaway_policy',  POLICY_RUNAWAY,  100_000],
];

function rule() { return '─'.repeat(72); }

async function runPolicy([name, source, budget]) {
  let gate;
  try {
    gate = await ReleaseGate.create(name, source, budget);
  } catch (err) {
    console.log(`[${name}]`);
    console.log(`  ${err.message}`);
    console.log();
    return;
  }

  console.log(`[${gate.name}]  budget: ${budget.toLocaleString()} ops`);

  for (const [env, branch, tests, actor] of SCENARIOS) {
    const { allowed, error } = gate.evaluate(env, branch, tests, actor);
    const verdict = error ? `error: ${error.split('\n')[0]}` : (allowed ? '✓ allowed' : '✗ denied');
    const ctx = `env=${env.padEnd(12)} branch=${branch.padEnd(16)} tests=${String(tests).padEnd(6)} actor=${actor}`;
    console.log(`  ${ctx}  →  ${verdict}`);
    if (error) {
      console.log(`  (evaluator still running — policy error is isolated)`);
      break;
    }
  }

  gate.destroy();
  console.log();
}

async function main() {
  console.log();
  console.log('Release gate — policy-as-code via Gengoscript');
  console.log(rule());
  console.log('Each team supplies a Gengoscript script. The pipeline runs it in an isolated WASM engine.');
  console.log('The script can call host:pipeline functions; it cannot reach anything else.');
  console.log();

  for (const policy of POLICIES) {
    await runPolicy(policy);
  }

  console.log(rule());
  console.log('Evaluator still running. Broken policies cannot affect the host process.');
  console.log();
}

main().catch(err => {
  console.error(err.message);
  process.exit(1);
});
