/**
 * ValueWire encoding / decoding for the Gengoscript engine WASM ABI.
 *
 * WireTag  | flags         | payload              | len
 * ---------|---------------|----------------------|-------
 * null (0) |               | 0                    | 0
 * bool (1) |               | 0|1                  | 0
 * num  (2) | 0=float       | f64 bits as u64      | 0
 * num  (2) | FLAG_INT=0x01 | raw int64 bits       | 0
 * str  (3) |               | linear-memory ptr    | byte length
 * arr  (4) |               | ptr to ValueWire[]   | element count
 * map  (5) |               | ptr to ValueWire[]   | entry count (pairs: k,v,k,v…)
 */

import { GVal } from "./types";

export const WIRE_SIZE = 24; // bytes per ValueWire (tag+flags+reserved[2]+pad[4]+payload[8]+len[4]+reserved2[4])

const FLAG_INTEGER = 0x01; // GENGO_WIRE_FLAG_INTEGER: payload is raw int64 bits

export const enum WireTag {
  Null = 0,
  Bool = 1,
  Num = 2,
  Str = 3,
  Arr = 4,
  Map = 5,
  Err = 6,
}

// ---------------------------------------------------------------------------
// Encoding helpers – write GVal → ValueWire bytes into a DataView
// ---------------------------------------------------------------------------

export interface WireWriteCtx {
  dv: DataView;
  /** bump-allocated region: next free offset */
  pos: number;
}

/** Write a single u8 at the current position and advance. */
function writeU8(ctx: WireWriteCtx, v: number): void {
  ctx.dv.setUint8(ctx.pos, v);
  ctx.pos += 1;
}

function writeU16(ctx: WireWriteCtx, v: number): void {
  ctx.dv.setUint16(ctx.pos, v, true);
  ctx.pos += 2;
}

function writeU32(ctx: WireWriteCtx, v: number): void {
  ctx.dv.setUint32(ctx.pos, v, true);
  ctx.pos += 4;
}

function writeU64(ctx: WireWriteCtx, v: bigint): void {
  ctx.dv.setBigUint64(ctx.pos, v, true);
  ctx.pos += 8;
}

/** Write a ValueWire header (24 bytes) at ctx.pos, leaving payload/len
 *  placeholders that may be patched later.  Returns the offset of the header
 *  so the caller can go back and fill payload/len. */
function writeWireHeader(ctx: WireWriteCtx, tag: WireTag): number {
  const off = ctx.pos;
  writeU8(ctx, tag);
  writeU8(ctx, 0); // flags
  writeU16(ctx, 0); // reserved
  writeU64(ctx, 0n); // payload placeholder
  writeU32(ctx, 0); // len placeholder
  writeU32(ctx, 0); // reserved2
  return off;
}

/** Patch a previously written header with payload (u64) and len (u32). */
function patchWire(ctx: WireWriteCtx, headerOff: number, payload: bigint, len: number): void {
  ctx.dv.setBigUint64(headerOff + 4, payload, true);
  ctx.dv.setUint32(headerOff + 12, len, true);
}

/**
 * Encode a GVal into sequential ValueWire entries starting at ctx.pos.
 * Strings and array/map element buffers are also written into ctx.  Returns
 * the final ctx.pos after encoding.
 *
 * NOTE: ctx.dv must cover enough space.  The caller should ensure scratch
 * space by growing WASM memory before calling this.
 */
export function encodeGVal(ctx: WireWriteCtx, val: GVal): number {
  switch (val.t) {
    case "null": {
      writeWireHeader(ctx, WireTag.Null);
      return ctx.pos;
    }
    case "bool": {
      const off = writeWireHeader(ctx, WireTag.Bool);
      patchWire(ctx, off, val.v ? 1n : 0n, 0);
      return ctx.pos;
    }
    case "num": {
      const off = writeWireHeader(ctx, WireTag.Num);
      if (Number.isInteger(val.v)) {
        ctx.dv.setUint8(off + 1, FLAG_INTEGER);
        patchWire(ctx, off, BigInt.asUintN(64, BigInt(val.v)), 0); // raw i64 bits
      } else {
        const buf = new ArrayBuffer(8);
        new Float64Array(buf)[0] = val.v;
        patchWire(ctx, off, new BigUint64Array(buf)[0], 0);
      }
      return ctx.pos;
    }
    case "str": {
      const bytes = new TextEncoder().encode(val.v);
      const ptrOff = ctx.pos;
      // write string data into scratch (advance pos)
      for (let i = 0; i < bytes.length; i++) {
        ctx.dv.setUint8(ctx.pos, bytes[i]);
        ctx.pos += 1;
      }
      const off = writeWireHeader(ctx, WireTag.Str);
      patchWire(ctx, off, BigInt(ptrOff), bytes.length);
      return ctx.pos;
    }
    case "arr": {
      // First write each element, collecting their header offsets
      const elemStart = ctx.pos;
      // Allocate space for elements (we'll compute the count after encoding)
      // We write elements first, then the array header with payload pointing to the first element
      const elemPositions: number[] = [];
      for (const item of val.v) {
        elemPositions.push(ctx.pos);
        ctx.pos = encodeGVal(ctx, item);
      }
      // Array header at the end (or wherever — the host just reads the pointer)
      const elemCount = elemPositions.length;
      const off = writeWireHeader(ctx, WireTag.Arr);
      patchWire(ctx, off, BigInt(elemStart), elemCount);
      return ctx.pos;
    }
    case "map": {
      // Write key-value pairs alternately
      const pairStart = ctx.pos;
      for (const [k, v] of val.v) {
        ctx.pos = encodeGVal(ctx, k);
        ctx.pos = encodeGVal(ctx, v);
      }
      const entryCount = val.v.length;
      const off = writeWireHeader(ctx, WireTag.Map);
      patchWire(ctx, off, BigInt(pairStart), entryCount);
      return ctx.pos;
    }
  }
}

// ---------------------------------------------------------------------------
// Decoding helpers – read ValueWire bytes → GVal
// ---------------------------------------------------------------------------

export interface WireReadCtx {
  dv: DataView;
}

function readU8(ctx: WireReadCtx, off: number): number {
  return ctx.dv.getUint8(off);
}
function readU32(ctx: WireReadCtx, off: number): number {
  return ctx.dv.getUint32(off, true);
}
function readU64(ctx: WireReadCtx, off: number): bigint {
  return ctx.dv.getBigUint64(off, true);
}

/**
 * Decode a single ValueWire located at offset `off` and produce a GVal.
 * Returns the GVal and the next offset after this wire.
 * For array/map, recursively decodes element/pair wires from their buffer
 * pointers.
 */
export function decodeGVal(ctx: WireReadCtx, off: number): [GVal, number] {
  const tag = readU8(ctx, off) as WireTag;
  const payload = readU64(ctx, off + 4);
  const len = readU32(ctx, off + 12);
  const nextOff = off + WIRE_SIZE;

  switch (tag) {
    case WireTag.Null:
      return [{ t: "null" }, nextOff];

    case WireTag.Bool:
      return [{ t: "bool", v: payload !== 0n }, nextOff];

    case WireTag.Num: {
      const flags = readU8(ctx, off + 1);
      if (flags & FLAG_INTEGER) {
        return [{ t: "num", v: Number(BigInt.asIntN(64, payload)) }, nextOff]; // raw i64 bits
      }
      const buf = new ArrayBuffer(8);
      new BigUint64Array(buf)[0] = payload;
      return [{ t: "num", v: new Float64Array(buf)[0] }, nextOff];
    }

    case WireTag.Str: {
      const ptr = Number(payload);
      const byteLen = len;
      const bytes = new Uint8Array(ctx.dv.buffer, ptr, byteLen);
      const str = new TextDecoder().decode(bytes);
      return [{ t: "str", v: str }, nextOff];
    }

    case WireTag.Arr: {
      const elemPtr = Number(payload);
      const count = len;
      const items: GVal[] = [];
      let pos = elemPtr;
      for (let i = 0; i < count; i++) {
        const [gv, next] = decodeGVal(ctx, pos);
        items.push(gv);
        pos = next;
      }
      return [{ t: "arr", v: items }, nextOff];
    }

    case WireTag.Map: {
      const pairPtr = Number(payload);
      const count = len;
      const entries: [GVal, GVal][] = [];
      let pos = pairPtr;
      for (let i = 0; i < count; i++) {
        const [k, n1] = decodeGVal(ctx, pos);
        const [v, n2] = decodeGVal(ctx, n1);
        entries.push([k, v]);
        pos = n2;
      }
      return [{ t: "map", v: entries }, nextOff];
    }

    case WireTag.Err: {
      const ptr = Number(payload);
      const bytes = new Uint8Array(ctx.dv.buffer, ptr, len);
      const msg = new TextDecoder().decode(bytes);
      return [{ t: "err", v: msg }, nextOff];
    }

    default:
      return [{ t: "null" }, nextOff];
  }
}
