/**
 * GengoEngine – TypeScript wrapper for the Gengoscript embeddable WASM engine.
 *
 * Usage:
 * ```ts
 * const engine = await GengoEngine.load("/gengo-engine.wasm");
 * engine.onStdout = console.log;
 * engine.run(`std := import("std"); std.io.println("hello")`);
 * engine.free();
 * ```
 */

import { GVal } from "./types";
import { WIRE_SIZE, encodeGVal, decodeGVal, WireWriteCtx, WireReadCtx } from "./wire";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
const MAX_ERROR_LEN = 512;
const SCRATCH_PAGES = 4;

const RESULT_OK = 0;
const RESULT_COMPILE_ERR = -1;
const RESULT_RUNTIME_ERR = -2;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface HostFunctionDef {
  name: string;
  arity: number;
  fn: (args: GVal[]) => GVal;
}

export type EngineResult =
  | { ok: true }
  | { ok: false; kind: "compile" | "runtime"; message: string; line: number; col: number };

export interface EngineOptions {
  onStdout?: (text: string) => void;
  onStderr?: (text: string) => void;
}

// ---------------------------------------------------------------------------
// GengoEngine
// ---------------------------------------------------------------------------

export class GengoEngine {
  private instance: WebAssembly.Instance;
  private memory: WebAssembly.Memory;
  private exports: Record<string, (...args: number[]) => number>;
  private handle: number;

  onStdout: ((text: string) => void) | null = null;
  onStderr: ((text: string) => void) | null = null;

  private hostFuncs = new Map<number, (args: GVal[]) => GVal>();
  private nextHostCallId = 0x1000;

  // Scratch bump allocator
  private scratchBase = 0;
  private scratchPos = 0;
  private scratchSize = 0;
  private dv!: DataView;

  private constructor(
    instance: WebAssembly.Instance,
    memory: WebAssembly.Memory,
    exports: Record<string, (...args: number[]) => number>,
  ) {
    this.instance = instance;
    this.memory = memory;
    this.exports = exports;
    this.setupScratch();
    this.handle = this.callExport("engine_init", []);
    if (this.handle <= 0) throw new Error("engine_init failed");
  }

  static async load(
    source: BufferSource | WebAssembly.Module,
    options?: EngineOptions,
  ): Promise<GengoEngine> {
    const mod = source instanceof WebAssembly.Module
      ? source
      : await WebAssembly.compile(source);

    const memRef: { current: WebAssembly.Memory | null } = { current: null };

    let onStdout: ((text: string) => void) | null = options?.onStdout ?? null;
    let onStderr: ((text: string) => void) | null = options?.onStderr ?? null;
    const hostFuncs = new Map<number, (args: GVal[]) => GVal>();

    const importObj = {
      env: {
        gengo_write(ptr: number, len: number, is_stderr: number): void {
          const mem = memRef.current!;
          const bytes = new Uint8Array(mem.buffer, ptr, len);
          const text = new TextDecoder().decode(bytes);
          if (is_stderr) onStderr?.(text);
          else onStdout?.(text);
        },
      },
      gengo_host: {
        gengo_native_call(id: number, argsPtr: number, argc: number, outPtr: number): number {
          const mem = memRef.current!;
          const fn = hostFuncs.get(id);
          if (!fn) return 1;
          const ctx: WireReadCtx = { dv: new DataView(mem.buffer) };
          const args: GVal[] = [];
          let pos = argsPtr;
          for (let i = 0; i < argc; i++) {
            const [gv, next] = decodeGVal(ctx, pos);
            args.push(gv);
            pos = next;
          }
          let result: GVal;
          try { result = fn(args); } catch { return 4; }
          const wctx: WireWriteCtx = { dv: new DataView(mem.buffer), pos: outPtr };
          encodeGVal(wctx, result);
          return 0;
        },
      },
    };

    const inst = await WebAssembly.instantiate(mod, importObj);
    const mem = inst.exports.memory as WebAssembly.Memory;
    memRef.current = mem;

    const exports: Record<string, (...args: number[]) => number> = {};
    for (const [k, v] of Object.entries(inst.exports)) {
      if (typeof v === "function") exports[k] = v as (...args: number[]) => number;
    }

    const engine = new GengoEngine(inst, mem, exports);
    if (options) {
      if (options.onStdout) engine.onStdout = options.onStdout;
      if (options.onStderr) engine.onStderr = options.onStderr;
    }
    onStdout = (t) => engine.onStdout?.(t);
    onStderr = (t) => engine.onStderr?.(t);
    engine.hostFuncs = hostFuncs;
    return engine;
  }

  // ------------------------------------------------------------------
  // Scratch memory management
  // ------------------------------------------------------------------

  private setupScratch(): void {
    const initialPages = this.memory.grow(0);
    this.memory.grow(SCRATCH_PAGES);
    this.scratchBase = (initialPages + 1) * 65536;
    this.scratchSize = SCRATCH_PAGES * 65536;
    this.scratchPos = this.scratchBase;
    this.dv = new DataView(this.memory.buffer);
  }

  private resetScratch(): void {
    this.scratchPos = this.scratchBase;
    this.dv = new DataView(this.memory.buffer);
  }

  private ensureScratch(needed: number): void {
    const remaining = this.scratchSize - (this.scratchPos - this.scratchBase);
    if (remaining < needed) {
      this.scratchPos = this.scratchBase;
      const afterReset = this.scratchSize;
      if (afterReset < needed) {
        const pages = Math.ceil((needed - afterReset) / 65536);
        this.memory.grow(pages);
        this.scratchSize += pages * 65536;
        this.dv = new DataView(this.memory.buffer);
      }
    }
  }

  private scratchString(s: string): [number, number] {
    const bytes = new TextEncoder().encode(s);
    this.ensureScratch(bytes.length + 32);
    const ptr = this.scratchPos;
    for (let i = 0; i < bytes.length; i++) {
      this.dv.setUint8(ptr + i, bytes[i]);
    }
    this.scratchPos += bytes.length;
    return [ptr, bytes.length];
  }

  // ------------------------------------------------------------------
  // Low-level
  // ------------------------------------------------------------------

  private assertAlive(): void {
    if (this.handle <= 0) throw new Error("GengoEngine: operation called after free()");
  }

  private callExport(name: string, args: number[]): number {
    return this.exports[name](...args);
  }

  // ------------------------------------------------------------------
  // Public API
  // ------------------------------------------------------------------

  run(source: string): EngineResult {
    this.assertAlive();
    this.resetScratch();
    const [srcPtr, srcLen] = this.scratchString(source);
    const rc = this.callExport("engine_run", [this.handle, srcPtr, srcLen]);
    if (rc === RESULT_OK) return { ok: true };
    return this.readError(rc);
  }

  runPath(source: string, path: string): EngineResult {
    this.assertAlive();
    this.resetScratch();
    const [srcPtr, srcLen] = this.scratchString(source);
    const [pathPtr, pathLen] = this.scratchString(path);
    const rc = this.callExport("engine_run_path", [
      this.handle, srcPtr, srcLen, pathPtr, pathLen,
    ]);
    if (rc === RESULT_OK) return { ok: true };
    return this.readError(rc);
  }

  call(name: string, args: GVal[]): GVal {
    this.assertAlive();
    this.resetScratch();
    const [namePtr, nameLen] = this.scratchString(name);

    const argsPtr = this.scratchPos;
    const ctx: WireWriteCtx = { dv: this.dv, pos: this.scratchPos };
    for (const arg of args) {
      ctx.pos = encodeGVal(ctx, arg);
    }
    this.scratchPos = ctx.pos;
    const argc = args.length;

    const outPtr = this.scratchPos;
    this.ensureScratch(WIRE_SIZE);
    this.scratchPos += WIRE_SIZE;

    const rc = this.callExport("engine_call", [
      this.handle, namePtr, nameLen, argsPtr, argc, outPtr,
    ]);
    if (rc === RESULT_RUNTIME_ERR) {
      const err = this.readError(rc);
      throw new Error(`engine_call failed: ${err.message} (${err.line}:${err.col})`);
    }

    const readCtx: WireReadCtx = { dv: this.dv };
    const [result] = decodeGVal(readCtx, outPtr);
    return result;
  }

  getGlobal(name: string): GVal | undefined {
    this.assertAlive();
    this.resetScratch();
    const [namePtr, nameLen] = this.scratchString(name);
    const outPtr = this.scratchPos;
    this.ensureScratch(WIRE_SIZE);
    this.scratchPos += WIRE_SIZE;
    const rc = this.callExport("engine_get_global", [this.handle, namePtr, nameLen, outPtr]);
    if (rc === -2) return undefined;
    if (rc !== RESULT_OK) throw new Error(`engine_get_global failed: ${rc}`);
    const ctx: WireReadCtx = { dv: this.dv };
    const [val] = decodeGVal(ctx, outPtr);
    return val;
  }

  addSource(path: string, source: string): void {
    this.assertAlive();
    this.resetScratch();
    const [pathPtr, pathLen] = this.scratchString(path);
    const [srcPtr, srcLen] = this.scratchString(source);
    const rc = this.callExport("engine_add_source", [
      this.handle, pathPtr, pathLen, srcPtr, srcLen,
    ]);
    if (rc !== RESULT_OK) throw new Error(`engine_add_source failed: ${rc}`);
  }

  registerModule(name: string, funcs: HostFunctionDef[]): void {
    this.assertAlive();
    this.resetScratch();
    const [namePtr, nameLen] = this.scratchString(name);

    const funcsPtr = this.scratchPos;
    for (const f of funcs) {
      const [fnPtr, fnLen] = this.scratchString(f.name);
      this.dv.setUint32(this.scratchPos, fnPtr, true); this.scratchPos += 4;
      this.dv.setUint32(this.scratchPos, fnLen, true); this.scratchPos += 4;
      this.dv.setUint32(this.scratchPos, f.arity, true); this.scratchPos += 4;
    }

    const rc = this.callExport("engine_register_module", [
      this.handle, namePtr, nameLen, funcsPtr, funcs.length,
    ]);
    if (rc !== RESULT_OK) throw new Error(`engine_register_module failed: ${rc}`);

    for (const f of funcs) {
      this.hostFuncs.set(this.nextHostCallId, f.fn);
      this.nextHostCallId++;
    }
  }

  reset(): void {
    this.assertAlive();
    this.callExport("engine_reset", [this.handle]);
  }

  destroy(): void { this.free(); }

  free(): void {
    if (this.handle > 0) {
      this.callExport("engine_destroy", [this.handle]);
      this.handle = 0;
    }
  }

  // ------------------------------------------------------------------
  // Error helpers
  // ------------------------------------------------------------------

  private readError(rc: number): EngineResult {
    const kind = rc === RESULT_COMPILE_ERR ? "compile" as const : "runtime" as const;
    const outPtr = this.scratchPos;
    this.ensureScratch(MAX_ERROR_LEN);
    this.scratchPos += MAX_ERROR_LEN;

    const written = this.callExport("engine_last_error", [this.handle, outPtr, MAX_ERROR_LEN]);
    if (written <= 0) {
      return { ok: false, kind, message: `engine error ${rc}`, line: 0, col: 0 };
    }
    const bytes = new Uint8Array(this.memory.buffer, outPtr, written);
    const message = new TextDecoder().decode(bytes);
    const line = this.callExport("engine_last_error_line", [this.handle]);
    const col = this.callExport("engine_last_error_col", [this.handle]);
    return { ok: false, kind, message, line, col };
  }
}
