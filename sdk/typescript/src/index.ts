/**
 * Gengo TypeScript SDK
 *
 * Wraps the Gengo embeddable WASM engine for use in Node.js and browser
 * environments.
 *
 * ## Quick start (browser)
 * ```ts
 * import { GengoEngine, gstr, gnum } from "gengo";
 *
 * const engine = await GengoEngine.load(fetch("/gengo-engine.wasm"));
 * engine.onStdout = console.log;
 *
 * engine.run(`std := import("std"); std.io.println("hello from Gengo!")`);
 *
 * const result = engine.call("myFunc", [gnum(42)]);
 * engine.destroy();
 * ```
 *
 * @module
 */

export { GengoEngine } from "./gengo-engine";
export type { HostFunctionDef, EngineResult, EngineOptions } from "./gengo-engine";
export {
  type GVal,
  gnull, gbool, gnum, gstr, garr, gmap,
  fromJS, toJS,
} from "./types";
