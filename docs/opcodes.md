# Opcode Reference

Gengo uses a single-byte opcode space (u8, 256 slots). 156 of 256 are
assigned, leaving 100 free for future use.

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
  [0x2E,"add·i", "add_int — i64 addition"],
  [0x2F,"sub·i", "sub_int — i64 subtraction"],
  [0x30,"mul·i", "mul_int — i64 multiplication"],
  [0x31,"div·i", "div_int — i64 division"],
  [0x32,"eqz·i", "eqz_int — i64 == 0"],
  [0x33,"nez·i", "nez_int — i64 != 0"],
  [0x34,"ltz·i", "ltz_int — i64 < 0"],
  [0x35,"lez·i", "lez_int — i64 <= 0"],
  [0x36,"gtz·i", "gtz_int — i64 > 0"],
  [0x37,"gez·i", "gez_int — i64 >= 0"],
  [0x38,"eq·i",  "eq_int — i64 equality"],
  [0x39,"ne·i",  "ne_int — i64 inequality"],
  [0x3A,"lt·i",  "lt_int — i64 less-than"],
  [0x3B,"le·i",  "le_int — i64 less-or-equal"],
  [0x3C,"gt·i",  "gt_int — i64 greater-than"],
  [0x3D,"ge·i",  "ge_int — i64 greater-or-equal"],
  [0x3E,"add·f", "add_float — f64 addition"],
  [0x3F,"sub·f", "sub_float — f64 subtraction"],
  [0x40,"mul·f", "mul_float — f64 multiplication"],
  [0x41,"div·f", "div_float — f64 division"],
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
  [0x78,"it·n1", "iter_next1 — iterator step, 1 value"],
  [0x79,"it·n2", "iter_next2 — iterator step, 2 values"],
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
  [0xE1,"igc",   "inc_global_const — global += const in-place (8 bytes)"]
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
| 0x2E–0x3D | 16 | Typed int (i64) |
| 0x3E–0x47 | 10 | Typed float (f64) |
| 0x48–0x51 | 10 | Math intrinsics |
| 0x52–0x57 | 6 | Bitwise |
| 0x58–0x5E | 7 | Cast |
| 0x5F–0x69 | 11 | Type system / assertions |
| 0x6A–0x79 | 16 | Collections / struct |
| 0x7A–0xBF | 70 | Free (reserved for future core ops) |
| 0xC0–0xE1 | 34 | Fused / peephole |
| 0xE2–0xFF | 30 | Free (within fused block) |

Total assigned: 156 of 256 slots.

## Instruction widths

Most opcodes are 1 byte. Multi-byte instructions encode operands immediately
after the opcode byte.

| Width | Examples |
|-------|---------|
| 1 byte | Most arithmetic, comparison, stack ops |
| 2 bytes | `get_local`, `set_local`, `get_upvalue`, `build_array`, … |
| 3 bytes | `constant`, `const_eq/sub/add/lt/gt`, `assert_interface`, … |
| 4 bytes | `call`, `call_tail`, `local_add_const` |
| 5 bytes | `get_local_const_*`, `jump`, `jump_if_false`, `loop`, `get_global`, … |
| 6 bytes | `get_field`, `set_field`, `get_local_const_sub_call`, `close_upvalue_loop` |
| 8 bytes | `get_global_const_*`, `get_local_get_field`, `set_global_loop`, `inc_global_const` |
| 9 bytes | `get_local_const_*_jif_pop`, `local_add_field` |
| 11 bytes | `call_global_local_sub_const` |
| 12 bytes | `get_global_const_lt_jif_pop` |
| 13 bytes | `get_local_const_lt_jif_pop_jump`, `call_global_local_sub_const_tail` |
