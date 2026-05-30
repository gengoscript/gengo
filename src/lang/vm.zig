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

fn namedTypeCarrier(a: Value, b: Value) !?*Object {
    var ta: ?*Object = null;
    var tb: ?*Object = null;
    if (a == .object and a.object.* == .named_value) ta = a.object.named_value.typ;
    if (b == .object and b.object.* == .named_value) tb = b.object.named_value.typ;
    if (ta != null and tb != null and ta.? != tb.?) return error.TypeError;
    return if (ta != null) ta else tb;
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
        else => return error.NotAFunction,
    }
}

fn writeFrameLocal(abs_slot: usize, v: Value) void {
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
    switch (v) {
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

fn runInner() !void {
    while (true) {
        if (vmState().ops_budget_remaining) |remaining| {
            if (remaining == 0) return error.InstructionBudgetExceeded;
            vmState().ops_budget_remaining = remaining - 1;
        }
        const op_raw = try vmByte();
        if (op_raw >= std.meta.fields(Op).len) return error.BadOpcode;
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
                const name = (try vmConst()).string;
                try vmPush(globals.get(name) orelse return error.NotDefined);
            },
            .set_global => {
                const name = (try vmConst()).string;
                const val = try vmPop();
                if (!globals.set(name, val)) return error.NotDefined;
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
                    const sa = try vms.asStringValue(a);
                    const sb = try vms.asStringValue(b);
                    try vmPush(try concatDynString(sa, sb));
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
                try vmPush(.{ .number = @floatFromInt(~n) });
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
            .neg => {
                const v = try vmPop();
                const n = try vms.valueAsNumber(v);
                try vmPush(.{ .number = -n });
            },
            .not => try vmPush(.{ .boolean = !(try vmPop()).isTruthy() }),
            .eq => {
                const b = try vmPop();
                const a = try vmPop();
                try vmPush(.{ .boolean = Value.equals(a, b) });
            },
            .gt => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try vms.valueAsNumber(a);
                const bn = try vms.valueAsNumber(b);
                try vmPush(.{ .boolean = an > bn });
            },
            .lt => {
                const b = try vmPop();
                const a = try vmPop();
                const an = try vms.valueAsNumber(a);
                const bn = try vms.valueAsNumber(b);
                try vmPush(.{ .boolean = an < bn });
            },

            .build_array => {
                const count = try vmByte();
                const obj = try vmAllocObject();
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
                const bcount = vmmap.mapBucketsForCount(count);
                const buckets = try vmAllocManagedSlice(i32, bcount);
                vmmap.mapBuildHashedBuckets(items[0..count], buckets);
                obj.* = .{ .map_hashed = .{ .entries = items[0..count], .len = count, .buckets = buckets } };
                try vmPush(.{ .object = obj });
            },
            .build_tuple => {
                const count = try vmByte();
                const obj = try vmAllocObject();
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
                const supplied_ptr = heap.bump(MapEntry, count) orelse return error.OutOfMemory;
                const supplied = supplied_ptr[0..count];
                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    const val = try vmPop();
                    const key = try vmPop();
                    supplied[i] = .{ .key = key, .value = val };
                }
                const typ_v = try vmPop();
                if (typ_v != .object or typ_v.object.* != .struct_type) return error.TypeError;
                const st = typ_v.object.struct_type;

                const seen_ptr = heap.bump(bool, st.fields.len) orelse return error.OutOfMemory;
                const seen = seen_ptr[0..st.fields.len];
                for (seen) |*b| b.* = false;
                const inst_fields_ptr = heap.bump(MapEntry, st.fields.len) orelse return error.OutOfMemory;
                const inst_fields = inst_fields_ptr[0..st.fields.len];

                var si: usize = 0;
                while (si < supplied.len) : (si += 1) {
                    const key_s = try vms.asStringValue(supplied[si].key);
                    const idx = vmtyp.findFieldIndex(st.fields, key_s) orelse return error.UnknownStructField;
                    if (seen[idx]) return error.DuplicateField;
                    seen[idx] = true;
                    if (!vmtyp.matchesFieldType(supplied[si].value, st.fields[idx])) return error.StructFieldTypeMismatch;
                    inst_fields[idx] = .{
                        .key = .{ .string = st.fields[idx].name },
                        .value = supplied[si].value,
                    };
                }

                var mi: usize = 0;
                while (mi < st.fields.len) : (mi += 1) {
                    if (!seen[mi]) return error.MissingStructField;
                }

                const obj = try vmAllocObject();
                obj.* = .{
                    .struct_instance = .{
                        .typ = typ_v.object,
                        .fields = inst_fields,
                    },
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
                const container = try vmPop();
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
                            var ei: usize = 0;
                            while (ei < et.members.len) : (ei += 1) {
                                if (common.streq(et.members[ei], key)) {
                                    const ev = try vmAllocObject();
                                    ev.* = .{ .enum_value = .{
                                        .typ = obj,
                                        .name = et.members[ei],
                                        .ordinal = @intCast(ei),
                                    } };
                                    try vmPush(.{ .object = ev });
                                    break;
                                }
                            }
                            if (ei == et.members.len) return error.UnknownStructField;
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
                const container = try vmPop();
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
                            container.object.* = .{ .map_managed = ext[0 .. items.len + 1] };
                        }
                    },
                    .map_hashed => {
                        try vmmap.mapInsertHashed(container.object, idx_v, val);
                    },
                    .struct_instance => |inst| {
                        const key = try vms.asStringValue(idx_v);
                        const idx = vmtyp.findFieldIndex(inst.typ.struct_type.fields, key) orelse return error.UnknownStructField;
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
                const recv_idx = vmState().stack_top - argc - 1;
                const recv = vmState().stack[recv_idx];
                if (recv != .object) return error.NotAMethodReceiver;
                switch (recv.object.*) {
                    .struct_instance => |inst| {
                        const tname = inst.typ.struct_type.name;
                        const total = tname.len + 1 + mname.len;
                        const key_buf = heap.bump(u8, total) orelse return error.OutOfMemory;
                        @memcpy(key_buf[0..tname.len], tname);
                        key_buf[tname.len] = '.';
                        @memcpy(key_buf[tname.len + 1 .. total], mname);
                        const key = key_buf[0..total];

                        const func = globals.get(key) orelse return error.UnknownMethod;
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
            .loop => {
                const off = try vmShort();
                vmState().ip -= off;
            },

            .call => {
                const argc = try vmByte();
                if (try trySelfTailCall(argc)) continue;
                try performCall(argc);
            },
            .defer_call => {
                const argc = try vmByte();
                if (vmState().defer_top >= cfg.max_defers) return error.DeferStackOverflow;
                const total: usize = @as(usize, argc) + 1;
                const start = vmState().stack_top - total;
                const arr_obj = try vmAllocObject();
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
                        const tname = inst.typ.struct_type.name;
                        const key_total = tname.len + 1 + mname.len;
                        if (key_total > 128) return error.NotAMethodReceiver;
                        var key_buf: [128]u8 = undefined;
                        @memcpy(key_buf[0..tname.len], tname);
                        key_buf[tname.len] = '.';
                        @memcpy(key_buf[tname.len + 1 .. key_total], mname);
                        func = globals.get(key_buf[0..key_total]) orelse return error.UnknownMethod;
                        pass_recv = true;
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
                if (vmState().frame_top == 0) return error.ReturnAtTopLevel;
                const retval = try vmPop();
                const fi = vmState().frame_top - 1;
                const frame = &vmState().frames[fi];

                // Fast path: no defers pending, no return-type checks (the common case).
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

                // Slow path: run defers and/or enforce return types.
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
                popTempRoot();
                vmState().frame_top = fi;
                if (frame.has_typed_returns) {
                    const fsig = try vmtyp.frameFuncSig(frame.func_obj);
                    try vmtyp.enforceFuncReturnTypes(fsig, retval);
                }
                vmState().stack_top = frame.base - 1;
                vmState().ip = frame.ret_ip;
                try vmPush(retval);
                if (vmState().call_depth_target) |d| {
                    if (vmState().frame_top == d) return;
                }
            },

            .halt => return,
        }
    }
}

fn runDeferredCall(deferred: Value) void {
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
        run() catch {};
    }
    _ = vmPop() catch {};
}

fn runPanicUnwind(orig_err: anyerror) anyerror!void {
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
            runDeferredCall(vmState().defer_stack[vmState().defer_top]);
        }
        vmState().frame_top -= 1;
        const frame = vmState().frames[vmState().frame_top];
        vmState().stack_top = if (frame.base > 0) frame.base - 1 else 0;
        vmState().ip = frame.ret_ip;
    }
    return orig_err;
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
