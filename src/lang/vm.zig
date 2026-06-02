const std = @import("std");
const chunk = @import("chunk.zig");
const common = @import("common.zig");
const globals = @import("globals.zig");
const heap = @import("../runtime/heap.zig");
const cfg = @import("../runtime/config.zig");
const Op = @import("op.zig").Op;
const Value = @import("value.zig").Value;
const Object = @import("value.zig").Object;
const MapEntry = @import("value.zig").MapEntry;
const IterObj = @import("value.zig").IterObj;
const ClosureObj = @import("value.zig").ClosureObj;

const vms = @import("vm_state.zig");
const vmgc = @import("vm_gc.zig");
const vmmap = @import("vm_map.zig");
const vmstr = @import("vm_string.zig");
const vmtyp = @import("vm_types.zig");
const vmnative = @import("vm_native.zig");
const vmperf = @import("vm_perf.zig");

// ── Public re-exports (external callers import from vm.zig unchanged) ─────────

pub const Policy = vms.Policy;
pub const State = vms.State;
pub const PanicFrame = vms.PanicFrame;
pub const MaxFrames = vms.MaxFrames;

pub const setActive = vms.setActive;
pub const reset = vms.reset;
pub const resetExec = vms.resetExec;
pub const setPolicy = vms.setPolicy;
pub const currentLine = vms.currentLine;
pub const currentCol = vms.currentCol;
pub const panicLine = vms.panicLine;
pub const panicCol = vms.panicCol;
pub const panicFrames = vms.panicFrames;

// ── Aliases for hot-path readability in runInner ──────────────────────────────

fn isModuleNamespaceStruct(typ: *Object) bool {
    return typ.* == .struct_type and std.mem.startsWith(u8, typ.struct_type.qualified_name, "@module_type:");
}

const vmState = vms.vmState;
const vmPush = vms.vmPush;
const vmPop = vms.vmPop;
const vmPeek = vms.vmPeek;
const vmByte = vms.vmByte;
const vmShort = vms.vmShort;
const vmConst = vms.vmConst;
const pushTempRoot = vms.pushTempRoot;
const popTempRoot = vms.popTempRoot;
const vmAllocObject = vmgc.vmAllocObject;
const vmAllocManagedSlice = vmgc.vmAllocManagedSlice;
const makeDynString = vmgc.makeDynString;
const concatDynString = vmgc.concatDynString;

// ── Private helpers used only in the execution core ───────────────────────────

fn namedTypeIsSubOf(sub: *Object, ancestor: *Object) bool {
    var cur = vmtyp.resolveParentType(sub) orelse return false;
    while (true) {
        if (cur == ancestor) return true;
        cur = vmtyp.resolveParentType(cur) orelse return false;
    }
}

fn namedTypeCarrier(a: Value, b: Value) !?*Object {
    var ta: ?*Object = null;
    var tb: ?*Object = null;
    if (a == .object and a.object.* == .named_value) ta = a.object.named_value.typ;
    if (b == .object and b.object.* == .named_value) tb = b.object.named_value.typ;
    if (ta == null and tb == null) return null;
    if (ta == null) return tb;
    if (tb == null) return ta;
    if (ta.? == tb.?) return ta;
    if (namedTypeIsSubOf(ta.?, tb.?)) return tb.?;
    if (namedTypeIsSubOf(tb.?, ta.?)) return ta.?;
    return error.TypeError;
}

fn pushNumericResultWithCarrier(a: Value, b: Value, n: f64) !void {
    const carrier = try namedTypeCarrier(a, b);
    if (carrier) |typ| {
        const wrapped = try vmtyp.constructNamedType(typ, .{ .number = n });
        try vmPush(wrapped);
    } else {
        try vmPush(.{ .number = n });
    }
}

fn prepareVariadicCall(f: @import("value.zig").FuncObj, argc: u8) !void {
    if (!f.is_variadic) return;
    const fixed: usize = f.arity - 1;
    if (argc < fixed) return error.ArityMismatch;
    const start = vmState().stack_top - argc;
    const extra: usize = argc - fixed;
    const arr_obj = try vmAllocObject();
    arr_obj.* = .{ .array = &[_]Value{} }; // safe tag before GC can run
    try pushTempRoot(.{ .object = arr_obj });
    defer popTempRoot();
    const items = try vmAllocManagedSlice(Value, extra);
    var i: usize = 0;
    while (i < extra) : (i += 1) items[i] = vmState().stack[start + fixed + i];
    arr_obj.* = .{ .array_managed = items[0..extra] };
    vmState().stack[start + fixed] = .{ .object = arr_obj };
    vmState().stack_top = start + fixed + 1;
}

fn performCall(argc: u8) !void {
    const func_val = vmState().stack[vmState().stack_top - argc - 1];
    if (func_val != .object) return error.NotAFunction;
    const obj = func_val.object;
    switch (obj.*) {
        .function => |f| {
            if (f.is_variadic) {
                if (argc < f.arity - 1) return error.ArityMismatch;
            } else if (f.arity != argc) return error.ArityMismatch;
            if (f.has_typed_params) try vmtyp.enforceFuncArgTypes(f, argc);
            try prepareVariadicCall(f, argc);
            if (vmState().frame_top >= vms.MaxFrames) return error.CallStackOverflow;
            vmState().frames[vmState().frame_top] = .{
                .ret_ip = vmState().ip,
                .base = vmState().stack_top - f.arity,
                .closure = null,
                .func_obj = obj,
                .defer_base = vmState().defer_top,
                .has_typed_returns = f.has_typed_returns,
            };
            vmState().frame_top += 1;
            vmState().ip = f.ip;
        },
        .closure => |cl| {
            const f = cl.func.function;
            if (f.is_variadic) {
                if (argc < f.arity - 1) return error.ArityMismatch;
            } else if (f.arity != argc) return error.ArityMismatch;
            if (f.has_typed_params) try vmtyp.enforceFuncArgTypes(f, argc);
            try prepareVariadicCall(f, argc);
            if (vmState().frame_top >= vms.MaxFrames) return error.CallStackOverflow;
            vmState().frames[vmState().frame_top] = .{
                .ret_ip = vmState().ip,
                .base = vmState().stack_top - f.arity,
                .closure = obj,
                .func_obj = cl.func,
                .defer_base = vmState().defer_top,
                .has_typed_returns = f.has_typed_returns,
            };
            vmState().frame_top += 1;
            vmState().ip = f.ip;
        },
        .native_function => |nf| {
            try vmnative.callNative(nf, argc);
        },
        .named_type => {
            if (argc != 1) return error.ArityMismatch;
            const arg = vmState().stack[vmState().stack_top - 1];
            const out = try vmtyp.constructNamedType(obj, arg);
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(out);
        },
        .variant_ctor => |vc| {
            if (argc != 1) return error.ArityMismatch;
            const payload = vmState().stack[vmState().stack_top - 1];
            if (vc.payload_type) |pt| {
                if (!vmtyp.matchesTypeSpec(payload, pt)) return error.TypeError;
            }
            const vv = try vmAllocObject();
            vv.* = .{ .variant_value = .{
                .typ = vc.typ,
                .tag = vc.tag,
                .ordinal = vc.ordinal,
                .payload = payload,
            }};
            _ = try vmPop();
            _ = try vmPop();
            try vmPush(.{ .object = vv });
        },
        else => return error.NotAFunction,
    }
}

fn writeFrameLocal(abs_slot: usize, v: Value) void {
    std.debug.assert(abs_slot < vms.MaxStack);
    const cur = vmState().stack[abs_slot];
    if (cur == .object and cur.object.* == .cell) {
        cur.object.cell.value = v;
    } else {
        vmState().stack[abs_slot] = v;
    }
}

fn trySelfTailCall(argc: u8) !bool {
    if (vmState().frame_top == 0) return false;
    // Tail position pattern emitted by compiler: `call <argc>` followed by `ret`.
    if (vmState().ip >= chunk.codeLen()) return false;
    const next_op: Op = @enumFromInt(chunk.codeByteAt(vmState().ip));
    if (next_op != .ret) return false;

    const callee_idx = vmState().stack_top - argc - 1;
    const func_val = vmState().stack[callee_idx];
    if (func_val != .object) return false;
    const callee_obj = func_val.object;

    const frame_idx = vmState().frame_top - 1;
    const frame = vmState().frames[frame_idx];
    if (callee_obj.* == .closure) {
        if (frame.closure == null or frame.closure.? != callee_obj) return false;
        const f = callee_obj.closure.func.function;
        if (f.is_variadic) return false;
        if (f.arity != argc) return false;
        if (f.has_typed_params) try vmtyp.enforceFuncArgTypes(f, argc);
        var i: usize = 0;
        while (i < argc) : (i += 1) {
            writeFrameLocal(frame.base + i, vmState().stack[callee_idx + 1 + i]);
        }
        vmState().stack_top = frame.base + argc;
        vmState().ip = f.ip;
        return true;
    }
    if (callee_obj.* == .function) {
        if (frame.closure != null) return false;
        if (frame.func_obj != callee_obj) return false;
        const f = callee_obj.function;
        if (f.is_variadic) return false;
        if (f.arity != argc) return false;
        if (f.has_typed_params) try vmtyp.enforceFuncArgTypes(f, argc);
        var i: usize = 0;
        while (i < argc) : (i += 1) {
            writeFrameLocal(frame.base + i, vmState().stack[callee_idx + 1 + i]);
        }
        vmState().stack_top = frame.base + argc;
        vmState().ip = f.ip;
        return true;
    }
    return false;
}

fn iterInit(v: Value) !Value {
    const obj = try vmAllocObject();
    const iv = if (v == .object and v.object.* == .named_value) v.object.named_value.value else v;
    switch (iv) {
        .object => |o| switch (o.*) {
            .dyn_string => |s| obj.* = .{ .iterator = .{ .kind = .string, .index = 0, .string = s, .string_managed = true, .source = o } },
            .array, .array_managed => obj.* = .{ .iterator = .{ .kind = .array, .index = 0, .array = vms.asArraySlice(o), .source = o } },
            .map, .map_managed, .map_hashed => obj.* = .{ .iterator = .{ .kind = .map, .index = 0, .map = vms.asMapSlice(o), .source = o } },
            else => return error.TypeError,
        },
        .string => |s| obj.* = .{ .iterator = .{ .kind = .string, .index = 0, .string = s, .string_managed = false } },
        else => return error.TypeError,
    }
    return .{ .object = obj };
}

fn iterNext1(it: *IterObj) !void {
    switch (it.kind) {
        .array => {
            if (it.index >= it.array.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            const v = it.array[it.index];
            it.index += 1;
            try vmPush(v);
            try vmPush(.{ .boolean = true });
        },
        .string => {
            if (it.index >= it.string.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            const ridx = it.rune_index;
            const start = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx);
            const end = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx + 1);
            if (it.string_managed) {
                try vmPush(try makeDynString(it.string[start..end]));
            } else {
                try vmPush(.{ .string = it.string[start..end] });
            }
            it.index = end;
            it.rune_index += 1;
            try vmPush(.{ .boolean = true });
        },
        .map => {
            if (it.index >= it.map.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            const k = it.map[it.index].key;
            it.index += 1;
            try vmPush(k);
            try vmPush(.{ .boolean = true });
        },
    }
}

fn iterNext2(it: *IterObj) !void {
    switch (it.kind) {
        .array => {
            if (it.index >= it.array.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            try vmPush(.{ .number = @floatFromInt(it.index) });
            try vmPush(it.array[it.index]);
            it.index += 1;
            try vmPush(.{ .boolean = true });
        },
        .string => {
            if (it.index >= it.string.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            const ridx = it.rune_index;
            const start = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx);
            const end = try vmstr.utf8ByteOffsetForRuneIndexCached(it.string, ridx + 1);
            try vmPush(.{ .number = @floatFromInt(it.rune_index) });
            if (it.string_managed) {
                try vmPush(try makeDynString(it.string[start..end]));
            } else {
                try vmPush(.{ .string = it.string[start..end] });
            }
            it.index = end;
            it.rune_index += 1;
            try vmPush(.{ .boolean = true });
        },
        .map => {
            if (it.index >= it.map.len) {
                try vmPush(.{ .boolean = false });
                return;
            }
            try vmPush(it.map[it.index].key);
            try vmPush(it.map[it.index].value);
            it.index += 1;
            try vmPush(.{ .boolean = true });
        },
    }
}

// Slow-path return: handles defers and/or typed-return enforcement.
// Returns true if runInner should stop (call_depth_target reached), false to continue.
// Fast-path returns (no defers, no typed returns) are inlined in the ret/ret_const handlers.
fn retSlowPath(retval_in: Value) !bool {
    var retval = retval_in;
    const fi = vmState().frame_top - 1;
    const frame = &vmState().frames[fi];
    try pushTempRoot(retval);
    while (vmState().defer_top > frame.defer_base) {
        vmState().defer_top -= 1;
        const deferred = vmState().defer_stack[vmState().defer_top];
        try pushTempRoot(deferred);
        const arr = vms.asArraySlice(deferred.object);
        if (arr.len > 0) {
            const dargc: u8 = @intCast(arr.len - 1);
            var di: usize = 0;
            while (di < arr.len) : (di += 1) try vmPush(arr[di]);
            const depth_before = vmState().frame_top;
            try performCall(dargc);
            if (vmState().frame_top > depth_before) {
                const prev_target = vmState().call_depth_target;
                vmState().call_depth_target = depth_before;
                defer vmState().call_depth_target = prev_target;
                try run();
            }
            _ = try vmPop();
        }
        popTempRoot();
    }
    const fsig_ret = vmtyp.frameFuncSig(frame.func_obj) catch null;
    if (fsig_ret) |fsig| {
        if (fsig.named_return_count > 0) {
            popTempRoot();
            const nrbase = frame.base + fsig.arity;
            if (fsig.named_return_count == 1) {
                const raw = vmState().stack[nrbase];
                retval = if (raw == .object and raw.object.* == .cell) raw.object.cell.value else raw;
            } else {
                const nrc: usize = fsig.named_return_count;
                const arr_obj = try vmAllocObject();
                arr_obj.* = .{ .array = &[_]Value{} };
                try pushTempRoot(.{ .object = arr_obj });
                const items = try vmAllocManagedSlice(Value, nrc);
                var ri: usize = 0;
                while (ri < nrc) : (ri += 1) {
                    const raw = vmState().stack[nrbase + ri];
                    items[ri] = if (raw == .object and raw.object.* == .cell) raw.object.cell.value else raw;
                }
                arr_obj.* = .{ .array_managed = items[0..nrc] };
                popTempRoot();
                retval = .{ .object = arr_obj };
            }
            try pushTempRoot(retval);
        }
    }
    popTempRoot();
    vmState().frame_top = fi;
    if (frame.has_typed_returns) {
        if (fsig_ret) |fsig| try vmtyp.enforceFuncReturnTypes(fsig, retval);
    }
    vmState().stack_top = frame.base - 1;
    vmState().ip = frame.ret_ip;
    try vmPush(retval);
    if (vmState().call_depth_target) |d| {
        if (vmState().frame_top == d) return true;
    }
    return false;
}

fn runInner() !void {
    while (true) {
        if (vmState().ops_budget_remaining < std.math.maxInt(u64)) {
            if (vmState().ops_budget_remaining == 0) return error.InstructionBudgetExceeded;
            vmState().ops_budget_remaining -= 1;
        }
        const op_raw = try vmByte();
        if (op_raw >= std.meta.fields(Op).len) return error.BadOpcode;
        vmperf.countOp(op_raw);
        const op: Op = @enumFromInt(op_raw);
        switch (op) {
            .constant => try vmPush(try vmConst()),
            .null_val => try vmPush(.null),
            .true_val => try vmPush(.{ .boolean = true }),
            .false_val => try vmPush(.{ .boolean = false }),
            .dup => try vmPush(try vmPeek(0)),
            .dup2 => {
                try vmPush(try vmPeek(1));
                try vmPush(try vmPeek(1));
            },
            .pop => _ = try vmPop(),

            .def_global => {
                const name = (try vmConst()).string;
                try globals.def(name, try vmPop());
            },
            .get_global => {
                const name_idx = try vmShort();
                const ic_base = vmState().ip;
                const ic_slot: u16 = @intCast(try vmShort());
                if (ic_slot != 0xFFFF) {
                    try vmPush(globals.getAt(ic_slot));
                } else {
                    const name = chunk.constAt(name_idx).string;
                    const slot = globals.findSlot(name) orelse return error.NotDefined;
                    chunk.patchByte(ic_base,     @intCast((slot >> 8) & 0xFF));
                    chunk.patchByte(ic_base + 1, @intCast(slot & 0xFF));
                    try vmPush(globals.getAt(slot));
                }
            },
            .set_global => {
                const name_idx = try vmShort();
                const ic_base = vmState().ip;
                const ic_slot: u16 = @intCast(try vmShort());
                const val = try vmPop();
                if (ic_slot != 0xFFFF) {
                    globals.setAt(ic_slot, val);
                } else {
                    const name = chunk.constAt(name_idx).string;
                    const slot = globals.findSlot(name) orelse return error.NotDefined;
                    chunk.patchByte(ic_base,     @intCast((slot >> 8) & 0xFF));
                    chunk.patchByte(ic_base + 1, @intCast(slot & 0xFF));
                    globals.setAt(slot, val);
                }
            },

            .get_local => {
                const slot = try vmByte();
                const base = vmState().frames[vmState().frame_top - 1].base;
                const v = vmState().stack[base + slot];
                if (v == .object and v.object.* == .cell) {
                    try vmPush(v.object.cell.value);
                } else {
                    try vmPush(v);
                }
            },
            .set_local => {
                const slot = try vmByte();
                const base = vmState().frames[vmState().frame_top - 1].base;
                const val = try vmPop();
                const cur = vmState().stack[base + slot];
                if (cur == .object and cur.object.* == .cell) {
                    cur.object.cell.value = val;
                } else {
                    vmState().stack[base + slot] = val;
                }
            },
            .get_upvalue => {
                const idx = try vmByte();
                const frame = vmState().frames[vmState().frame_top - 1];
                const cl = frame.closure orelse return error.TypeError;
                if (cl.* != .closure) return error.TypeError;
                if (idx >= cl.closure.upvalues.len) return error.TypeError;
                const cell = cl.closure.upvalues[idx];
                try vmPush(cell.cell.value);
            },
            .set_upvalue => {
                const idx = try vmByte();
                const frame = vmState().frames[vmState().frame_top - 1];
                const cl = frame.closure orelse return error.TypeError;
                if (cl.* != .closure) return error.TypeError;
                if (idx >= cl.closure.upvalues.len) return error.TypeError;
                const val = try vmPop();
                const cell = cl.closure.upvalues[idx];
                cell.cell.value = val;
            },

            .add => {
                const b = try vmPop();
                const a = try vmPop();
                if (vms.isStringValue(a) and vms.isStringValue(b)) {
                    // a and b are off the Gengo stack; protect them so GC inside
                    // concatDynString can't free their backing bytes before the copy.
                    try pushTempRoot(a);
                    try pushTempRoot(b);
                    const sa = try vms.asStringValue(a);
                    const sb = try vms.asStringValue(b);
                    vmperf.countStringConcat(sa.len + sb.len);
                    const result = concatDynString(sa, sb);
                    popTempRoot();
                    popTempRoot();
                    try vmPush(try result);
                } else {
                    const an = try vms.valueAsNumber(a);
                    const bn = try vms.valueAsNumber(b);
                    try pushNumericResultWithCarrier(a, b, an + bn);
                }
            },
            .sub => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try vms.valueAsNumber(a);
                const bn = try vms.valueAsNumber(b);
                try pushNumericResultWithCarrier(a, b, an - bn);
            },
            .mul => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try vms.valueAsNumber(a);
                const bn = try vms.valueAsNumber(b);
                try pushNumericResultWithCarrier(a, b, an * bn);
            },
            .div => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try vms.valueAsNumber(a);
                const bn = try vms.valueAsNumber(b);
                if (bn == 0.0) return error.DivisionByZero;
                try pushNumericResultWithCarrier(a, b, an / bn);
            },
            .mod => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try vms.valueAsNumber(a);
                const bn = try vms.valueAsNumber(b);
                if (bn == 0.0) return error.DivisionByZero;
                try pushNumericResultWithCarrier(a, b, common.fmod(an, bn));
            },
            .bit_and => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try vms.valueAsInt(a);
                const bn = try vms.valueAsInt(b);
                try pushNumericResultWithCarrier(a, b, @floatFromInt(an & bn));
            },
            .bit_or => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try vms.valueAsInt(a);
                const bn = try vms.valueAsInt(b);
                try pushNumericResultWithCarrier(a, b, @floatFromInt(an | bn));
            },
            .bit_xor => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try vms.valueAsInt(a);
                const bn = try vms.valueAsInt(b);
                try pushNumericResultWithCarrier(a, b, @floatFromInt(an ^ bn));
            },
            .bit_not => {
                const v = try vmPop();
                const n = try vms.valueAsInt(v);
                const result: f64 = @floatFromInt(~n);
                if (v == .object and v.object.* == .named_value) {
                    try vmPush(try vmtyp.constructNamedType(v.object.named_value.typ, .{ .number = result }));
                } else {
                    try vmPush(.{ .number = result });
                }
            },
            .shl => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try vms.valueAsInt(a);
                const bn = try vms.valueAsInt(b);
                if (bn < 0) return error.RangeError;
                const shift: u6 = @intCast(@min(bn, 63));
                try pushNumericResultWithCarrier(a, b, @floatFromInt(an << shift));
            },
            .shr => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try vms.valueAsInt(a);
                const bn = try vms.valueAsInt(b);
                if (bn < 0) return error.RangeError;
                const shift: u6 = @intCast(@min(bn, 63));
                try pushNumericResultWithCarrier(a, b, @floatFromInt(an >> shift));
            },
            .cast_int => {
                const v = vms.unboxNamed(try vmPop());
                switch (v) {
                    .number => |n| try vmPush(.{ .number = @trunc(n) }),
                    .rune => |r| try vmPush(.{ .number = @floatFromInt(r) }),
                    .boolean => |b| try vmPush(.{ .number = if (b) 1 else 0 }),
                    else => return error.TypeError,
                }
            },
            .cast_float => {
                const v = vms.unboxNamed(try vmPop());
                switch (v) {
                    .number => |n| try vmPush(.{ .number = n }),
                    .rune => |r| try vmPush(.{ .number = @floatFromInt(r) }),
                    .boolean => |b| try vmPush(.{ .number = if (b) 1.0 else 0.0 }),
                    else => return error.TypeError,
                }
            },
            .cast_bool => {
                const v = vms.unboxNamed(try vmPop());
                switch (v) {
                    .number => |n| try vmPush(.{ .boolean = n != 0.0 }),
                    .rune => |r| try vmPush(.{ .boolean = r != 0 }),
                    .boolean => |b| try vmPush(.{ .boolean = b }),
                    else => return error.TypeError,
                }
            },
            .cast_string => {
                const v = vms.unboxNamed(try vmPop());
                try vmPush(try vmnative.nativeConvToString(v));
            },
            .cast_rune => {
                const v = vms.unboxNamed(try vmPop());
                const r: u21 = switch (v) {
                    .rune => |rv| rv,
                    .number => |n| blk: {
                        const t = @trunc(n);
                        if (t != n or t < 0 or t > 0x10FFFF) return error.TypeError;
                        break :blk @intFromFloat(t);
                    },
                    else => return error.TypeError,
                };
                try vmPush(.{ .rune = r });
            },
            .assert_type => {
                const tag = try vmByte();
                const v = try vmPeek(0);
                const ok = switch (tag) {
                    1 => v == .object and vms.isArrayObject(v.object),
                    2 => v == .object and vms.isMapObject(v.object),
                    3 => v == .error_value,
                    else => return error.TypeError,
                };
                if (!ok) return error.TypeError;
            },
            .neg => {
                const v = try vmPop();
                const n = try vms.valueAsNumber(v);
                if (v == .object and v.object.* == .named_value) {
                    try vmPush(try vmtyp.constructNamedType(v.object.named_value.typ, .{ .number = -n }));
                } else {
                    try vmPush(.{ .number = -n });
                }
            },
            .not => try vmPush(.{ .boolean = !(try vmPop()).isTruthy() }),
            .eq => {
                const b = try vmPop();
                const a = try vmPop();
                const a_named = a == .object and a.object.* == .named_value;
                const b_named = b == .object and b.object.* == .named_value;
                if (a_named and b_named and a.object.named_value.typ != b.object.named_value.typ) {
                    const ta = a.object.named_value.typ;
                    const tb = b.object.named_value.typ;
                    if (!namedTypeIsSubOf(ta, tb) and !namedTypeIsSubOf(tb, ta)) return error.TypeError;
                }
                // Unwrap named values for cross named-vs-raw comparison
                const ea = if (a_named) a.object.named_value.value else a;
                const eb = if (b_named) b.object.named_value.value else b;
                try vmPush(.{ .boolean = Value.equals(ea, eb) });
            },
            .gt => {
                const b = try vmPop();
                const a = try vmPop();
                const a_named = a == .object and a.object.* == .named_value;
                const b_named = b == .object and b.object.* == .named_value;
                if (a_named and b_named and a.object.named_value.typ != b.object.named_value.typ) {
                    const ta = a.object.named_value.typ;
                    const tb = b.object.named_value.typ;
                    if (!namedTypeIsSubOf(ta, tb) and !namedTypeIsSubOf(tb, ta)) return error.TypeError;
                }
                const an = try vms.valueAsNumber(a);
                const bn = try vms.valueAsNumber(b);
                try vmPush(.{ .boolean = an > bn });
            },
            .lt => {
                const b = try vmPop();
                const a = try vmPop();
                const a_named = a == .object and a.object.* == .named_value;
                const b_named = b == .object and b.object.* == .named_value;
                if (a_named and b_named and a.object.named_value.typ != b.object.named_value.typ) {
                    const ta = a.object.named_value.typ;
                    const tb = b.object.named_value.typ;
                    if (!namedTypeIsSubOf(ta, tb) and !namedTypeIsSubOf(tb, ta)) return error.TypeError;
                }
                const an = try vms.valueAsNumber(a);
                const bn = try vms.valueAsNumber(b);
                try vmPush(.{ .boolean = an < bn });
            },

            // Fused const+op: reads rhs constant, pops lhs from stack.
            .const_eq => {
                const k = chunk.constAt(try vmShort());
                const a = try vmPop();
                const a_named = a == .object and a.object.* == .named_value;
                const k_named = k == .object and k.object.* == .named_value;
                if (a_named and k_named and a.object.named_value.typ != k.object.named_value.typ) {
                    const ta = a.object.named_value.typ;
                    const tk = k.object.named_value.typ;
                    if (!namedTypeIsSubOf(ta, tk) and !namedTypeIsSubOf(tk, ta)) return error.TypeError;
                }
                const ea = if (a_named) a.object.named_value.value else a;
                const ek = if (k_named) k.object.named_value.value else k;
                try vmPush(.{ .boolean = Value.equals(ea, ek) });
            },
            .const_sub => {
                const k = chunk.constAt(try vmShort());
                const a = try vmPop();
                const an = try vms.valueAsNumber(a);
                const kn = try vms.valueAsNumber(k);
                try pushNumericResultWithCarrier(a, k, an - kn);
            },

            // Triple-fused: get_local + constant + eq/sub.
            // Bytecode: [op][slot][skip][idx_hi][idx_lo]
            // The skip byte (was const_eq/sub opcode) is always present in well-formed
            // bytecode; advance IP directly to avoid the bounds check in vmByte().
            .get_local_const_eq => {
                const slot = try vmByte();
                vmState().ip += 1; // skip the embedded const_eq opcode byte
                const k = chunk.constAt(try vmShort());
                const base = vmState().frames[vmState().frame_top - 1].base;
                var a = vmState().stack[base + slot];
                if (a == .object and a.object.* == .cell) a = a.object.cell.value;
                const a_named = a == .object and a.object.* == .named_value;
                const k_named = k == .object and k.object.* == .named_value;
                if (a_named and k_named and a.object.named_value.typ != k.object.named_value.typ) {
                    const ta = a.object.named_value.typ;
                    const tk = k.object.named_value.typ;
                    if (!namedTypeIsSubOf(ta, tk) and !namedTypeIsSubOf(tk, ta)) return error.TypeError;
                }
                const ea = if (a_named) a.object.named_value.value else a;
                const ek = if (k_named) k.object.named_value.value else k;
                try vmPush(.{ .boolean = Value.equals(ea, ek) });
            },
            .get_local_const_sub => {
                const slot = try vmByte();
                vmState().ip += 1; // skip the embedded const_sub opcode byte
                const k = chunk.constAt(try vmShort());
                const base = vmState().frames[vmState().frame_top - 1].base;
                var a = vmState().stack[base + slot];
                if (a == .object and a.object.* == .cell) a = a.object.cell.value;
                const an = try vms.valueAsNumber(a);
                const kn = try vms.valueAsNumber(k);
                try pushNumericResultWithCarrier(a, k, an - kn);
            },

            // Quad-fused: get_local + constant + eq + jif_pop.
            // Bytecode: [op][slot][skip][idx_hi][idx_lo][jmp_hi][jmp_lo]
            // Reads offset first (advancing IP past the full instruction), then branches.
            .get_local_const_eq_jif_pop => {
                const slot = try vmByte();
                vmState().ip += 1; // skip
                const k = chunk.constAt(try vmShort());
                const off = try vmShort();
                const base = vmState().frames[vmState().frame_top - 1].base;
                var a = vmState().stack[base + slot];
                if (a == .object and a.object.* == .cell) a = a.object.cell.value;
                const a_named = a == .object and a.object.* == .named_value;
                const k_named = k == .object and k.object.* == .named_value;
                if (a_named and k_named and a.object.named_value.typ != k.object.named_value.typ) {
                    const ta = a.object.named_value.typ;
                    const tk = k.object.named_value.typ;
                    if (!namedTypeIsSubOf(ta, tk) and !namedTypeIsSubOf(tk, ta)) return error.TypeError;
                }
                const ea = if (a_named) a.object.named_value.value else a;
                const ek = if (k_named) k.object.named_value.value else k;
                if (!Value.equals(ea, ek)) vmState().ip += off;
            },

            // Quad-fused: get_local + const_lt + jif_pop.
            // Bytecode: [op][slot][skip][idx_hi][idx_lo][jmp_hi][jmp_lo]
            .get_local_const_lt_jif_pop => {
                const slot = try vmByte();
                vmState().ip += 1; // skip embedded const_lt opcode byte
                const k = chunk.constAt(try vmShort());
                const off = try vmShort();
                const base = vmState().frames[vmState().frame_top - 1].base;
                var a = vmState().stack[base + slot];
                if (a == .object and a.object.* == .cell) a = a.object.cell.value;
                const a_named = a == .object and a.object.* == .named_value;
                const k_named = k == .object and k.object.* == .named_value;
                if (a_named and k_named and a.object.named_value.typ != k.object.named_value.typ) {
                    const ta = a.object.named_value.typ;
                    const tk = k.object.named_value.typ;
                    if (!namedTypeIsSubOf(ta, tk) and !namedTypeIsSubOf(tk, ta)) return error.TypeError;
                }
                const an = try vms.valueAsNumber(if (a_named) a.object.named_value.value else a);
                const kn = try vms.valueAsNumber(if (k_named) k.object.named_value.value else k);
                if (!(an < kn)) vmState().ip += off;
            },

            // Fused: get_local + get_field. 8-byte layout:
            // [op][slot][skip=get_field_byte][name_hi][name_lo][ic_type_hi][ic_type_lo][ic_fidx]
            .get_local_get_field => {
                const slot = try vmByte();
                vmState().ip += 1; // skip embedded get_field opcode byte
                const name_idx = try vmShort();
                const ic_base = vmState().ip;
                const ic_type_idx = try vmShort();
                const ic_fidx = try vmByte();
                const frame_base = vmState().frames[vmState().frame_top - 1].base;
                var raw = vmState().stack[frame_base + slot];
                if (raw == .object and raw.object.* == .cell) raw = raw.object.cell.value;
                const container = if (raw == .object and raw.object.* == .named_value)
                    raw.object.named_value.value
                else
                    raw;
                if (container != .object) return error.TypeError;
                const obj = container.object;
                switch (obj.*) {
                    .struct_instance => |inst| {
                        const tpi = heap.objectPoolIndex(inst.typ);
                        if (ic_type_idx == @as(usize, tpi) and ic_fidx != 0xFF) {
                            try vmPush(inst.fields[ic_fidx].value);
                        } else {
                            const name = chunk.constAt(name_idx).string;
                            const fi = vmtyp.findFieldIndex(inst.typ.struct_type.fields, name) orelse return error.UnknownStructField;
                            if (fi <= 0xFE) {
                                chunk.patchByte(ic_base,     @intCast((tpi >> 8) & 0xFF));
                                chunk.patchByte(ic_base + 1, @intCast(tpi & 0xFF));
                                chunk.patchByte(ic_base + 2, @intCast(fi));
                            }
                            try vmPush(inst.fields[fi].value);
                        }
                    },
                    .map, .map_managed => {
                        const name = chunk.constAt(name_idx).string;
                        const items = vms.asMapSlice(obj);
                        const key_v = Value{ .string = name };
                        var i: usize = 0;
                        while (i < items.len) : (i += 1) {
                            if (vmmap.mapKeyEquals(items[i].key, key_v)) {
                                try vmPush(items[i].value);
                                break;
                            }
                        }
                        if (i == items.len) try vmPush(.null);
                    },
                    .map_hashed => |hm| {
                        const name = chunk.constAt(name_idx).string;
                        const key_v = Value{ .string = name };
                        if (vmmap.mapFindHashedIndex(hm.entries[0..hm.len], hm.buckets, key_v)) |fi| {
                            try vmPush(hm.entries[fi].value);
                        } else {
                            try vmPush(.null);
                        }
                    },
                    .enum_type => |et| {
                        const name = chunk.constAt(name_idx).string;
                        if (common.streq(name, "name")) {
                            try vmPush(.{ .string = et.name });
                        } else if (common.streq(name, "first")) {
                            if (et.members.len == 0) return error.IndexOutOfBounds;
                            const ev = try vmAllocObject();
                            ev.* = .{ .enum_value = .{ .typ = obj, .name = et.members[0], .ordinal = 0 } };
                            try vmPush(.{ .object = ev });
                        } else if (common.streq(name, "last")) {
                            if (et.members.len == 0) return error.IndexOutOfBounds;
                            const last_i = et.members.len - 1;
                            const ev = try vmAllocObject();
                            ev.* = .{ .enum_value = .{ .typ = obj, .name = et.members[last_i], .ordinal = @intCast(last_i) } };
                            try vmPush(.{ .object = ev });
                        } else if (common.streq(name, "values")) {
                            const arr_obj = try vmAllocObject();
                            arr_obj.* = .{ .array = &[_]Value{} };
                            try pushTempRoot(.{ .object = arr_obj });
                            defer popTempRoot();
                            const items = try vmAllocManagedSlice(Value, et.members.len);
                            var ei: usize = 0;
                            while (ei < et.members.len) : (ei += 1) {
                                const ev = try vmAllocObject();
                                ev.* = .{ .enum_value = .{ .typ = obj, .name = et.members[ei], .ordinal = @intCast(ei) } };
                                items[ei] = .{ .object = ev };
                                arr_obj.* = .{ .array_managed = items[0 .. ei + 1] };
                            }
                            try vmPush(.{ .object = arr_obj });
                        } else {
                            var ei: usize = 0;
                            while (ei < et.members.len) : (ei += 1) {
                                if (common.streq(et.members[ei], name)) {
                                    const ev = try vmAllocObject();
                                    ev.* = .{ .enum_value = .{ .typ = obj, .name = et.members[ei], .ordinal = @intCast(ei) } };
                                    try vmPush(.{ .object = ev });
                                    break;
                                }
                            }
                            if (ei == et.members.len) return error.UnknownStructField;
                        }
                    },
                    .named_type => |nt| {
                        const name = chunk.constAt(name_idx).string;
                        if (common.streq(name, "name")) {
                            try vmPush(.{ .string = nt.name });
                        } else if (common.streq(name, "first")) {
                            if (!nt.has_range) return error.TypeError;
                            try vmPush(try vmtyp.makeNamedValue(obj, .{ .number = nt.min }));
                        } else if (common.streq(name, "last")) {
                            if (!nt.has_range) return error.TypeError;
                            try vmPush(try vmtyp.makeNamedValue(obj, .{ .number = nt.max }));
                        } else return error.UnknownStructField;
                    },
                    .variant_type => |vt| {
                        const name = chunk.constAt(name_idx).string;
                        if (common.streq(name, "name")) {
                            try vmPush(.{ .string = vt.name });
                        } else {
                            var vi: usize = 0;
                            while (vi < vt.arms.len) : (vi += 1) {
                                if (common.streq(vt.arms[vi].name, name)) {
                                    const arm = vt.arms[vi];
                                    if (arm.has_payload) {
                                        const ctor = try vmAllocObject();
                                        ctor.* = .{ .variant_ctor = .{
                                            .typ = obj,
                                            .tag = arm.name,
                                            .ordinal = vi,
                                            .payload_type = arm.payload_type,
                                        }};
                                        try vmPush(.{ .object = ctor });
                                    } else {
                                        const vv = try vmAllocObject();
                                        vv.* = .{ .variant_value = .{
                                            .typ = obj,
                                            .tag = arm.name,
                                            .ordinal = vi,
                                            .payload = .null,
                                        }};
                                        try vmPush(.{ .object = vv });
                                    }
                                    break;
                                }
                            }
                            if (vi == vt.arms.len) return error.UnknownStructField;
                        }
                    },
                    else => return error.TypeError,
                }
            },

            .const_add => {
                const k = chunk.constAt(try vmShort());
                const a = try vmPop();
                if (vms.isStringValue(a) and vms.isStringValue(k)) {
                    const sk = try vms.asStringValue(k);
                    const state = vmState();
                    const acc = &state.str_acc;
                    // An acc view is a .string whose ptr equals &str_acc[0].
                    // Using pointer identity avoids any per-byte scan.
                    const is_acc = (a == .string) and (state.str_acc_len > 0) and
                        (@intFromPtr(a.string.ptr) == @intFromPtr(&acc[0]));
                    const sa: []const u8 = if (is_acc) acc[0..state.str_acc_len] else try vms.asStringValue(a);
                    const new_len = sa.len + sk.len;
                    if (new_len <= acc.len) {
                        // Fast path: accumulate in the buffer, push a .string view.
                        if (!is_acc) @memcpy(acc[0..sa.len], sa);
                        @memcpy(acc[sa.len..new_len], sk);
                        state.str_acc_len = new_len;
                        vmperf.countStringConcat(new_len);
                        try vmPush(.{ .string = acc[0..new_len] });
                        // Lookahead: if next op is not const_add, promote now so
                        // callers never observe a .string pointing into the acc buffer.
                        const next = if (state.ip < chunk.codeLen()) chunk.codeByteAt(state.ip) else 0xff;
                        if (next != @intFromEnum(Op.const_add)) {
                            _ = try vmPop();
                            const result = try makeDynString(acc[0..new_len]);
                            state.str_acc_len = 0;
                            try vmPush(result);
                        }
                    } else {
                        // acc too small (very long chain): alloc normally.
                        // sa points to acc or to a GC object; neither needs a temp root here
                        // because acc is VM-static and GC strings in the const pool are traced.
                        const result = try concatDynString(sa, sk);
                        state.str_acc_len = 0;
                        try vmPush(result);
                    }
                } else {
                    const an = try vms.valueAsNumber(a);
                    const kn = try vms.valueAsNumber(k);
                    try pushNumericResultWithCarrier(a, k, an + kn);
                }
            },
            .const_lt => {
                const k = chunk.constAt(try vmShort());
                const a = try vmPop();
                const a_named = a == .object and a.object.* == .named_value;
                const k_named = k == .object and k.object.* == .named_value;
                if (a_named and k_named and a.object.named_value.typ != k.object.named_value.typ) {
                    const ta = a.object.named_value.typ;
                    const tk = k.object.named_value.typ;
                    if (!namedTypeIsSubOf(ta, tk) and !namedTypeIsSubOf(tk, ta)) return error.TypeError;
                }
                const an = try vms.valueAsNumber(a);
                const kn = try vms.valueAsNumber(k);
                try vmPush(.{ .boolean = an < kn });
            },

            .build_array => {
                const count = try vmByte();
                const obj = try vmAllocObject();
                obj.* = .{ .array = &[_]Value{} }; // must init before temp root: GC may run during slice alloc
                try pushTempRoot(.{ .object = obj });
                defer popTempRoot();
                const items = try vmAllocManagedSlice(Value, count);
                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    items[i] = try vmPop();
                }
                obj.* = .{ .array_managed = items[0..count] };
                try vmPush(.{ .object = obj });
            },
            .build_map => {
                const count = try vmByte();
                const obj = try vmAllocObject();
                obj.* = .{ .map = &[_]MapEntry{} }; // must init before temp root: GC may run during slice alloc
                try pushTempRoot(.{ .object = obj });
                defer popTempRoot();
                const items = try vmAllocManagedSlice(MapEntry, count);
                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    const val = try vmPop();
                    const key = try vmPop();
                    items[i] = .{ .key = key, .value = val };
                }
                // Point obj at items before allocating buckets so GC can trace the entries
                // (they are no longer on the stack after vmPop above).
                obj.* = .{ .map = items[0..count] };
                const bcount = vmmap.mapBucketsForCount(count);
                const buckets = try vmAllocManagedSlice(i32, bcount);
                vmmap.mapBuildHashedBuckets(items[0..count], buckets);
                obj.* = .{ .map_hashed = .{ .entries = items[0..count], .len = count, .buckets = buckets } };
                try vmPush(.{ .object = obj });
            },
            .build_tuple => {
                const count = try vmByte();
                const obj = try vmAllocObject();
                obj.* = .{ .array = &[_]Value{} }; // must init before temp root: GC may run during slice alloc
                try pushTempRoot(.{ .object = obj });
                defer popTempRoot();
                const items = try vmAllocManagedSlice(Value, count);
                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    items[i] = try vmPop();
                }
                obj.* = .{ .array_managed = items[0..count] };
                try vmPush(.{ .object = obj });
            },
            .build_struct_instance => {
                const count = try vmByte();
                // Peek at the struct type below the count*2 key-value pairs.
                const typ_stack_dist = @as(usize, count) * 2;
                if (vmState().stack_top <= typ_stack_dist) return error.StackUnderflow;
                const typ_peek = vmState().stack[vmState().stack_top - 1 - typ_stack_dist];
                if (typ_peek != .object or typ_peek.object.* != .struct_type) return error.TypeError;
                const st = typ_peek.object.struct_type;
                if (st.fields.len > 255) return error.TooManyStructFields;

                // Allocate managed field storage and the object while all values are still on
                // the stack so GC (if triggered) can trace them as roots. No heap temporaries
                // are used — key-value pairs are read directly from their stack positions.
                const inst_fields = try vmAllocManagedSlice(MapEntry, st.fields.len);
                const obj = try vmAllocObject();
                try pushTempRoot(.{ .object = obj });
                defer popTempRoot();
                obj.* = .{ .array = &[_]Value{} }; // valid placeholder until finalised below

                // key-value pairs occupy stack[base .. base + count*2); type is at base-1.
                const base = vmState().stack_top - typ_stack_dist;
                var seen: [255]bool = [_]bool{false} ** 255;
                var ci: usize = 0;
                while (ci < count) : (ci += 1) {
                    const key = vmState().stack[base + ci * 2];
                    const val = vmState().stack[base + ci * 2 + 1];
                    const key_s = try vms.asStringValue(key);
                    const idx = vmtyp.findFieldIndex(st.fields, key_s) orelse return error.UnknownStructField;
                    if (seen[idx]) return error.DuplicateField;
                    seen[idx] = true;
                    if (!vmtyp.matchesFieldType(val, st.fields[idx])) return error.StructFieldTypeMismatch;
                    inst_fields[idx] = .{ .key = .{ .string = st.fields[idx].name }, .value = val };
                }

                var mi: usize = 0;
                while (mi < st.fields.len) : (mi += 1) {
                    if (!seen[mi]) return error.MissingStructField;
                }

                // Discard type + key-value pairs from the stack in one step.
                vmState().stack_top -= typ_stack_dist + 1;

                obj.* = .{
                    .struct_instance = .{ .typ = typ_peek.object, .fields = inst_fields },
                };
                try vmPush(.{ .object = obj });
            },
            .tuple_check_arity => {
                const expect = try vmByte();
                const tup = try vmPeek(0);
                if (tup != .object or !vms.isArrayObject(tup.object)) return error.TypeError;
                if (vms.asArraySlice(tup.object).len != expect) return error.ArityMismatch;
            },
            .tuple_get => {
                const idx = try vmByte();
                const tup = try vmPop();
                if (tup != .object or !vms.isArrayObject(tup.object)) return error.TypeError;
                const a = vms.asArraySlice(tup.object);
                if (idx >= a.len) return error.ArityMismatch;
                try vmPush(a[idx]);
            },
            .tuple_get_keep => {
                const idx = try vmByte();
                const tup = try vmPeek(0);
                if (tup != .object or !vms.isArrayObject(tup.object)) return error.TypeError;
                const a = vms.asArraySlice(tup.object);
                if (idx >= a.len) return error.ArityMismatch;
                try vmPush(a[idx]);
            },
            .get_index => {
                const idx_v = try vmPop();
                const raw = try vmPop();
                const container = if (raw == .object and raw.object.* == .named_value)
                    raw.object.named_value.value
                else
                    raw;
                switch (container) {
                    .object => |obj| switch (obj.*) {
                        .dyn_string => |s| {
                            const ridx = try vms.vmIndexFromVal(idx_v);
                            const start = try vmstr.utf8ByteOffsetForRuneIndexCached(s, ridx);
                            const w = try vmstr.utf8NextRuneByteLen(s, start);
                            try vmPush(try makeDynString(s[start .. start + w]));
                        },
                        .array, .array_managed => {
                            const items = vms.asArraySlice(obj);
                            const idx = try vms.vmIndexFromVal(idx_v);
                            if (idx >= items.len) return error.IndexOutOfBounds;
                            try vmPush(items[idx]);
                        },
                        .map, .map_managed => {
                            const items = vms.asMapSlice(obj);
                            var i: usize = 0;
                            while (i < items.len) : (i += 1) {
                                if (vmmap.mapKeyEquals(items[i].key, idx_v)) {
                                    try vmPush(items[i].value);
                                    break;
                                }
                            }
                            if (i == items.len) try vmPush(.null);
                        },
                        .map_hashed => |hm| {
                            if (vmmap.mapFindHashedIndex(hm.entries[0..hm.len], hm.buckets, idx_v)) |fi| {
                                try vmPush(hm.entries[fi].value);
                            } else {
                                try vmPush(.null);
                            }
                        },
                        .struct_instance => |inst| {
                            const key = try vms.asStringValue(idx_v);
                            const idx = vmtyp.findFieldIndex(inst.typ.struct_type.fields, key) orelse return error.UnknownStructField;
                            try vmPush(inst.fields[idx].value);
                        },
                        .enum_type => |et| {
                            const key = try vms.asStringValue(idx_v);
                            if (common.streq(key, "name")) {
                                try vmPush(.{ .string = et.name });
                            } else if (common.streq(key, "first")) {
                                if (et.members.len == 0) return error.IndexOutOfBounds;
                                const ev = try vmAllocObject();
                                ev.* = .{ .enum_value = .{ .typ = obj, .name = et.members[0], .ordinal = 0 } };
                                try vmPush(.{ .object = ev });
                            } else if (common.streq(key, "last")) {
                                if (et.members.len == 0) return error.IndexOutOfBounds;
                                const last = et.members.len - 1;
                                const ev = try vmAllocObject();
                                ev.* = .{ .enum_value = .{ .typ = obj, .name = et.members[last], .ordinal = @intCast(last) } };
                                try vmPush(.{ .object = ev });
                            } else if (common.streq(key, "values")) {
                                const arr_obj = try vmAllocObject();
                                arr_obj.* = .{ .array = &[_]Value{} };
                                try pushTempRoot(.{ .object = arr_obj });
                                defer popTempRoot();
                                const items = try vmAllocManagedSlice(Value, et.members.len);
                                var ei: usize = 0;
                                while (ei < et.members.len) : (ei += 1) {
                                    const ev = try vmAllocObject();
                                    ev.* = .{ .enum_value = .{ .typ = obj, .name = et.members[ei], .ordinal = @intCast(ei) } };
                                    items[ei] = .{ .object = ev };
                                    arr_obj.* = .{ .array_managed = items[0 .. ei + 1] };
                                }
                                try vmPush(.{ .object = arr_obj });
                            } else {
                                var ei: usize = 0;
                                while (ei < et.members.len) : (ei += 1) {
                                    if (common.streq(et.members[ei], key)) {
                                        const ev = try vmAllocObject();
                                        ev.* = .{ .enum_value = .{ .typ = obj, .name = et.members[ei], .ordinal = @intCast(ei) } };
                                        try vmPush(.{ .object = ev });
                                        break;
                                    }
                                }
                                if (ei == et.members.len) return error.UnknownStructField;
                            }
                        },
                        .named_type => |nt| {
                            const key = try vms.asStringValue(idx_v);
                            if (common.streq(key, "name")) {
                                try vmPush(.{ .string = nt.name });
                            } else if (common.streq(key, "first")) {
                                if (!nt.has_range) return error.TypeError;
                                try vmPush(try vmtyp.makeNamedValue(obj, .{ .number = nt.min }));
                            } else if (common.streq(key, "last")) {
                                if (!nt.has_range) return error.TypeError;
                                try vmPush(try vmtyp.makeNamedValue(obj, .{ .number = nt.max }));
                            } else return error.UnknownStructField;
                        },
                        .variant_type => |vt| {
                            const key = try vms.asStringValue(idx_v);
                            if (common.streq(key, "name")) {
                                try vmPush(.{ .string = vt.name });
                            } else {
                                var vi: usize = 0;
                                while (vi < vt.arms.len) : (vi += 1) {
                                    if (common.streq(vt.arms[vi].name, key)) {
                                        const arm = vt.arms[vi];
                                        if (arm.has_payload) {
                                            const ctor = try vmAllocObject();
                                            ctor.* = .{ .variant_ctor = .{
                                                .typ = obj,
                                                .tag = arm.name,
                                                .ordinal = vi,
                                                .payload_type = arm.payload_type,
                                            }};
                                            try vmPush(.{ .object = ctor });
                                        } else {
                                            const vv = try vmAllocObject();
                                            vv.* = .{ .variant_value = .{
                                                .typ = obj,
                                                .tag = arm.name,
                                                .ordinal = vi,
                                                .payload = .null,
                                            }};
                                            try vmPush(.{ .object = vv });
                                        }
                                        break;
                                    }
                                }
                                if (vi == vt.arms.len) return error.UnknownStructField;
                            }
                        },
                        else => return error.TypeError,
                    },
                    .string => |s| {
                        const ridx = try vms.vmIndexFromVal(idx_v);
                        const start = try vmstr.utf8ByteOffsetForRuneIndexCached(s, ridx);
                        const w = try vmstr.utf8NextRuneByteLen(s, start);
                        try vmPush(.{ .string = s[start .. start + w] });
                    },
                    else => return error.TypeError,
                }
            },
            .set_index => {
                const val = try vmPop();
                const idx_v = try vmPop();
                const raw_c = try vmPop();
                // Unbox named collection; enforce element/key/value type constraints
                const is_named_c = raw_c == .object and raw_c.object.* == .named_value;
                const container = if (is_named_c) raw_c.object.named_value.value else raw_c;
                if (is_named_c) {
                    const nv = raw_c.object.named_value;
                    if (nv.typ.* == .named_type) {
                        const nt = nv.typ.named_type;
                        if (nt.base == .array_t) {
                            if (nt.elem_spec) |es| {
                                if (!vmtyp.matchesTypeSpec(val, es)) return error.TypeError;
                            }
                        } else if (nt.base == .map_t) {
                            if (nt.key_spec) |ks| {
                                if (!vmtyp.matchesTypeSpec(idx_v, ks)) return error.TypeError;
                            }
                            if (nt.val_spec) |vs| {
                                if (!vmtyp.matchesTypeSpec(val, vs)) return error.TypeError;
                            }
                        }
                    }
                }
                if (container != .object) return error.TypeError;
                switch (container.object.*) {
                    .array, .array_managed => {
                        const items = vms.asArraySlice(container.object);
                        const idx = try vms.vmIndexFromVal(idx_v);
                        if (idx >= items.len) return error.IndexOutOfBounds;
                        items[idx] = val;
                    },
                    .map, .map_managed => {
                        const items = vms.asMapSlice(container.object);
                        var i: usize = 0;
                        var updated = false;
                        while (i < items.len) : (i += 1) {
                            if (vmmap.mapKeyEquals(items[i].key, idx_v)) {
                                items[i].value = val;
                                updated = true;
                                break;
                            }
                        }
                        if (!updated) {
                            try pushTempRoot(container);
                            defer popTempRoot();
                            const ext = try vmAllocManagedSlice(MapEntry, items.len + 1);
                            @memcpy(ext[0..items.len], items);
                            ext[items.len] = .{ .key = idx_v, .value = val };
                            const new_len = items.len + 1;
                            container.object.* = .{ .map_managed = ext[0..new_len] };
                            // Auto-promote to hashed map once linear scan becomes expensive.
                            if (new_len > 8) {
                                const bcount = vmmap.mapBucketsForCount(new_len);
                                const buckets = try vmAllocManagedSlice(i32, bcount);
                                vmmap.mapBuildHashedBuckets(ext[0..new_len], buckets);
                                container.object.* = .{ .map_hashed = .{ .entries = ext[0..new_len], .len = new_len, .buckets = buckets } };
                            }
                        }
                    },
                    .map_hashed => {
                        try vmmap.mapInsertHashed(container.object, idx_v, val);
                    },
                    .struct_instance => |inst| {
                        const key = try vms.asStringValue(idx_v);
                        const idx = vmtyp.findFieldIndex(inst.typ.struct_type.fields, key) orelse return error.UnknownStructField;
                        if (inst.typ.struct_type.fields[idx].is_const) return error.AssignToConst;
                        if (!vmtyp.matchesFieldType(val, inst.typ.struct_type.fields[idx])) return error.StructFieldTypeMismatch;
                        inst.fields[idx].value = val;
                    },
                    else => return error.TypeError,
                }
            },
            .get_slice => {
                const flags = try vmByte();
                const has_start = (flags & 0b01) != 0;
                const has_end = (flags & 0b10) != 0;

                var end_v: Value = .null;
                var start_v: Value = .null;
                if (has_end) end_v = try vmPop();
                if (has_start) start_v = try vmPop();
                const container = try vmPop();

                switch (container) {
                    .string => |s| {
                        const rune_len = try vmstr.utf8RuneCountCached(s);
                        const start_r: usize = if (has_start) try vms.vmSliceIndex(start_v, rune_len) else 0;
                        const end_r: usize = if (has_end) try vms.vmSliceIndex(end_v, rune_len) else rune_len;
                        if (start_r > end_r) return error.IndexOutOfBounds;
                        const start_b = try vmstr.utf8ByteOffsetForRuneIndexCached(s, start_r);
                        const end_b = try vmstr.utf8ByteOffsetForRuneIndexCached(s, end_r);
                        try vmPush(.{ .string = s[start_b..end_b] });
                    },
                    .object => |obj| switch (obj.*) {
                        .dyn_string => |s| {
                            const rune_len = try vmstr.utf8RuneCountCached(s);
                            const start_r: usize = if (has_start) try vms.vmSliceIndex(start_v, rune_len) else 0;
                            const end_r: usize = if (has_end) try vms.vmSliceIndex(end_v, rune_len) else rune_len;
                            if (start_r > end_r) return error.IndexOutOfBounds;
                            const start_b = try vmstr.utf8ByteOffsetForRuneIndexCached(s, start_r);
                            const end_b = try vmstr.utf8ByteOffsetForRuneIndexCached(s, end_r);
                            try vmPush(try makeDynString(s[start_b..end_b]));
                        },
                        .array, .array_managed => {
                            const items = vms.asArraySlice(obj);
                            const start: usize = if (has_start) try vms.vmSliceIndex(start_v, items.len) else 0;
                            const end: usize = if (has_end) try vms.vmSliceIndex(end_v, items.len) else items.len;
                            if (start > end) return error.IndexOutOfBounds;
                            const out = try vmAllocObject();
                            out.* = .{ .array = items[start..end] };
                            try vmPush(.{ .object = out });
                        },
                        else => return error.TypeError,
                    },
                    else => return error.TypeError,
                }
            },
            .import_std => {
                const std_obj = try vmnative.buildStdModule();
                try vmPush(.{ .object = std_obj });
            },
            .iter_init => {
                const v = try vmPop();
                try vmPush(try iterInit(v));
            },
            .iter_next1 => {
                const itv = try vmPeek(0);
                if (itv != .object or itv.object.* != .iterator) return error.TypeError;
                try iterNext1(&itv.object.iterator);
            },
            .iter_next2 => {
                const itv = try vmPeek(0);
                if (itv != .object or itv.object.* != .iterator) return error.TypeError;
                try iterNext2(&itv.object.iterator);
            },
            .make_closure => {
                const f = try vmConst();
                if (f != .object or f.object.* != .function) return error.TypeError;
                const proto = f.object.function;
                const ups = heap.bump(*Object, proto.capture_slots.len) orelse return error.OutOfMemory;
                if (vmState().frame_top == 0 and proto.capture_slots.len != 0) return error.TypeError;
                const frame = if (vmState().frame_top == 0) vms.Frame{ .ret_ip = 0, .base = 0, .closure = null, .func_obj = f.object, .defer_base = 0, .has_typed_returns = false } else vmState().frames[vmState().frame_top - 1];
                var i: usize = 0;
                while (i < proto.capture_slots.len) : (i += 1) {
                    const enc = proto.capture_slots[i];
                    const is_upvalue = (enc & 0x80) != 0;
                    const idx = enc & 0x7f;
                    if (is_upvalue) {
                        const pcl = frame.closure orelse return error.TypeError;
                        if (pcl.* != .closure) return error.TypeError;
                        if (idx >= pcl.closure.upvalues.len) return error.TypeError;
                        ups[i] = pcl.closure.upvalues[idx];
                    } else {
                        const abs = frame.base + idx;
                        const cur = vmState().stack[abs];
                        if (cur == .object and cur.object.* == .cell) {
                            ups[i] = cur.object;
                            continue;
                        }
                        const cell = try vmAllocObject();
                        cell.* = .{ .cell = .{ .value = cur } };
                        vmState().stack[abs] = .{ .object = cell };
                        ups[i] = cell;
                    }
                }
                const clo = try vmAllocObject();
                clo.* = .{ .closure = ClosureObj{ .func = f.object, .upvalues = ups[0..proto.capture_slots.len] } };
                try vmPush(.{ .object = clo });
            },
            .invoke_method => {
                const mname = (try vmConst()).string;
                const argc = try vmByte();
                const ic_base = vmState().ip;
                const ic_type_idx = try vmShort(); // ic_type pool index (0xFFFF = cold)
                const ic_func_idx = try vmShort(); // ic_func pool index (0xFFFF = cold)
                const recv_idx = vmState().stack_top - argc - 1;
                const recv = vmState().stack[recv_idx];
                if (recv != .object) return error.NotAMethodReceiver;
                switch (recv.object.*) {
                    .struct_instance => |inst| {
                        const tpi = heap.objectPoolIndex(inst.typ);
                        var func: Value = undefined;
                        var pass_recv = true;
                        if (ic_type_idx == @as(usize, tpi) and ic_func_idx != 0xFFFF) {
                            func = .{ .object = heap.objectAt(@intCast(ic_func_idx)) };
                        } else {
                            const tname = inst.typ.struct_type.qualified_name;
                            const total = tname.len + 1 + mname.len;
                            if (total > 512) return error.NotAMethodReceiver;
                            var key_buf: [512]u8 = undefined;
                            @memcpy(key_buf[0..tname.len], tname);
                            key_buf[tname.len] = '.';
                            @memcpy(key_buf[tname.len + 1 .. total], mname);
                            if (globals.get(key_buf[0..total])) |method_func| {
                                func = method_func;
                            } else {
                                const fi = vmtyp.findFieldIndex(inst.typ.struct_type.fields, mname) orelse {
                                    if (isModuleNamespaceStruct(inst.typ)) return error.UnknownStructField;
                                    return error.UnknownMethod;
                                };
                                func = inst.fields[fi].value;
                                pass_recv = false;
                            }
                            if (pass_recv and func == .object) {
                                const fpi = heap.objectPoolIndex(func.object);
                                if (fpi != 0xFFFF) {
                                    chunk.patchByte(ic_base + 0, @intCast((tpi >> 8) & 0xFF));
                                    chunk.patchByte(ic_base + 1, @intCast(tpi & 0xFF));
                                    chunk.patchByte(ic_base + 2, @intCast((fpi >> 8) & 0xFF));
                                    chunk.patchByte(ic_base + 3, @intCast(fpi & 0xFF));
                                }
                            }
                        }
                        if (pass_recv) {
                            if (vmState().stack_top >= vms.MaxStack) return error.StackOverflow;
                            var i: usize = vmState().stack_top;
                            while (i > recv_idx + 1) {
                                vmState().stack[i] = vmState().stack[i - 1];
                                i -= 1;
                            }
                            vmState().stack_top += 1;
                            vmState().stack[recv_idx] = func;
                            vmState().stack[recv_idx + 1] = recv;
                            try performCall(argc + 1);
                        } else {
                            vmState().stack[recv_idx] = func;
                            try performCall(argc);
                        }
                    },
                    .map, .map_managed, .map_hashed => {
                        const items = vms.asMapSlice(recv.object);
                        var i: usize = 0;
                        var maybe: ?Value = null;
                        while (i < items.len) : (i += 1) {
                            if (vms.isStringValue(items[i].key) and common.streq(try vms.asStringValue(items[i].key), mname)) {
                                maybe = items[i].value;
                                break;
                            }
                        }
                        const func = maybe orelse return error.UnknownMethod;
                        vmState().stack[recv_idx] = func;
                        try performCall(argc);
                    },
                    .variant_type => |vt| {
                        var vi: usize = 0;
                        while (vi < vt.arms.len) : (vi += 1) {
                            if (common.streq(vt.arms[vi].name, mname)) break;
                        }
                        if (vi == vt.arms.len) return error.UnknownStructField;
                        const arm = vt.arms[vi];
                        if (arm.has_payload) {
                            if (argc != 1) return error.ArityMismatch;
                            const payload = vmState().stack[vmState().stack_top - 1];
                            if (arm.payload_type) |pt| {
                                if (!vmtyp.matchesTypeSpec(payload, pt)) return error.TypeError;
                            }
                            const vv = try vmAllocObject();
                            vv.* = .{ .variant_value = .{ .typ = recv.object, .tag = arm.name, .ordinal = vi, .payload = payload } };
                            var i: usize = @as(usize, argc) + 1;
                            while (i > 0) : (i -= 1) { _ = try vmPop(); }
                            try vmPush(.{ .object = vv });
                        } else {
                            if (argc != 0) return error.ArityMismatch;
                            const vv = try vmAllocObject();
                            vv.* = .{ .variant_value = .{ .typ = recv.object, .tag = arm.name, .ordinal = vi, .payload = .null } };
                            _ = try vmPop(); // pop recv
                            try vmPush(.{ .object = vv });
                        }
                    },
                    .string_builder => |*sb| {
                        if (common.streq(mname, "write")) {
                            if (argc != 1) return error.ArityMismatch;
                            const s_bytes = try vms.asStringValue(vmState().stack[recv_idx + 1]);
                            const needed = sb.len + s_bytes.len;
                            if (needed > sb.buf.len) {
                                // Grow: receiver stays on stack so GC keeps the object alive.
                                const new_buf = try vmgc.vmAllocManagedBytes(needed);
                                @memcpy(new_buf[0..sb.len], sb.buf[0..sb.len]);
                                heap.freeBytesManaged(sb.buf);
                                sb.buf = new_buf;
                            }
                            @memcpy(sb.buf[sb.len..][0..s_bytes.len], s_bytes);
                            sb.len = needed;
                            vmState().stack_top = recv_idx;
                            try vmPush(.null);
                        } else if (common.streq(mname, "str")) {
                            if (argc != 0) return error.ArityMismatch;
                            const result = try makeDynString(sb.buf[0..sb.len]);
                            vmState().stack_top = recv_idx;
                            try vmPush(result);
                        } else if (common.streq(mname, "reset")) {
                            if (argc != 0) return error.ArityMismatch;
                            sb.len = 0;
                            vmState().stack_top = recv_idx;
                            try vmPush(.null);
                        } else return error.UnknownMethod;
                    },
                    else => return error.NotAMethodReceiver,
                }
            },

            .jump => {
                const off = try vmShort();
                vmState().ip += off;
            },
            .jump_if_false => {
                const off = try vmShort();
                if (!(try vmPeek(0)).isTruthy()) vmState().ip += off;
            },
            .jif_pop => {
                const off = try vmShort();
                const cond = try vmPop();
                if (!cond.isTruthy()) vmState().ip += off;
            },
            .loop => {
                const off = try vmShort();
                vmState().ip -= off;
                // If the back-edge target is a warm get_global IC, execute it inline
                // to save one full dispatch iteration per loop cycle.
                const jip = vmState().ip;
                if (jip + 5 <= chunk.codeLen() and
                    chunk.codeByteAt(jip) == @intFromEnum(Op.get_global))
                {
                    const ic_slot: u16 = @intCast(
                        (@as(usize, chunk.codeByteAt(jip + 3)) << 8) | chunk.codeByteAt(jip + 4),
                    );
                    if (ic_slot != 0xffff) {
                        vmState().ip += 5;
                        try vmPush(globals.getAt(ic_slot));
                    }
                }
            },

            // Fused set_global + loop back-edge.
            // Bytecode: [op][name_hi][name_lo][ic_hi][ic_lo][off_hi][off_lo]
            // IC layout and patch offsets are identical to set_global.
            .set_global_loop => {
                const name_idx = try vmShort();
                const ic_base = vmState().ip;
                const ic_slot: u16 = @intCast(try vmShort());
                const val = try vmPop();
                if (ic_slot != 0xFFFF) {
                    globals.setAt(ic_slot, val);
                } else {
                    const name = chunk.constAt(name_idx).string;
                    const slot = globals.findSlot(name) orelse return error.NotDefined;
                    chunk.patchByte(ic_base,     @intCast((slot >> 8) & 0xFF));
                    chunk.patchByte(ic_base + 1, @intCast(slot & 0xFF));
                    globals.setAt(slot, val);
                }
                const off = try vmShort();
                vmState().ip -= off;
                // Same inline get_global as loop: skip one dispatch if warm.
                const jip = vmState().ip;
                if (jip + 5 <= chunk.codeLen() and
                    chunk.codeByteAt(jip) == @intFromEnum(Op.get_global))
                {
                    const ic_slot2: u16 = @intCast(
                        (@as(usize, chunk.codeByteAt(jip + 3)) << 8) | chunk.codeByteAt(jip + 4),
                    );
                    if (ic_slot2 != 0xffff) {
                        vmState().ip += 5;
                        try vmPush(globals.getAt(ic_slot2));
                    }
                }
            },

            .call => {
                const argc = try vmByte();
                if (try trySelfTailCall(argc)) continue;
                try performCall(argc);
            },
            .op_assert => {
                const cond = try vmPop();
                if (cond != .boolean) return error.TypeError;
                if (!cond.boolean) return error.AssertionFailed;
            },

            .op_assert_msg => {
                const msg_val = try vmPop();
                const cond = try vmPop();
                if (cond != .boolean) return error.TypeError;
                if (!cond.boolean) {
                    vmState().pending_panic_message = vms.asStringValue(msg_val) catch "AssertionFailed";
                    return error.AssertionFailed;
                }
            },

            .op_trap_check => {
                const val = try vmPop();
                switch (val) {
                    .null => {},
                    else => {
                        vmState().pending_panic_value = val;
                        vmState().has_pending_panic_value = true;
                        return error.TrapFired;
                    },
                }
            },

            .variant_check => {
                const arm = (try vms.vmConst()).string;
                const v = try vmPop();
                const matches = v == .object and v.object.* == .variant_value and
                    common.streq(v.object.variant_value.tag, arm);
                try vmPush(.{ .boolean = matches });
            },

            .variant_payload => {
                const v = try vmPop();
                if (v != .object or v.object.* != .variant_value) return error.TypeError;
                try vmPush(v.object.variant_value.payload);
            },

            .get_field => {
                const name_idx = try vmShort();
                const ic_base = vmState().ip;
                const ic_type_idx = try vmShort();
                const ic_fidx = try vmByte();
                const name = chunk.constAt(name_idx).string;
                const raw = try vmPop();
                const container = if (raw == .object and raw.object.* == .named_value)
                    raw.object.named_value.value
                else
                    raw;
                if (container != .object) return error.TypeError;
                const obj = container.object;
                switch (obj.*) {
                    .struct_instance => |inst| {
                        const tpi = heap.objectPoolIndex(inst.typ);
                        if (ic_type_idx == @as(usize, tpi) and ic_fidx != 0xFF) {
                            try vmPush(inst.fields[ic_fidx].value);
                        } else {
                            const fi = vmtyp.findFieldIndex(inst.typ.struct_type.fields, name) orelse return error.UnknownStructField;
                            if (fi <= 0xFE) {
                                chunk.patchByte(ic_base,     @intCast((tpi >> 8) & 0xFF));
                                chunk.patchByte(ic_base + 1, @intCast(tpi & 0xFF));
                                chunk.patchByte(ic_base + 2, @intCast(fi));
                            }
                            try vmPush(inst.fields[fi].value);
                        }
                    },
                    .map, .map_managed => {
                        const items = vms.asMapSlice(obj);
                        const key_v = Value{ .string = name };
                        var i: usize = 0;
                        while (i < items.len) : (i += 1) {
                            if (vmmap.mapKeyEquals(items[i].key, key_v)) {
                                try vmPush(items[i].value);
                                break;
                            }
                        }
                        if (i == items.len) try vmPush(.null);
                    },
                    .map_hashed => |hm| {
                        const key_v = Value{ .string = name };
                        if (vmmap.mapFindHashedIndex(hm.entries[0..hm.len], hm.buckets, key_v)) |fi| {
                            try vmPush(hm.entries[fi].value);
                        } else {
                            try vmPush(.null);
                        }
                    },
                    .enum_type => |et| {
                        if (common.streq(name, "name")) {
                            try vmPush(.{ .string = et.name });
                        } else if (common.streq(name, "first")) {
                            if (et.members.len == 0) return error.IndexOutOfBounds;
                            const ev = try vmAllocObject();
                            ev.* = .{ .enum_value = .{ .typ = obj, .name = et.members[0], .ordinal = 0 } };
                            try vmPush(.{ .object = ev });
                        } else if (common.streq(name, "last")) {
                            if (et.members.len == 0) return error.IndexOutOfBounds;
                            const last_i = et.members.len - 1;
                            const ev = try vmAllocObject();
                            ev.* = .{ .enum_value = .{ .typ = obj, .name = et.members[last_i], .ordinal = @intCast(last_i) } };
                            try vmPush(.{ .object = ev });
                        } else if (common.streq(name, "values")) {
                            const arr_obj = try vmAllocObject();
                            arr_obj.* = .{ .array = &[_]Value{} };
                            try pushTempRoot(.{ .object = arr_obj });
                            defer popTempRoot();
                            const items = try vmAllocManagedSlice(Value, et.members.len);
                            var ei: usize = 0;
                            while (ei < et.members.len) : (ei += 1) {
                                const ev = try vmAllocObject();
                                ev.* = .{ .enum_value = .{ .typ = obj, .name = et.members[ei], .ordinal = @intCast(ei) } };
                                items[ei] = .{ .object = ev };
                                arr_obj.* = .{ .array_managed = items[0 .. ei + 1] };
                            }
                            try vmPush(.{ .object = arr_obj });
                        } else {
                            var ei: usize = 0;
                            while (ei < et.members.len) : (ei += 1) {
                                if (common.streq(et.members[ei], name)) {
                                    const ev = try vmAllocObject();
                                    ev.* = .{ .enum_value = .{ .typ = obj, .name = et.members[ei], .ordinal = @intCast(ei) } };
                                    try vmPush(.{ .object = ev });
                                    break;
                                }
                            }
                            if (ei == et.members.len) return error.UnknownStructField;
                        }
                    },
                    .named_type => |nt| {
                        if (common.streq(name, "name")) {
                            try vmPush(.{ .string = nt.name });
                        } else if (common.streq(name, "first")) {
                            if (!nt.has_range) return error.TypeError;
                            try vmPush(try vmtyp.makeNamedValue(obj, .{ .number = nt.min }));
                        } else if (common.streq(name, "last")) {
                            if (!nt.has_range) return error.TypeError;
                            try vmPush(try vmtyp.makeNamedValue(obj, .{ .number = nt.max }));
                        } else return error.UnknownStructField;
                    },
                    .variant_type => |vt| {
                        if (common.streq(name, "name")) {
                            try vmPush(.{ .string = vt.name });
                        } else {
                            var vi: usize = 0;
                            while (vi < vt.arms.len) : (vi += 1) {
                                if (common.streq(vt.arms[vi].name, name)) {
                                    const arm = vt.arms[vi];
                                    if (arm.has_payload) {
                                        const ctor = try vmAllocObject();
                                        ctor.* = .{ .variant_ctor = .{
                                            .typ = obj,
                                            .tag = arm.name,
                                            .ordinal = vi,
                                            .payload_type = arm.payload_type,
                                        }};
                                        try vmPush(.{ .object = ctor });
                                    } else {
                                        const vv = try vmAllocObject();
                                        vv.* = .{ .variant_value = .{
                                            .typ = obj,
                                            .tag = arm.name,
                                            .ordinal = vi,
                                            .payload = .null,
                                        }};
                                        try vmPush(.{ .object = vv });
                                    }
                                    break;
                                }
                            }
                            if (vi == vt.arms.len) return error.UnknownStructField;
                        }
                    },
                    else => return error.TypeError,
                }
            },

            .set_field => {
                const name_idx = try vmShort();
                const ic_base = vmState().ip;
                const ic_type_idx = try vmShort();
                const ic_fidx = try vmByte();
                const name = chunk.constAt(name_idx).string;
                const val = try vmPop();
                const raw_c = try vmPop();
                const is_named_c = raw_c == .object and raw_c.object.* == .named_value;
                const container = if (is_named_c) raw_c.object.named_value.value else raw_c;
                if (is_named_c) {
                    const nv = raw_c.object.named_value;
                    if (nv.typ.* == .named_type) {
                        const nt = nv.typ.named_type;
                        if (nt.base == .map_t) {
                            if (nt.val_spec) |vs| {
                                if (!vmtyp.matchesTypeSpec(val, vs)) return error.TypeError;
                            }
                        }
                    }
                }
                if (container != .object) return error.TypeError;
                switch (container.object.*) {
                    .struct_instance => |inst| {
                        const tpi = heap.objectPoolIndex(inst.typ);
                        var fi: usize = undefined;
                        if (ic_type_idx == @as(usize, tpi) and ic_fidx != 0xFF) {
                            fi = ic_fidx;
                        } else {
                            const found = vmtyp.findFieldIndex(inst.typ.struct_type.fields, name) orelse return error.UnknownStructField;
                            fi = found;
                            if (found <= 0xFE) {
                                chunk.patchByte(ic_base,     @intCast((tpi >> 8) & 0xFF));
                                chunk.patchByte(ic_base + 1, @intCast(tpi & 0xFF));
                                chunk.patchByte(ic_base + 2, @intCast(found));
                            }
                        }
                        if (inst.typ.struct_type.fields[fi].is_const) return error.AssignToConst;
                        if (!vmtyp.matchesFieldType(val, inst.typ.struct_type.fields[fi])) return error.StructFieldTypeMismatch;
                        inst.fields[fi].value = val;
                    },
                    .map, .map_managed => {
                        const items = vms.asMapSlice(container.object);
                        const key_v = Value{ .string = name };
                        var i: usize = 0;
                        var updated = false;
                        while (i < items.len) : (i += 1) {
                            if (vmmap.mapKeyEquals(items[i].key, key_v)) {
                                items[i].value = val;
                                updated = true;
                                break;
                            }
                        }
                        if (!updated) {
                            try pushTempRoot(container);
                            defer popTempRoot();
                            const ext = try vmAllocManagedSlice(MapEntry, items.len + 1);
                            @memcpy(ext[0..items.len], items);
                            ext[items.len] = .{ .key = .{ .string = name }, .value = val };
                            const new_len = items.len + 1;
                            container.object.* = .{ .map_managed = ext[0..new_len] };
                            if (new_len > 8) {
                                const bcount = vmmap.mapBucketsForCount(new_len);
                                const buckets = try vmAllocManagedSlice(i32, bcount);
                                vmmap.mapBuildHashedBuckets(ext[0..new_len], buckets);
                                container.object.* = .{ .map_hashed = .{ .entries = ext[0..new_len], .len = new_len, .buckets = buckets } };
                            }
                        }
                    },
                    .map_hashed => {
                        const key_v = Value{ .string = name };
                        try vmmap.mapInsertHashed(container.object, key_v, val);
                    },
                    else => return error.TypeError,
                }
            },

            .defer_call => {
                const argc = try vmByte();
                if (vmState().defer_top >= cfg.max_defers) return error.DeferStackOverflow;
                const total: usize = @as(usize, argc) + 1;
                const start = vmState().stack_top - total;
                const arr_obj = try vmAllocObject();
                arr_obj.* = .{ .array = &[_]Value{} }; // safe tag before GC can run
                try pushTempRoot(.{ .object = arr_obj });
                defer popTempRoot();
                const items = try vmAllocManagedSlice(Value, total);
                var di: usize = 0;
                while (di < total) : (di += 1) items[di] = vmState().stack[start + di];
                arr_obj.* = .{ .array_managed = items[0..total] };
                vmState().defer_stack[vmState().defer_top] = .{ .object = arr_obj };
                vmState().defer_top += 1;
                vmState().stack_top -= total;
            },
            .defer_invoke_method => {
                const mname = (try vmConst()).string;
                const argc = try vmByte();
                if (vmState().defer_top >= cfg.max_defers) return error.DeferStackOverflow;
                const recv_idx = vmState().stack_top - @as(usize, argc) - 1;
                const recv = vmState().stack[recv_idx];
                if (recv != .object) return error.NotAMethodReceiver;
                var func: Value = undefined;
                var pass_recv: bool = undefined;
                switch (recv.object.*) {
                    .struct_instance => |inst| {
                        const tname = inst.typ.struct_type.qualified_name;
                        const key_total = tname.len + 1 + mname.len;
                        if (key_total > 512) return error.NotAMethodReceiver;
                        var key_buf: [512]u8 = undefined;
                        @memcpy(key_buf[0..tname.len], tname);
                        key_buf[tname.len] = '.';
                        @memcpy(key_buf[tname.len + 1 .. key_total], mname);
                        if (globals.get(key_buf[0..key_total])) |method_func| {
                            func = method_func;
                            pass_recv = true;
                        } else {
                            const fi = vmtyp.findFieldIndex(inst.typ.struct_type.fields, mname) orelse {
                                if (isModuleNamespaceStruct(inst.typ)) return error.UnknownStructField;
                                return error.UnknownMethod;
                            };
                            func = inst.fields[fi].value;
                            pass_recv = false;
                        }
                    },
                    .map, .map_managed, .map_hashed => {
                        const map_items = vms.asMapSlice(recv.object);
                        var found: ?Value = null;
                        var mi: usize = 0;
                        while (mi < map_items.len) : (mi += 1) {
                            if (vms.isStringValue(map_items[mi].key)) {
                                const ks = vms.asStringValue(map_items[mi].key) catch continue;
                                if (common.streq(ks, mname)) { found = map_items[mi].value; break; }
                            }
                        }
                        func = found orelse return error.UnknownMethod;
                        pass_recv = false;
                    },
                    else => return error.NotAMethodReceiver,
                }
                const extra: usize = if (pass_recv) 1 else 0;
                const total: usize = 1 + extra + @as(usize, argc);
                const arr_obj = try vmAllocObject();
                try pushTempRoot(.{ .object = arr_obj });
                defer popTempRoot();
                const items = try vmAllocManagedSlice(Value, total);
                items[0] = func;
                if (pass_recv) items[1] = recv;
                var ai: usize = 0;
                while (ai < argc) : (ai += 1) items[1 + extra + ai] = vmState().stack[recv_idx + 1 + ai];
                arr_obj.* = .{ .array_managed = items[0..total] };
                vmState().defer_stack[vmState().defer_top] = .{ .object = arr_obj };
                vmState().defer_top += 1;
                vmState().stack_top = recv_idx;
            },
            .ret => {
                vmperf.breakOpChain();
                if (vmState().frame_top == 0) return error.ReturnAtTopLevel;
                const retval = try vmPop();
                const fi = vmState().frame_top - 1;
                const frame = &vmState().frames[fi];
                if (vmState().defer_top == frame.defer_base and !frame.has_typed_returns) {
                    vmState().frame_top = fi;
                    vmState().stack_top = frame.base - 1;
                    vmState().ip = frame.ret_ip;
                    try vmPush(retval);
                    if (vmState().call_depth_target) |d| {
                        if (vmState().frame_top == d) return;
                    }
                    continue;
                }
                if (try retSlowPath(retval)) return;
            },

            // Fused constant+ret: reads idx, pushes constant, returns.
            // Emitted when `constant k` immediately precedes `ret`.
            .ret_const => {
                vmperf.breakOpChain();
                if (vmState().frame_top == 0) return error.ReturnAtTopLevel;
                const k = chunk.constAt(try vmShort());
                const fi = vmState().frame_top - 1;
                const frame = &vmState().frames[fi];
                if (vmState().defer_top == frame.defer_base and !frame.has_typed_returns) {
                    vmState().frame_top = fi;
                    vmState().stack_top = frame.base - 1;
                    vmState().ip = frame.ret_ip;
                    try vmPush(k);
                    if (vmState().call_depth_target) |d| {
                        if (vmState().frame_top == d) return;
                    }
                    continue;
                }
                if (try retSlowPath(k)) return;
            },

            .halt => { vmperf.breakOpChain(); return; },
        }
    }
}

fn runDeferredCall(deferred: Value) anyerror!void {
    const arr = vms.asArraySlice(deferred.object);
    if (arr.len == 0) return;
    const dargc: u8 = @intCast(arr.len - 1);
    var di: usize = 0;
    while (di < arr.len) : (di += 1) vmPush(arr[di]) catch return;
    const depth_before = vmState().frame_top;
    performCall(dargc) catch return;
    if (vmState().frame_top > depth_before) {
        const prev_target = vmState().call_depth_target;
        vmState().call_depth_target = depth_before;
        defer vmState().call_depth_target = prev_target;
        try run();
    }
    _ = vmPop() catch {};
}

fn runPanicUnwind(orig_err: anyerror) anyerror!void {
    var current_err = orig_err;
    vmState().recovered = false;
    vmState().panic_line = 0;
    vmState().panic_col = 0;
    vmState().panic_depth = 0;
    vmState().is_panicking = true;
    if (vmState().has_pending_panic_value) {
        vmState().panic_value = vmState().pending_panic_value;
        vmState().has_pending_panic_value = false;
    } else if (vmState().pending_panic_message) |msg| {
        vmState().panic_value = .{ .error_value = msg };
        vmState().pending_panic_message = null;
    } else {
        vmState().panic_value = .{ .error_value = @errorName(orig_err) };
    }

    if (vmState().panic_line == 0) {
        vmState().panic_line = currentLine();
        vmState().panic_col = currentCol();
        const stop_depth = vmState().call_depth_target orelse 0;
        var depth: usize = 0;
        var fi: usize = vmState().frame_top;
        while (fi > stop_depth and depth < vms.MaxFrames) {
            fi -= 1;
            const frame = vmState().frames[fi];
            const call_ip = if (frame.ret_ip > 0) frame.ret_ip - 1 else 0;
            const fname = switch (frame.func_obj.*) {
                .function => |f| f.name,
                .closure => |cl| cl.func.function.name,
                else => "",
            };
            vmState().panic_frames[depth] = .{ .line = chunk.lineAt(call_ip), .name = fname };
            depth += 1;
        }
        vmState().panic_depth = depth;
    }
    const stop_depth = vmState().call_depth_target orelse 0;
    while (vmState().frame_top > stop_depth) {
        const frame_defer_base = vmState().frames[vmState().frame_top - 1].defer_base;
        while (vmState().defer_top > frame_defer_base) {
            vmState().defer_top -= 1;
            runDeferredCall(vmState().defer_stack[vmState().defer_top]) catch |new_err| {
                if (!vmState().recovered) {
                    current_err = new_err;
                    vmState().panic_value = .{ .error_value = @errorName(new_err) };
                }
            };
            if (vmState().recovered) break;
        }
        if (vmState().recovered) {
            vmState().recovered = false;
            vmState().is_panicking = false;
            vmState().panic_line = 0;
            vmState().panic_col = 0;
            vmState().panic_depth = 0;
            vmState().defer_top = frame_defer_base;

            // Determine the recovered function's return arity before unwinding its frame.
            // If the function returns multiple values, callers expect a tuple; pushing a
            // bare null causes tuple_check_arity to throw TypeError.
            const rec_fobj = vmState().frames[vmState().frame_top - 1].func_obj;
            const rec_base = vmState().frames[vmState().frame_top - 1].base;
            const rec_fn: ?*@import("value.zig").FuncObj = switch (rec_fobj.*) {
                .function => &rec_fobj.function,
                .closure => |*cl| &cl.func.function,
                else => null,
            };
            const ret_count: usize = if (rec_fn) |f| f.return_types.len else 1;
            const named_ret: u8 = if (rec_fn) |f| f.named_return_count else 0;
            const rec_arity: u8 = if (rec_fn) |f| f.arity else 0;

            vmState().frame_top -= 1;
            const frame = vmState().frames[vmState().frame_top];
            vmState().stack_top = if (frame.base > 0) frame.base - 1 else 0;
            vmState().ip = frame.ret_ip;

            if (ret_count <= 1) {
                vmPush(.null) catch {};
            } else recover_ret: {
                // Multi-value return: build a tuple of the right size.
                // Named returns: use the values from the (still-readable) stack slots;
                // unnamed returns: fill with null.
                const n: u8 = if (named_ret > 0) named_ret else @intCast(ret_count);
                const tup_obj = vmAllocObject() catch { vmPush(.null) catch {}; break :recover_ret; };
                tup_obj.* = .{ .array = &[_]Value{} };
                const items = vmAllocManagedSlice(Value, n) catch { vmPush(.null) catch {}; break :recover_ret; };
                if (named_ret > 0) {
                    var ri: u8 = 0;
                    while (ri < named_ret) : (ri += 1)
                        items[ri] = vmState().stack[rec_base + rec_arity + ri];
                } else {
                    var ri: u8 = 0;
                    while (ri < n) : (ri += 1) items[ri] = .null;
                }
                tup_obj.* = .{ .array_managed = items };
                vmPush(.{ .object = tup_obj }) catch { vmPush(.null) catch {}; break :recover_ret; };
            }
            return run();
        }
        vmState().frame_top -= 1;
        const frame = vmState().frames[vmState().frame_top];
        vmState().stack_top = if (frame.base > 0) frame.base - 1 else 0;
        vmState().ip = frame.ret_ip;
    }
    vmState().is_panicking = false;
    return current_err;
}

// ── Public API ────────────────────────────────────────────────────────────────

pub fn run() anyerror!void {
    runInner() catch |err| return runPanicUnwind(err);
}

pub fn makeString(s: []const u8) !Value {
    return vmgc.makeDynString(s);
}

pub fn callGlobal(name: []const u8, args: []const Value) !Value {
    const fn_val = globals.get(name) orelse return error.NotDefined;
    if (fn_val != .object) return error.NotAFunction;
    const obj = fn_val.object;
    if (obj.* != .function and obj.* != .closure) return error.NotAFunction;

    try vmPush(fn_val);
    for (args) |a| try vmPush(a);

    const depth_before = vmState().frame_top;
    try performCall(@intCast(args.len));

    const prev_target = vmState().call_depth_target;
    vmState().call_depth_target = depth_before;
    defer vmState().call_depth_target = prev_target;

    try run();
    return try vmPop();
}
