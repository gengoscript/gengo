pub const Op = enum(u8) {
    constant,
    null_val,
    true_val,
    false_val,
    dup,
    dup2,
    pop,
    def_global,
    get_global,
    set_global,
    get_local,
    set_local,
    get_upvalue,
    set_upvalue,
    close_upvalue,   // u8: local slot — move cell value back to stack, giving next iteration a fresh capture
    add,
    sub,
    mul,
    // Fused constant+binop: reads u16 const_idx, pops TOS (left operand),
    // applies op with the constant as right operand, pushes result.
    // Emitted by the peephole when `constant k` immediately precedes the op.
    const_eq,
    const_sub,
    const_add,
    const_lt,
    // Triple-fused get_local+constant+binop. Same 5-byte layout as
    // get_local(2) + const_eq/sub/add/lt(3). The middle byte (the original const_*
    // opcode, now a skip byte) is read and discarded by the VM.
    // Emitted when get_local immediately precedes a const_eq, const_sub, const_add, or const_lt.
    get_local_const_eq,
    get_local_const_sub,
    get_local_const_add,
    get_local_const_lt,
    // Quad-fused get_local+constant+eq+jif_pop: 7-byte conditional branch.
    // Layout: [op][slot][skip][idx_hi][idx_lo][jmp_hi][jmp_lo]
    // Emitted when get_local_const_eq immediately precedes jif_pop.
    get_local_const_eq_jif_pop,
    // Quad-fused get_local+constant+lt+jif_pop: 7-byte conditional branch.
    // Layout: [op][slot][skip=const_lt_byte][idx_hi][idx_lo][jmp_hi][jmp_lo]
    // Emitted when get_local_const_lt immediately precedes jif_pop.
    get_local_const_lt_jif_pop,
    // Fused get_local+get_field: 8-byte load-and-read-field.
    // Layout: [op][slot][skip=get_field_byte][name_hi][name_lo][ic_type_hi][ic_type_lo][ic_fidx]
    // Emitted when get_local immediately precedes get_field.
    get_local_get_field,
    div,
    mod,
    pow,
    bit_and,
    bit_or,
    bit_xor,
    bit_not,
    shl,
    shr,
    cast_int,
    cast_float,
    cast_decimal,
    cast_bool,
    cast_string,
    cast_rune,
    assert_type, // operand byte: 1=array 2=map 3=error
    neg,
    not,
    eq,
    gt,
    lt,
    build_array,
    build_map,
    build_tuple,
    build_struct_instance,
    tuple_check_arity,
    tuple_get,
    tuple_get_keep,
    get_index,
    set_index,
    get_slice,
    iter_init,
    iter_next1,
    iter_next2,
    make_closure,
    invoke_method,
    jump,
    jump_if_false,
    jif_pop,          // pop condition then jump if it was falsy; used by if/while/for/switch
    loop,
    set_global_loop,  // fused: set_global (5 bytes) + loop back-edge (2 bytes); same IC layout
    set_named_predicate, // pop predicate, set named_type.predicate on TOS
    call,
    defer_call,
    defer_invoke_method,
    op_assert,
    op_assert_msg,
    op_trap_check,
    variant_check,   // u8 const_idx: pop dup'd value, push bool (tag match)
    variant_payload, // pop variant_value, push payload
    get_field,       // u16:name_const_idx, u16:ic_type_pool_idx, u8:ic_field_idx — struct field read with inline cache
    set_field,       // u16:name_const_idx, u16:ic_type_pool_idx, u8:ic_field_idx — struct field write with inline cache
    ret,
    ret_const,       // fused constant+ret: [op][idx_hi][idx_lo]; same 3-byte layout as `constant k`
    repl_print,      // REPL-only: print TOS if not null, then pop
    halt,
};
