import test from "node:test";
import assert from "node:assert/strict";

import { WIRE_SIZE, encodeGVal, decodeGVal } from "../dist/wire.js";

test("ValueWire uses the padded ABI layout for payload and len", () => {
  const dv = new DataView(new ArrayBuffer(128));
  const ctx = { dv, pos: 0 };

  encodeGVal(ctx, { t: "num", v: 42 });

  assert.equal(WIRE_SIZE, 24);
  assert.equal(dv.getUint8(0), 2);
  assert.equal(dv.getUint8(1), 1);
  assert.equal(dv.getBigUint64(8, true), 42n);
  assert.equal(dv.getUint32(16, true), 0);
});

test("decodeGVal reads payload and len from the padded ABI offsets", () => {
  const dv = new DataView(new ArrayBuffer(128));

  dv.setUint8(0, 3); // string
  dv.setUint8(1, 0);
  dv.setUint16(2, 0, true);
  dv.setBigUint64(8, 24n, true);
  dv.setUint32(16, 2, true);
  dv.setUint32(20, 0, true);
  dv.setUint8(24, "o".charCodeAt(0));
  dv.setUint8(25, "k".charCodeAt(0));

  const [val, next] = decodeGVal({ dv }, 0);
  assert.deepEqual(val, { t: "str", v: "ok" });
  assert.equal(next, 24);
});
