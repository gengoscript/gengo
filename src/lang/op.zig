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
    const_gt,
    // Triple-fused get_local+constant+binop. Same 5-byte layout as
    // get_local(2) + const_eq/sub/add/lt/gt(3). The middle byte (the original const_*
    // opcode, now a skip byte) is read and discarded by the VM.
    // Emitted when get_local immediately precedes a const_eq, const_sub, const_add, const_lt, or const_gt.
    get_local_const_eq,
    get_local_const_sub,
    get_local_const_add,
    get_local_const_lt,
    get_local_const_gt,
    // Quad-fused get_local+constant+eq+jif_pop: 9-byte conditional branch.
    // Layout: [op][slot][skip][idx_hi][idx_lo][jmp_hi][jmp_lo]
    // Emitted when get_local_const_eq immediately precedes jif_pop.
    get_local_const_eq_jif_pop,
    // Quad-fused get_local+constant+lt+jif_pop: 9-byte conditional branch.
    // Layout: [op][slot][skip=const_lt_byte][idx_hi][idx_lo][exit_b3][exit_b2][exit_b1][exit_b0]
    // Emitted when get_local_const_lt immediately precedes jif_pop.
    get_local_const_lt_jif_pop,
    // Quad-fused get_local+constant+gt+jif_pop: 9-byte conditional branch.
    // Layout: [op][slot][skip=const_gt_byte][idx_hi][idx_lo][exit_b3][exit_b2][exit_b1][exit_b0]
    // Emitted when get_local_const_gt immediately precedes jif_pop.
    get_local_const_gt_jif_pop,
    // Quint-fused get_local+constant+lt+jif_pop+jump: 13-byte for-loop header.
    // Layout: [op][slot][skip][idx_hi][idx_lo][exit_b3..b0][body_b3..b0]
    // When a < k: ip += body_off (jump to body, past post-increment).
    // When a >= k: ip (at mid, after exit_off read) += exit_off (jump to loop end).
    // Emitted when get_local_const_lt_jif_pop immediately precedes jump.
    get_local_const_lt_jif_pop_jump,
    // Triple-fused get_global+constant+binop. 8-byte layout:
    // [op][glob_hi][glob_lo][ic_hi][ic_lo][skip][val_hi][val_lo]
    // Emitted when get_global immediately precedes a const_eq, const_sub, const_add, or const_lt.
    get_global_const_eq,
    get_global_const_sub,
    get_global_const_add,
    get_global_const_lt,
    // Quad-fused get_global+constant+lt+jif_pop: 12-byte conditional branch.
    // Layout: [op][glob_hi][glob_lo][ic_hi][ic_lo][skip][val_hi][val_lo][jmp_b3][jmp_b2][jmp_b1][jmp_b0]
    // Emitted when get_global_const_lt immediately precedes jif_pop.
    get_global_const_lt_jif_pop,
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
    assert_interface, // u16: const index of interface type name
    assert_struct,    // u16: const index of struct type name
    type_name, // pops a value, pushes its runtime type name as a string (the `.type` operator)
    neg,
    not,
    eq,
    gt,
    lt,
    build_array,
    build_map,
    build_tuple,
    build_struct_instance,
    zero_struct,
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
    close_upvalue_loop, // fused: close_upvalue (2 bytes) + loop back-edge; layout: [op][slot][off_b3..b0] (6 bytes)
    set_named_predicate, // pop predicate, set named_type.predicate on TOS
    validate_type_default, // if TOS named_type has both a default and a predicate, check the default now
    call,
    defer_call,
    defer_invoke_method,
    op_assert,
    op_assert_msg,
    op_trap_check,
    variant_check,   // u16 const_idx: pop dup'd value, push bool (tag match)
    variant_payload, // pop variant_value, push payload
    get_field,       // u16:name_const_idx, u16:ic_type_pool_idx, u8:ic_field_idx — struct field read with inline cache
    set_field,       // u16:name_const_idx, u16:ic_type_pool_idx, u8:ic_field_idx — struct field write with inline cache
    ret,
    ret_const,       // fused constant+ret: [op][idx_hi][idx_lo]; same 3-byte layout as `constant k`
    get_local_ret,   // fused get_local+ret: [op][slot]; same 2-byte layout as `get_local slot`
    get_local_const_sub_call, // fused get_local_const_sub+call: [op][slot][skip][idx_hi][idx_lo][argc] (6 bytes)
    // Hexa-fused get_global+get_local+const+sub+call: 11-byte recursive-call fast path.
    // Layout: [op][name_hi][name_lo][ic_hi][ic_lo][glcs_skip][slot][const_sub_skip][idx_hi][idx_lo][argc]
    // Emitted when get_global immediately precedes get_local_const_sub_call.
    call_global_local_sub_const,
    add_ret,         // fused add+ret: [op]; same 1-byte layout as `add`
    local_add_local, // fused get_local+get_local+add+set_local: [op][dst][src] (3 bytes); dst += src
    local_add_const, // fused get_local+const_add+set_local: [op][dst][idx_hi][idx_lo] (4 bytes); dst += k
    local_add_const_loop, // fused local_add_const+loop: [op][dst][idx_hi][idx_lo][off_b3..b0] (8 bytes)
    // Fused get_global_const_add+set_global (same global): 8-byte in-place global increment.
    // Layout: [op][name_hi][name_lo][ic_hi][ic_lo][add_skip][val_hi][val_lo] (same as get_global_const_add)
    // Emitted when get_global_const_add immediately precedes set_global with the same name.
    inc_global_const,
    repl_print,      // REPL-only: print TOS if not null, then pop
    halt,
};
