pub const Op = enum(u8) {
    // ── Control flow ──────────────────────────────────────────────────────────
    halt             = 0x00, // normal program/function end
    op_unreachable   = 0x01, // dead-code sentinel; traps if reached
    jump             = 0x02,
    jump_if_false    = 0x03,
    jif_pop          = 0x04, // pop condition then jump if falsy
    jump_if_not_null = 0x05, // peek TOS; if not null, jump (value stays); used by ??
    loop             = 0x06,

    // ── Call / return ─────────────────────────────────────────────────────────
    call             = 0x07,
    call_tail        = 0x08, // tail-position call; same encoding as call
    // Spread call: callee has named_return_count >= 2 and the call site destructures
    // the result directly. Layout: [op][argc][spread_n][ic_hi][ic_lo] (5 bytes).
    call_spread      = 0x09,
    defer_call       = 0x0A,
    invoke_method    = 0x0B,
    defer_invoke_method = 0x0C,
    ret              = 0x0D,

    // ── Variables + closure ───────────────────────────────────────────────────
    get_local        = 0x0E,
    set_local        = 0x0F,
    get_global       = 0x10,
    set_global       = 0x11,
    def_global       = 0x12,
    get_upvalue      = 0x13,
    set_upvalue      = 0x14,
    close_upvalue    = 0x15, // u8: local slot — move cell value back to stack, giving next iteration a fresh capture
    make_closure     = 0x16,

    // ── Stack / literals ──────────────────────────────────────────────────────
    constant         = 0x17,
    null_val         = 0x18,
    true_val         = 0x19,
    false_val        = 0x1A,
    dup              = 0x1B,
    dup2             = 0x1C,
    pop              = 0x1D,

    // ── Generic arithmetic ────────────────────────────────────────────────────
    add              = 0x1E,
    sub              = 0x1F,
    mul              = 0x20,
    div              = 0x21,
    int_div          = 0x22,
    rem              = 0x23,
    mod              = 0x24,
    pow              = 0x25,
    neg              = 0x26,

    // ── Generic comparison / logic ────────────────────────────────────────────
    eq               = 0x27,
    ne               = 0x28,
    lt               = 0x29,
    le               = 0x2A,
    gt               = 0x2B,
    ge               = 0x2C,
    not              = 0x2D,

    // ── Typed int (i64) ───────────────────────────────────────────────────────
    add_int          = 0x2E,
    sub_int          = 0x2F,
    mul_int          = 0x30,
    div_int          = 0x31,
    // zero-compare: pop one int, compare against 0
    eqz_int          = 0x32,
    nez_int          = 0x33,
    ltz_int          = 0x34,
    lez_int          = 0x35,
    gtz_int          = 0x36,
    gez_int          = 0x37,
    // general compare: pop two ints
    eq_int           = 0x38,
    ne_int           = 0x39,
    lt_int           = 0x3A,
    le_int           = 0x3B,
    gt_int           = 0x3C,
    ge_int           = 0x3D,

    // ── Typed float (f64) ─────────────────────────────────────────────────────
    add_float        = 0x3E,
    sub_float        = 0x3F,
    mul_float        = 0x40,
    div_float        = 0x41,
    eq_float         = 0x42,
    ne_float         = 0x43,
    lt_float         = 0x44,
    le_float         = 0x45,
    gt_float         = 0x46,
    ge_float         = 0x47,

    // ── Math intrinsics ───────────────────────────────────────────────────────
    abs              = 0x48,
    floor            = 0x49,
    ceil             = 0x4A,
    trunc            = 0x4B,
    nearest          = 0x4C,
    min              = 0x4D,
    max              = 0x4E,
    sign             = 0x4F,
    sqrt             = 0x50,
    clamp            = 0x51,

    // ── Bitwise ───────────────────────────────────────────────────────────────
    bit_and          = 0x52,
    bit_or           = 0x53,
    bit_xor          = 0x54,
    bit_not          = 0x55,
    shl              = 0x56,
    shr              = 0x57,

    // ── Cast ──────────────────────────────────────────────────────────────────
    cast_int         = 0x58,
    cast_float       = 0x59,
    cast_decimal     = 0x5A,
    cast_bool        = 0x5B,
    cast_string      = 0x5C,
    cast_rune        = 0x5D,
    cast_bigint      = 0x5E,

    // ── Type system + assertions ──────────────────────────────────────────────
    assert_type      = 0x5F, // operand byte: 1=array 2=map 3=error
    assert_interface = 0x60, // u16: const index of interface type name
    assert_struct    = 0x61, // u16: const index of struct type name
    type_name        = 0x62, // pops a value, pushes its runtime type name as a string (the `.type` operator)
    set_named_predicate   = 0x63, // pop predicate, set named_type.predicate on TOS
    validate_type_default = 0x64, // if TOS named_type has both a default and a predicate, check the default now
    op_assert        = 0x65,
    op_assert_msg    = 0x66,
    op_trap_check    = 0x67,
    variant_check    = 0x68, // u16 const_idx: pop dup'd value, push bool (tag match)
    variant_payload  = 0x69, // pop variant_value, push payload

    // ── Collections + struct ─────────────────────────────────────────────────
    build_array      = 0x6A,
    build_map        = 0x6B,
    build_tuple      = 0x6C,
    build_struct_instance = 0x6D,
    zero_struct      = 0x6E,
    tuple_check_arity = 0x6F,
    tuple_get        = 0x70,
    tuple_get_keep   = 0x71,
    get_index        = 0x72,
    set_index        = 0x73,
    get_slice        = 0x74,
    get_field        = 0x75, // u16:name_const_idx, u16:ic_type_pool_idx, u8:ic_field_idx — struct field read with inline cache
    set_field        = 0x76, // u16:name_const_idx, u16:ic_type_pool_idx, u8:ic_field_idx — struct field write with inline cache
    iter_init        = 0x77,
    iter_next1       = 0x78,
    iter_next2       = 0x79,

    // 0x7A–0xBF: reserved for future core ops (70 slots)

    // ── Fused / peephole (0xC0–0xFF, 64 slots) ───────────────────────────────
    // Fused constant+binop: reads u16 const_idx, pops TOS (left operand),
    // applies op with the constant as right operand, pushes result.
    const_eq         = 0xC0,
    const_sub        = 0xC1,
    const_add        = 0xC2,
    const_lt         = 0xC3,
    const_gt         = 0xC4,
    // Triple-fused get_local+constant+binop. Same 5-byte layout as
    // get_local(2) + const_eq/sub/add/lt/gt(3). The middle byte (the original const_*
    // opcode, now a skip byte) is read and discarded by the VM.
    get_local_const_eq  = 0xC5,
    get_local_const_sub = 0xC6,
    get_local_const_add = 0xC7,
    get_local_const_lt  = 0xC8,
    get_local_const_gt  = 0xC9,
    // Quad-fused get_local+constant+eq+jif_pop: 9-byte conditional branch.
    // Layout: [op][slot][skip][idx_hi][idx_lo][jmp_hi][jmp_lo]
    get_local_const_eq_jif_pop  = 0xCA,
    // Quad-fused get_local+constant+lt/gt+jif_pop: 9-byte conditional branch.
    // Layout: [op][slot][skip][idx_hi][idx_lo][exit_b3][exit_b2][exit_b1][exit_b0]
    get_local_const_lt_jif_pop  = 0xCB,
    get_local_const_gt_jif_pop  = 0xCC,
    // Quint-fused get_local+constant+lt+jif_pop+jump: 13-byte for-loop header.
    // Layout: [op][slot][skip][idx_hi][idx_lo][exit_b3..b0][body_b3..b0]
    get_local_const_lt_jif_pop_jump = 0xCD,
    // Triple-fused get_global+constant+binop. 8-byte layout:
    // [op][glob_hi][glob_lo][ic_hi][ic_lo][skip][val_hi][val_lo]
    get_global_const_eq  = 0xCE,
    get_global_const_sub = 0xCF,
    get_global_const_add = 0xD0,
    get_global_const_lt  = 0xD1,
    // Quad-fused get_global+constant+lt+jif_pop: 12-byte conditional branch.
    // Layout: [op][glob_hi][glob_lo][ic_hi][ic_lo][skip][val_hi][val_lo][jmp_b3..b0]
    get_global_const_lt_jif_pop = 0xD2,
    // Fused get_local+get_field: 8-byte load-and-read-field.
    // Layout: [op][slot][skip=get_field_byte][name_hi][name_lo][ic_type_hi][ic_type_lo][ic_fidx]
    get_local_get_field  = 0xD3,
    // Fused loop variants
    set_global_loop      = 0xD4, // fused: set_global (5 bytes) + loop back-edge (2 bytes); same IC layout
    close_upvalue_loop   = 0xD5, // fused: close_upvalue (2 bytes) + loop back-edge; layout: [op][slot][off_b3..b0] (6 bytes)
    // Fused ret variants
    ret_const            = 0xD6, // fused constant+ret: [op][idx_hi][idx_lo]
    get_local_ret        = 0xD7, // fused get_local+ret: [op][slot]
    // Fused call variants
    get_local_const_sub_call      = 0xD8, // fused get_local_const_sub+call: [op][slot][skip][idx_hi][idx_lo][argc] (6 bytes)
    get_local_const_sub_call_tail = 0xD9, // tail-position variant; same encoding
    // Hexa-fused get_global+get_local+const+sub+call: 11-byte recursive-call fast path.
    // Layout: [op][name_hi][name_lo][ic_hi][ic_lo][glcs_skip][slot][const_sub_skip][idx_hi][idx_lo][argc]
    call_global_local_sub_const      = 0xDA,
    call_global_local_sub_const_tail = 0xDB, // tail-position variant; same encoding
    // Fused arithmetic
    add_ret          = 0xDC, // fused add+ret: [op]
    local_add_local  = 0xDD, // fused get_local+get_local+add+set_local: [op][dst][src] (3 bytes); dst += src
    local_add_const  = 0xDE, // fused get_local+const_add+set_local: [op][dst][idx_hi][idx_lo] (4 bytes); dst += k
    local_add_const_loop = 0xDF, // fused local_add_const+loop: [op][dst][idx_hi][idx_lo][off_b3..b0] (8 bytes)
    local_add_field  = 0xE0, // fused get_local+get_local_get_field+add+set_local: [op][dst][src][skip][name_hi][name_lo][ic_hi][ic_lo][ic_fidx] (9 bytes); dst += src.field
    // Fused get_global_const_add+set_global (same global): 8-byte in-place global increment.
    // Layout: [op][name_hi][name_lo][ic_hi][ic_lo][add_skip][val_hi][val_lo]
    inc_global_const = 0xE1,
    // 0xE2–0xFF: free within fused block (30 slots)
};
