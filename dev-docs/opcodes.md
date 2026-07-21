# Opcode Reference

Gengo uses a single-byte opcode space (u8, 256 slots): 192 slots
(0x00–0xBF) for **core ops** the compiler emits, and the last 64 slots
(0xC0–0xFF) reserved as flexible, VM-private space for **fused ops** —
opcodes the load-time fusion pass selects, never the compiler, free to
change shape release to release since nothing outside the VM depends on
their numeric identity. See "Opcode space policy" below for why this
split is fixed and doesn't move.

Of the 192 core slots, 117 are assigned and 75 remain free for future
core primitives — permanent once claimed, since core is what GBC's wire
format will encode. Of the 64 fused slots, 35 are assigned and 29 remain
free for future fused patterns. That's 152 of 256 slots assigned overall,
104 free.

Two kinds of opcode live in this space, distinguished only by numeric
range — there is no tag byte or separate namespace; the VM dispatches on
both identically. **Core ops** (0x00–0x82) are what the compiler emits
directly. **Fused/specialized ops** (0xC0–0xE2) are never emitted by the
compiler — they are produced from core-op bytecode by a separate
load-time rewrite pass (`src/lang/fusion_pass.zig`) that runs after
verification and before execution, replacing common 2–4 instruction
patterns (e.g. `constant` + `eq` → `const_eq`) with a single fused
instruction. This keeps the compiler simple (one code path, no
emission-time pattern tracking) while still letting the VM dispatch fused
forms at execution time. The rewrite is exact and reversible:
`src/lang/vm_defuse.zig` expands fused code back to core ops, and a
differential test (`chaos_spec_test.zig`, "spec pass cases refuse
differential") compiles every spec case, defuses it, re-fuses it, and
checks the output is unchanged.

**Stability today: fused values are frozen, same as core ops.** The plan
is for fused values to eventually become a private VM-internal detail,
free to renumber between versions — but that only becomes true once the
bytecode cache (GBC, `dev-docs/design/gbc-spec.md`) ships with a wire
format that serializes the *defused*, core-ops-only form exclusively.
That loader does not exist yet (see `dev-docs/roadmap.md`). Until it does,
nothing decouples a fused opcode's numeric value from anything that might
depend on it, so the same rule applies to the whole table: don't renumber
an assigned slot, add new ops only by claiming a `reserved_*` slot.

## Opcode space policy (ratified 2026-07-20, permanent)

The 0x00–0xBF / 0xC0–0xFF split — **192 slots for core, 64 for
fused/specialized** — is fixed policy, not an incidental byproduct of
current usage. It does not move. Rationale:

- **Core ops are what GBC's wire format will encode.** Once the bytecode
  cache ships, every core slot spent is permanent — it has to mean the
  same thing forever, across every cache ever written. Core needs the
  bigger reservation precisely because a mistake there is unrecoverable.
- **Fused ops stay VM-private and renumberable forever**, GBC or not — the
  load-time fusion pass (`src/lang/fusion_pass.zig`) regenerates them
  fresh from source on every load, so nothing external ever depends on
  their numeric identity. This has already been exercised once in
  practice: `get_global_const_eq_jif_pop` was added, found to never fire,
  and deleted (`3366941`) — a slot reclaimed at zero cost. Running low on
  fused slots is cheap to fix; running low on core slots is not.
- The asymmetry, not growth rate, is why the reservation is asymmetric:
  the side where mistakes are permanent gets the bigger cushion.

**Rejected alternatives, with measured cost — do not re-propose without
new data:**

- **u16 opcode field.** Not built or measured as of this writing; if
  fused-slot pressure ever gets real (see fallback below), a real
  prototype is the next thing to build, not a straight adoption.
- **WASM-style prefix byte for fused ops** (a marker opcode + a second
  indexed dispatch into the real handler). Built as a real, working
  prototype (`prefix_spike.zig`, 2026-07-20) covering the 6
  highest-frequency fused ops and measured with hyperfine on ReleaseFast:
  **9% slower on `fib_recursive`, 25% slower on `dispatch_loop`.** Loop
  back-edges are the hottest instructions in the VM, and they're exactly
  where the extra fetch + second indirect jump costs the most — the
  "amortize over N replaced dispatches" theory does not hold in practice.
  Reverted in full; see the prior discussion in this doc's history for
  the walkthrough.

**Fallback if the 64 fused slots are ever exhausted: build/link-time-
selected fused-op-set profiles**, not a wire-format or dispatch change.
Different builds compile in different fusion-pattern tables and VM
dispatch arms for the same numeric range — a compile-time choice, not a
runtime branch, so it costs nothing per-instruction (a given running
binary only ever has one fused set live). This is already consistent with
today's reality: fused bytecode isn't a portable wire format pre-GBC
anyway, since it's regenerated per load from source.

Hover a cell to see the full instruction name and description.

```html
<style>
.opmat-outer{overflow-x:auto;margin:1em 0}
.opmat{border-collapse:collapse;font-family:"Courier New",Courier,monospace;font-size:.8em}
.opmat th,.opmat td{border:1px solid #888;padding:2px 4px;text-align:center;vertical-align:middle}
.opmat th{background:#e8e8e8;white-space:nowrap}
.opmat td{width:52px;height:32px;cursor:default}
.opmat td:hover{background:#e8e8e8}
.op-hex{font-size:.8em;color:#888;display:block}
.op-mn{font-weight:bold;display:block}
.op-free{background-color:#fff;background-image:repeating-linear-gradient(-45deg,#bbb 0,#bbb 1px,transparent 1px,transparent 6px);color:#bbb}
</style>
<div class="opmat-outer">
<table class="opmat" id="gengo-opmat"></table>
</div>
<script>
(function(){
var OPS=[
  [0x00,"halt",  "halt — normal program/function end"],
  [0x01,"unrech","op_unreachable — dead-code sentinel; traps if reached"],
  [0x02,"jump",  "jump — unconditional branch (4-byte offset)"],
  [0x03,"jif",   "jump_if_false — branch if TOS falsy"],
  [0x04,"jif·p", "jif_pop — pop+branch on false"],
  [0x05,"jinn",  "jump_if_not_null — non-null peek+jump (?? operator)"],
  [0x06,"loop",  "loop — back-edge jump"],
  [0x07,"call",  "call — function call [op][argc][ic_hi][ic_lo]"],
  [0x08,"call·t","call_tail — tail-position call"],
  [0x09,"call·s","call_spread — spread multi-return call"],
  [0x0A,"dcall", "defer_call — deferred function call"],
  [0x0B,"invoke","invoke_method — method dispatch with inline cache"],
  [0x0C,"dinvk", "defer_invoke_method — deferred method call"],
  [0x0D,"ret",   "ret — function return"],
  [0x0E,"get·l", "get_local — local slot read [op][slot]"],
  [0x0F,"set·l", "set_local — local slot write"],
  [0x10,"get·g", "get_global — global name read (const-idx)"],
  [0x11,"set·g", "set_global — global write"],
  [0x12,"def·g", "def_global — global variable definition"],
  [0x13,"get·u", "get_upvalue — upvalue read"],
  [0x14,"set·u", "set_upvalue — upvalue write"],
  [0x15,"close", "close_upvalue — local-to-heap-cell promotion"],
  [0x16,"mkcls", "make_closure — function+upvalue wrapper"],
  [0x17,"const", "constant — constant pool load [op][hi][lo]"],
  [0x18,"null",  "null_val — null literal"],
  [0x19,"true",  "true_val — true literal"],
  [0x1A,"false", "false_val — false literal"],
  [0x1B,"dup",   "dup — TOS duplicate"],
  [0x1C,"dup2",  "dup2 — top-2 duplicate"],
  [0x1D,"pop",   "pop — TOS discard"],
  [0x1E,"add",   "add — generic addition"],
  [0x1F,"sub",   "sub — generic subtraction"],
  [0x20,"mul",   "mul — generic multiplication"],
  [0x21,"div",   "div — generic division"],
  [0x22,"idiv",  "int_div — integer (floor) division"],
  [0x23,"rem",   "rem — remainder (sign follows dividend)"],
  [0x24,"mod",   "mod — modulo (always non-negative)"],
  [0x25,"pow",   "pow — exponentiation"],
  [0x26,"neg",   "neg — unary negation"],
  [0x27,"eq",    "eq — generic equality"],
  [0x28,"ne",    "ne — generic inequality"],
  [0x29,"lt",    "lt — generic less-than"],
  [0x2A,"le",    "le — generic less-or-equal"],
  [0x2B,"gt",    "gt — generic greater-than"],
  [0x2C,"ge",    "ge — generic greater-or-equal"],
  [0x2D,"not",   "not — boolean negation"],
  [0x32,"eqz·i", "eqz_int — i64 == 0"],
  [0x33,"nez·i", "nez_int — i64 != 0"],
  [0x34,"ltz·i", "ltz_int — i64 < 0"],
  [0x35,"lez·i", "lez_int — i64 <= 0"],
  [0x36,"gtz·i", "gtz_int — i64 > 0"],
  [0x37,"gez·i", "gez_int — i64 >= 0"],
  [0x42,"eq·f",  "eq_float — f64 equality"],
  [0x43,"ne·f",  "ne_float — f64 inequality"],
  [0x44,"lt·f",  "lt_float — f64 less-than"],
  [0x45,"le·f",  "le_float — f64 less-or-equal"],
  [0x46,"gt·f",  "gt_float — f64 greater-than"],
  [0x47,"ge·f",  "ge_float — f64 greater-or-equal"],
  [0x48,"abs",   "abs — absolute value"],
  [0x49,"floor", "floor — round toward -∞"],
  [0x4A,"ceil",  "ceil — round toward +∞"],
  [0x4B,"trunc", "trunc — truncate toward zero"],
  [0x4C,"nrst",  "nearest — round to nearest even"],
  [0x4D,"min",   "min — minimum of two values"],
  [0x4E,"max",   "max — maximum of two values"],
  [0x4F,"sign",  "sign — signum (-1 / 0 / 1)"],
  [0x50,"sqrt",  "sqrt — square root"],
  [0x51,"clamp", "clamp — clamp to [lo, hi]"],
  [0x52,"b·and", "bit_and — bitwise AND"],
  [0x53,"b·or",  "bit_or — bitwise OR"],
  [0x54,"b·xor", "bit_xor — bitwise XOR"],
  [0x55,"b·not", "bit_not — bitwise NOT"],
  [0x56,"shl",   "shl — shift left"],
  [0x57,"shr",   "shr — shift right (arithmetic)"],
  [0x58,"c·int", "cast_int — value → int"],
  [0x59,"c·flt", "cast_float — value → float"],
  [0x5A,"c·dec", "cast_decimal — value → decimal"],
  [0x5B,"c·bol", "cast_bool — value → bool"],
  [0x5C,"c·str", "cast_string — value → string"],
  [0x5D,"c·run", "cast_rune — value → rune"],
  [0x5E,"c·big", "cast_bigint — value → bigint"],
  [0x5F,"a·typ", "assert_type — array/map/error kind assertion"],
  [0x60,"a·ifc", "assert_interface — interface conformance assertion"],
  [0x61,"a·str", "assert_struct — struct type assertion"],
  [0x62,"tynam", "type_name — runtime type name (.type operator)"],
  [0x63,"s·prd", "set_named_predicate — named type predicate attachment"],
  [0x64,"v·dft", "validate_type_default — named type default validation"],
  [0x65,"assrt", "op_assert — condition assertion"],
  [0x66,"ass·m", "op_assert_msg — condition assertion with message"],
  [0x67,"trap",  "op_trap_check — recover trap check"],
  [0x68,"v·chk", "variant_check — variant tag check"],
  [0x69,"v·pay", "variant_payload — variant payload extraction"],
  [0x6A,"b·arr", "build_array — array build from N stack values"],
  [0x6B,"b·map", "build_map — map build from N key-value pairs"],
  [0x6C,"b·tup", "build_tuple — tuple build from N values"],
  [0x6D,"b·str", "build_struct_instance — struct instance build"],
  [0x6E,"z·str", "zero_struct — zero-valued struct literal"],
  [0x6F,"t·ari", "tuple_check_arity — tuple arity check"],
  [0x70,"t·get", "tuple_get — tuple element read (pop)"],
  [0x71,"t·gk",  "tuple_get_keep — tuple element read (keep)"],
  [0x72,"g·idx", "get_index — array/map index read"],
  [0x73,"s·idx", "set_index — array/map index write"],
  [0x74,"g·slc", "get_slice — array slice [lo:hi]"],
  [0x75,"g·fld", "get_field — struct field read with inline cache"],
  [0x76,"s·fld", "set_field — struct field write with inline cache"],
  [0x77,"it·in", "iter_init — for-in iterator initialization"],
  [0x7A,"n·in",  "named_inner — unwrap a runtime named value when one exists"],
  [0x7B,"n·prd", "check_named_predicate — u16 named-type constant; validate TOS predicate chain"],
  [0x7C,"swap",  "swap — exchange the top two stack values"],
  [0x7D,"n·rng", "validate_named_range — u16 named-type constant; normalize/validate TOS range or cycle"],
  [0x78,"it·n1", "iter_next1 — iterator step, 1 value"],
  [0x79,"it·n2", "iter_next2 — iterator step, 2 values"],
  [0x7E,"len",   "len — pop a value, push its length (string rune count, array/map size, struct field count); lowered from std.core.len(x)"],
  [0x7F,"append","append — [op][argc]; pop argc values (array + items), push the resulting array; lowered from std.core.append(a, ...items)"],
  [0x80,"blen",  "bytelen — pop a value, push its raw byte length (no rune counting); lowered from std.core.bytelen(x)"],
  [0x81,"b·dec", "bytes_decode — [op][kind]; pop offset then data, decode a fixed-width int/float at that offset; lowered from std.bytes.{at,u16be_at,u32be_at,u64be_at,u16le_at,u32le_at,u64le_at,f32be_at,f32le_at,f64be_at,f64le_at}"],
  [0x82,"gi·cs", "get_index_const_str — u16:name_const_idx; get_index specialized for a bare string-literal index (m[\"literal\"]); map_hashed reads the key straight from the constant pool, everything else falls back to opGetIndex"],
  [0xC0,"c_eq",  "const_eq — fused constant+eq"],
  [0xC1,"c_sub", "const_sub — fused constant+sub"],
  [0xC2,"c_add", "const_add — fused constant+add"],
  [0xC3,"c_lt",  "const_lt — fused constant+lt"],
  [0xC4,"c_gt",  "const_gt — fused constant+gt"],
  [0xC5,"glc·eq","get_local_const_eq — triple-fused get_local+const+eq (5 bytes)"],
  [0xC6,"glc·sb","get_local_const_sub — triple-fused (5 bytes)"],
  [0xC7,"glc·ad","get_local_const_add — triple-fused (5 bytes)"],
  [0xC8,"glc·lt","get_local_const_lt — triple-fused (5 bytes)"],
  [0xC9,"glc·gt","get_local_const_gt — triple-fused (5 bytes)"],
  [0xCA,"glcejp","get_local_const_eq_jif_pop — quad-fused eq+branch (9 bytes)"],
  [0xCB,"glcljp","get_local_const_lt_jif_pop — quad-fused lt+branch (9 bytes)"],
  [0xCC,"glcgjp","get_local_const_gt_jif_pop — quad-fused gt+branch (9 bytes)"],
  [0xCD,"glcljj","get_local_const_lt_jif_pop_jump — quint-fused for-loop header (13 bytes)"],
  [0xCE,"ggc·eq","get_global_const_eq — triple-fused get_global+const+eq (8 bytes)"],
  [0xCF,"ggc·sb","get_global_const_sub — triple-fused (8 bytes)"],
  [0xD0,"ggc·ad","get_global_const_add — triple-fused (8 bytes)"],
  [0xD1,"ggc·lt","get_global_const_lt — triple-fused (8 bytes)"],
  [0xD2,"ggcljp","get_global_const_lt_jif_pop — quad-fused global lt+branch (12 bytes)"],
  [0xD3,"glgfl", "get_local_get_field — fused get_local+get_field (8 bytes)"],
  [0xD4,"sgl·lp","set_global_loop — fused set_global+loop (9 bytes)"],
  [0xD5,"cup·lp","close_upvalue_loop — fused close_upvalue+loop (6 bytes)"],
  [0xD6,"ret·c", "ret_const — fused constant+ret"],
  [0xD7,"gl·ret","get_local_ret — fused get_local+ret"],
  [0xD8,"glsc·c","get_local_const_sub_call — fused local-decrement+call (6 bytes)"],
  [0xD9,"glsc·t","get_local_const_sub_call_tail — tail variant"],
  [0xDA,"cglsc", "call_global_local_sub_const — hexa-fused recursive fast path (11 bytes)"],
  [0xDB,"cglsct","call_global_local_sub_const_tail — tail variant"],
  [0xDC,"add·rt","add_ret — fused add+ret"],
  [0xDD,"l·al",  "local_add_local — dst += src (3 bytes)"],
  [0xDE,"l·ac",  "local_add_const — dst += k (4 bytes)"],
  [0xDF,"l·acl", "local_add_const_loop — fused dst+=k + loop (8 bytes)"],
  [0xE0,"l·af",  "local_add_field — dst += src.field (9 bytes)"],
  [0xE1,"igc",   "inc_global_const — global += const in-place (8 bytes)"],
  [0xE2,"f·ac",  "field_add_const — field += const in-place, e.g. c.tx_id = c.tx_id + 1 (15 bytes)"]
];
var by={};
for(var i=0;i<OPS.length;i++) by[OPS[i][0]]=OPS[i];
var tbl=document.getElementById("gengo-opmat");
var hr=tbl.insertRow();
var ct=document.createElement("th");ct.textContent="";hr.appendChild(ct);
for(var c=0;c<16;c++){
  var th=document.createElement("th");
  th.textContent="·"+c.toString(16).toUpperCase();
  hr.appendChild(th);
}
for(var r=0;r<16;r++){
  var tr=tbl.insertRow();
  var rh=document.createElement("th");
  rh.textContent=(r*16).toString(16).toUpperCase().padStart(2,"0")+"·";
  tr.appendChild(rh);
  for(var c=0;c<16;c++){
    var b=r*16+c,td=tr.insertCell(),op=by[b];
    if(op){
      td.title=op[2];
      var hs=document.createElement("span");hs.className="op-hex";hs.textContent=b.toString(16).toUpperCase().padStart(2,"0");
      var ms=document.createElement("span");ms.className="op-mn";ms.textContent=op[1];
      td.appendChild(hs);td.appendChild(ms);
    } else {
      td.className="op-free";
      var hs=document.createElement("span");hs.className="op-hex";hs.textContent=b.toString(16).toUpperCase().padStart(2,"0");
      td.appendChild(hs);
    }
  }
}
})();
</script>
```

## Slot summary

| Range | Count | Group |
|-------|-------|-------|
| 0x00–0x06 | 7 | Control flow |
| 0x07–0x0D | 7 | Call / return |
| 0x0E–0x16 | 9 | Variables / closure |
| 0x17–0x1D | 7 | Stack / literals |
| 0x1E–0x26 | 9 | Generic arithmetic |
| 0x27–0x2D | 7 | Generic comparison / logic |
| 0x2E–0x31 | 4 | Free (reserved for future core ops) |
| 0x32–0x37 | 6 | Int zero-compare (eqz_int..gez_int) |
| 0x38–0x3D | 6 | Free (reserved for future core ops) |
| 0x3E–0x41 | 4 | Free (reserved for future core ops) |
| 0x42–0x47 | 6 | Typed float comparison (eq_float..ge_float) |
| 0x48–0x51 | 10 | Math intrinsics |
| 0x52–0x57 | 6 | Bitwise |
| 0x58–0x5E | 7 | Cast |
| 0x5F–0x69 | 11 | Type system / assertions |
| 0x6A–0x79 | 16 | Collections / struct |
| 0x7A–0x7D | 4 | Named-scalar validation / stack |
| 0x7E–0x81 | 4 | Stdlib intrinsics (len, append, bytelen, bytes_decode) |
| 0x82 | 1 | get_index_const_str (constant-key map/index access, #206) |
| 0x83–0xBF | 61 | Free (reserved for future core ops) |
| 0xC0–0xE2 | 35 | Fused / peephole |
| 0xE3–0xFF | 29 | Free (within fused block) |

Total assigned: 152 of 256 slots.

The 0x00–0xBF (core, 192 slots) / 0xC0–0xFF (fused, 64 slots) boundary is
permanent policy — see "Opcode space policy" above. It does not move to
grow either side.

## Instruction widths

Most opcodes are 1 byte. Multi-byte instructions encode operands immediately
after the opcode byte.

| Width | Examples |
|-------|---------|
| 1 byte | Most arithmetic, comparison, stack ops |
| 2 bytes | `get_local`, `set_local`, `get_upvalue`, `build_array`, … |
| 3 bytes | `constant`, `const_eq/sub/add/lt/gt`, `assert_interface`, `check_named_predicate`, `validate_named_range`, … |
| 4 bytes | `call`, `call_tail`, `local_add_const` |
| 5 bytes | `get_local_const_*`, `jump`, `jump_if_false`, `loop`, `get_global`, … |
| 6 bytes | `get_field`, `set_field`, `get_local_const_sub_call`, `close_upvalue_loop` |
| 8 bytes | `get_global_const_*`, `get_local_get_field`, `set_global_loop`, `inc_global_const` |
| 9 bytes | `get_local_const_*_jif_pop`, `local_add_field` |
| 11 bytes | `call_global_local_sub_const` |
| 12 bytes | `get_global_const_lt_jif_pop` |
| 13 bytes | `get_local_const_lt_jif_pop_jump`, `call_global_local_sub_const_tail` |
| 15 bytes | `field_add_const` |
