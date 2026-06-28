/** A Gengoscript value that can be converted to/from ValueWire. */
export type GVal =
  | { t: "null" }
  | { t: "bool"; v: boolean }
  | { t: "num"; v: number }
  | { t: "str"; v: string }
  | { t: "arr"; v: GVal[] }
  | { t: "map"; v: [GVal, GVal][] }
  | { t: "err"; v: string };

// -- constructors -----------------------------------------------------------

export function gnull(): GVal {
  return { t: "null" };
}

export function gbool(v: boolean): GVal {
  return { t: "bool", v };
}

export function gnum(v: number): GVal {
  return { t: "num", v };
}

export function gstr(v: string): GVal {
  return { t: "str", v };
}

export function garr(...items: GVal[]): GVal {
  return { t: "arr", v: items };
}

export function gmap(entries?: [GVal, GVal][]): GVal {
  return { t: "map", v: entries ?? [] };
}

export function gerr(v: string): GVal {
  return { t: "err", v };
}

// -- JS round-trip helpers --------------------------------------------------

/** Best-effort conversion from a plain JS value to GVal. */
export function fromJS(v: unknown): GVal {
  if (v === null || v === undefined) return { t: "null" };
  if (typeof v === "boolean") return { t: "bool", v };
  if (typeof v === "number") return { t: "num", v };
  if (typeof v === "string") return { t: "str", v };
  if (Array.isArray(v)) return { t: "arr", v: v.map(fromJS) };
  if (typeof v === "object") {
    const entries: [GVal, GVal][] = [];
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      entries.push([{ t: "str", v: k }, fromJS(val)]);
    }
    return { t: "map", v: entries };
  }
  return { t: "null" };
}

/** Best-effort conversion from GVal to a plain JS value. */
export function toJS(v: GVal): unknown {
  switch (v.t) {
    case "null": return null;
    case "bool": return v.v;
    case "num": return v.v;
    case "str": return v.v;
    case "err": return new Error(v.v);
    case "arr": return v.v.map(toJS);
    case "map": {
      const obj: Record<string, unknown> = {};
      for (const [k, val] of v.v) {
        const key = k.t === "str" ? k.v : String(toJS(k));
        obj[key] = toJS(val);
      }
      return obj;
    }
  }
}
