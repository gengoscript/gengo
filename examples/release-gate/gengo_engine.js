'use strict';
/**
 * gengo_engine.js — Node.js wrapper for gengo-engine.wasm.
 *
 * No npm dependencies. Requires Node.js 18+.
 *
 * Build the WASM engine first:
 *   zig build -Dpreset=dev engine-build
 *
 * Usage:
 *   const { Engine } = require('./gengo_engine');
 *
 *   const eng = await Engine.load('/path/to/gengo-engine.wasm');
 *   eng.run(`func greet(name string) string { return "hello, " + name }`);
 *   const { value } = eng.call('greet', 'world');
 *   console.log(value);  // hello, world
 *   eng.free();
 */

const fs = require('node:fs');

// ---------------------------------------------------------------------------
// ValueWire layout  (must match ValueWire in src/runtime/host_abi.zig)
//
//  offset  size  field
//  ------  ----  -----
//       0     1  tag      (u8)
//       1     1  flags    (u8)
//       2     2  reserved (u16)
//       4     4  padding
//       8     8  payload  (u64, little-endian)
//      16     4  len      (u32, little-endian)
//      20     4  reserved2
//  total: 24 bytes
// ---------------------------------------------------------------------------

const WIRE_SIZE    = 24;
const TAG_NULL     = 0;
const TAG_BOOL     = 1;
const TAG_NUM      = 2;
const TAG_STR      = 3;
const TAG_ERR      = 6;
const FLAG_INTEGER = 0x01;  // payload is raw int64 bits (two's complement)

// Module-level so the WASM import closure can reach them without going through
// the Engine class (private fields are inaccessible from import closures).

function wireRead(dv, off) {
  const tag     = dv.getUint8(off);
  const flags   = dv.getUint8(off + 1);
  const payload = dv.getBigUint64(off + 8, true);
  const len     = dv.getUint32(off + 16, true);
  const next    = off + WIRE_SIZE;

  switch (tag) {
    case TAG_NULL: return [null, next];
    case TAG_BOOL: return [payload !== 0n, next];
    case TAG_NUM: {
      if (flags & FLAG_INTEGER) {
        return [Number(dv.getBigInt64(off + 8, true)), next]; // raw i64 bits
      }
      const tmp = new ArrayBuffer(8);
      new BigUint64Array(tmp)[0] = payload;
      return [new Float64Array(tmp)[0], next];
    }
    case TAG_STR:
    case TAG_ERR: {
      if (len === 0) return ['', next];
      const ptr   = Number(payload);
      const bytes = new Uint8Array(dv.buffer, ptr, len);
      return [new TextDecoder().decode(bytes), next];
    }
    default: return [null, next];
  }
}

function wireWrite(dv, off, value) {
  for (let i = 0; i < WIRE_SIZE; i++) dv.setUint8(off + i, 0);
  if (value === null || value === undefined) {
    dv.setUint8(off, TAG_NULL);
  } else if (typeof value === 'boolean') {
    dv.setUint8(off, TAG_BOOL);
    dv.setBigUint64(off + 8, value ? 1n : 0n, true);
  } else if (typeof value === 'number') {
    dv.setUint8(off, TAG_NUM);
    if (Number.isInteger(value)) {
      dv.setUint8(off + 1, FLAG_INTEGER);
      dv.setBigInt64(off + 8, BigInt(value), true); // raw i64 bits
    } else {
      const tmp = new ArrayBuffer(8);
      new Float64Array(tmp)[0] = value;
      dv.setBigUint64(off + 8, new BigUint64Array(tmp)[0], true);
    }
  }
  // String returns from host functions require allocation in WASM memory;
  // use bool/number results where possible. See the TypeScript SDK for full support.
}

// ---------------------------------------------------------------------------
// InstanceConfig layout  (WASM32: usize = 4 bytes)
//
//  offset  size  field
//  ------  ----  -----
//       0     4  heap_size_bytes (u32)
//       4     4  max_objects     (u32)
//       8     4  max_stack       (u32)
//      12     4  max_frames      (u32)
//      16     4  max_defers      (u32)
//      20     4  padding
//      24     8  max_ops         (i64, -1 = unlimited)
//      32     1  allow_io        (bool)
//      33     7  padding
//  total: 40 bytes
// ---------------------------------------------------------------------------

const CONFIG_SIZE = 40;

// ---------------------------------------------------------------------------
// HostModuleFuncDef layout  (WASM32)
//
//  offset  size  field
//  ------  ----  -----
//       0     4  name_ptr (u32)
//       4     4  name_len (u32)
//       8     4  arity    (u32)
//  total: 12 bytes
// ---------------------------------------------------------------------------

const FUNC_DEF_SIZE = 12;

// The engine assigns host call IDs starting from this base, incrementing per
// registered function. The host must mirror this sequence exactly.
const HOST_CALL_ID_BASE = 0x1000;  // matches HostModuleCallIdBase in engine.zig

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

const SCRATCH_PAGES = 8;  // 512 KB scratch space for strings and wire values

class Engine {
  #inst;
  #mem;
  #handle;
  #scratchBase;
  #scratchPos;
  #hostFns;      // Map<callId, fn> — same reference as the gengo_native_call closure
  #nextCallId;

  constructor(inst, mem, handle, scratchBase, hostFns) {
    this.#inst        = inst;
    this.#mem         = mem;
    this.#handle      = handle;
    this.#scratchBase = scratchBase;
    this.#scratchPos  = scratchBase;
    this.#hostFns     = hostFns;
    this.#nextCallId  = HOST_CALL_ID_BASE;
  }

  /**
   * Load the engine WASM module from a file path.
   *
   * @param {string} wasmPath
   * @param {object} [opts]
   * @param {number} [opts.maxOps]  Instruction budget (-1 or omit = unlimited).
   */
  static async load(wasmPath, opts = {}) {
    const bytes   = fs.readFileSync(wasmPath);
    const memRef  = { current: null };
    const hostFns = new Map();  // shared by the import closure and the Engine instance

    const importObj = {
      // WASI stubs — the engine is built as wasm32-wasi so these imports must
      // be satisfied. In embedded mode (allow_io=false) most are never called;
      // clock and random are used by the standard library.
      wasi_snapshot_preview1: {
        random_get(bufPtr, bufLen) {
          const buf = new Uint8Array(memRef.current.buffer, bufPtr, bufLen);
          crypto.getRandomValues(buf);
          return 0;
        },
        clock_time_get(clockId, _precision, timePtr) {
          const ns = BigInt(Date.now()) * 1_000_000n;
          new DataView(memRef.current.buffer).setBigUint64(timePtr, ns, true);
          return 0;
        },
        clock_res_get(clockId, resPtr) {
          new DataView(memRef.current.buffer).setBigUint64(resPtr, 1_000_000n, true);
          return 0;
        },
        environ_sizes_get(countPtr, bufSizePtr) {
          const dv = new DataView(memRef.current.buffer);
          dv.setUint32(countPtr, 0, true);
          dv.setUint32(bufSizePtr, 0, true);
          return 0;
        },
        environ_get(_environPtr, _environBufPtr) { return 0; },
        poll_oneoff(_in, _out, _nsubs, neventPtr) {
          new DataView(memRef.current.buffer).setUint32(neventPtr, 0, true);
          return 0;
        },
        // fd_write is called by Zig's panic handler; drain it silently.
        fd_write(fd, iovsPtr, iovsLen, nwrittenPtr) {
          const dv = new DataView(memRef.current.buffer);
          let total = 0;
          for (let i = 0; i < iovsLen; i++) {
            total += dv.getUint32(iovsPtr + i * 8 + 4, true);
          }
          dv.setUint32(nwrittenPtr, total, true);
          return 0;
        },
        fd_read()               { return 8; },  // EBADF
        fd_seek()               { return 8; },
        fd_close()              { return 8; },
        fd_fdstat_get()         { return 8; },
        fd_filestat_get()       { return 8; },
        fd_filestat_set_size()  { return 8; },
        fd_filestat_set_times() { return 8; },
        fd_pread()              { return 8; },
        fd_pwrite()             { return 8; },
        fd_readdir()            { return 8; },
        fd_sync()               { return 8; },
        path_open()             { return 8; },
        path_filestat_get()     { return 8; },
        path_create_directory() { return 8; },
        path_remove_directory() { return 8; },
        path_unlink_file()      { return 8; },
        path_readlink()         { return 8; },
      },
      env: {
        gengo_write(ptr, len, isStderr) {
          const bytes = new Uint8Array(memRef.current.buffer, ptr, len);
          const text  = new TextDecoder().decode(bytes);
          (isStderr ? process.stderr : process.stdout).write(text);
        },
        gengo_read(_ptr, _maxLen, _isLine) {
          return 0;  // EOF / no input available
        },
      },
      gengo_host: {
        gengo_native_call(id, argsPtr, argc, outPtr) {
          const fn = hostFns.get(id);
          if (!fn) return 1;
          const dv   = new DataView(memRef.current.buffer);
          const args = [];
          let pos    = argsPtr;
          for (let i = 0; i < argc; i++) {
            const [val, next] = wireRead(dv, pos);
            args.push(val);
            pos = next;
          }
          let result;
          try { result = fn(args); } catch { return 4; }
          wireWrite(dv, outPtr, result);
          return 0;
        },
      },
    };

    const { instance } = await WebAssembly.instantiate(bytes, importObj);
    const mem          = instance.exports.memory;
    memRef.current     = mem;

    // Grow scratch pages at the top of the engine's existing memory.
    const initialPages = mem.grow(SCRATCH_PAGES);
    const scratchBase  = initialPages * 65536;

    let handle;
    const ex = instance.exports;

    if (opts.maxOps !== undefined) {
      const dv  = new DataView(mem.buffer);
      const cfg = scratchBase;
      dv.setUint32  (cfg +  0, 524288,              true);  // heap_size_bytes
      dv.setUint32  (cfg +  4, 2048,                true);  // max_objects
      dv.setUint32  (cfg +  8, 512,                 true);  // max_stack
      dv.setUint32  (cfg + 12, 64,                  true);  // max_frames
      dv.setUint32  (cfg + 16, 128,                 true);  // max_defers
      dv.setUint32  (cfg + 20, 0,                   true);  // padding
      dv.setBigInt64(cfg + 24, BigInt(opts.maxOps), true);  // max_ops
      dv.setUint8   (cfg + 32, 0);                          // allow_io = false
      handle = ex.engine_init_with_config(cfg);
    } else {
      handle = ex.engine_init();
    }

    if (handle <= 0) throw new Error(`engine_init failed (code ${handle})`);

    // Scratch space starts after the config struct so we don't clobber it on reset.
    return new Engine(instance, mem, handle, scratchBase + CONFIG_SIZE, hostFns);
  }

  // --------------------------------------------------------------------------
  // Scratch allocator
  // --------------------------------------------------------------------------

  #resetScratch() {
    this.#scratchPos = this.#scratchBase;
  }

  #bump(n) {
    const ptr = this.#scratchPos;
    this.#scratchPos += n;
    return ptr;
  }

  // Align scratch position to n bytes (n must be a power of 2).
  #align(n) {
    this.#scratchPos = (this.#scratchPos + n - 1) & ~(n - 1);
  }

  #writeString(s) {
    const bytes = new TextEncoder().encode(s);
    const ptr   = this.#bump(bytes.length);
    new Uint8Array(this.#mem.buffer, ptr, bytes.length).set(bytes);
    return [ptr, bytes.length];
  }

  // --------------------------------------------------------------------------
  // Public API
  // --------------------------------------------------------------------------

  /**
   * Compile and run a Gengoscript source string.
   *
   * @returns {{ ok: true } | { ok: false, error: string }}
   */
  run(source) {
    this.#assertAlive();
    this.#resetScratch();
    const [ptr, len] = this.#writeString(source);
    const rc = this.#inst.exports.engine_run(this.#handle, ptr, len);
    if (rc !== 0) return { ok: false, error: this.#lastError() };
    return { ok: true };
  }

  /**
   * Call a named function exported by the loaded script.
   *
   * @param {string} name   Function name.
   * @param {...*}   args   boolean, number, string, or null.
   * @returns {{ ok: true, value: * } | { ok: false, error: string }}
   */
  call(name, ...args) {
    this.#assertAlive();
    this.#resetScratch();
    const dv = new DataView(this.#mem.buffer);

    const [namePtr, nameLen] = this.#writeString(name);

    // ValueWire contains a u64 field — Zig's Debug build enforces 8-byte
    // alignment on the pointer. Align before allocating any wire structs.
    this.#align(8);
    const argsBase = this.#scratchPos;
    this.#bump(WIRE_SIZE * args.length);  // pre-allocate all wire structs contiguously
    for (let i = 0; i < WIRE_SIZE * args.length; i++) dv.setUint8(argsBase + i, 0);

    for (let i = 0; i < args.length; i++) {
      const off = argsBase + i * WIRE_SIZE;
      const arg = args[i];

      if (arg === null || arg === undefined) {
        dv.setUint8(off, TAG_NULL);
      } else if (typeof arg === 'boolean') {
        dv.setUint8(off, TAG_BOOL);
        dv.setBigUint64(off + 8, arg ? 1n : 0n, true);
      } else if (typeof arg === 'number') {
        dv.setUint8(off, TAG_NUM);
        if (Number.isInteger(arg)) dv.setUint8(off + 1, FLAG_INTEGER);
        const tmp = new ArrayBuffer(8);
        new Float64Array(tmp)[0] = arg;
        dv.setBigUint64(off + 8, new BigUint64Array(tmp)[0], true);
      } else if (typeof arg === 'string') {
        // Write string data AFTER all wire structs have been reserved.
        const [strPtr, strLen] = this.#writeString(arg);
        dv.setUint8(off, TAG_STR);
        dv.setBigUint64(off + 8, BigInt(strPtr), true);
        dv.setUint32(off + 16, strLen, true);
      }
    }

    this.#align(8);  // outPtr must also be 8-byte aligned
    const outPtr = this.#bump(WIRE_SIZE);
    for (let i = 0; i < WIRE_SIZE; i++) dv.setUint8(outPtr + i, 0);

    const rc = this.#inst.exports.engine_call(
      this.#handle, namePtr, nameLen, argsBase, args.length, outPtr,
    );
    if (rc !== 0) return { ok: false, error: this.#lastError() };

    const [value] = wireRead(new DataView(this.#mem.buffer), outPtr);
    return { ok: true, value };
  }

  /**
   * Register a host-side module that scripts can import.
   *
   * Scripts import the module as: `m := import("host:<name>")`
   *
   * The engine assigns call IDs sequentially from HOST_CALL_ID_BASE in
   * registration order across all modules. This wrapper mirrors that sequence,
   * so registerModule calls must happen in the same order as script imports.
   *
   * @param {string}  name   Module name (no prefix).
   * @param {Array}   funcs  [{ name: string, arity: number, fn: Function }]
   */
  registerModule(name, funcs) {
    this.#assertAlive();
    this.#resetScratch();
    const dv = new DataView(this.#mem.buffer);

    const [namePtr, nameLen] = this.#writeString(name);

    // HostModuleFuncDef has only u32 fields — 4-byte alignment is sufficient.
    // Pre-allocate ALL struct entries before writing any string data so the
    // engine can read them as a contiguous array starting at funcsBase.
    this.#align(4);
    const funcsBase = this.#scratchPos;
    this.#bump(FUNC_DEF_SIZE * funcs.length);

    for (let i = 0; i < funcs.length; i++) {
      const [fnPtr, fnLen] = this.#writeString(funcs[i].name);
      const off = funcsBase + i * FUNC_DEF_SIZE;
      dv.setUint32(off + 0, fnPtr,          true);  // name_ptr
      dv.setUint32(off + 4, fnLen,          true);  // name_len
      dv.setUint32(off + 8, funcs[i].arity, true);  // arity
    }

    const rc = this.#inst.exports.engine_register_module(
      this.#handle, namePtr, nameLen, funcsBase, funcs.length,
    );
    if (rc !== 0) throw new Error(`engine_register_module("${name}") failed (code ${rc})`);

    for (const f of funcs) {
      this.#hostFns.set(this.#nextCallId, f.fn);
      this.#nextCallId += 1;
    }
  }

  /**
   * Destroy the engine instance and release its WASM-side memory.
   * No methods may be called after free().
   */
  free() {
    if (this.#handle > 0) {
      this.#inst.exports.engine_destroy(this.#handle);
      this.#handle = 0;
    }
  }

  // --------------------------------------------------------------------------

  #assertAlive() {
    if (this.#handle <= 0) throw new Error('Engine.free() has already been called');
  }

  #lastError() {
    const buf  = this.#bump(512);
    const n    = this.#inst.exports.engine_last_error(this.#handle, buf, 512);
    if (n <= 0) return '(no error)';
    const msg  = new TextDecoder().decode(new Uint8Array(this.#mem.buffer, buf, n));
    const line = this.#inst.exports.engine_last_error_line(this.#handle);
    const col  = this.#inst.exports.engine_last_error_col(this.#handle);
    return line > 0 ? `${msg} (line ${line}, col ${col})` : msg;
  }
}

module.exports = { Engine };
