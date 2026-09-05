const std = @import("std");
const host_abi = @import("../../runtime/host_abi.zig");
const heap = @import("../../runtime/heap.zig");
const chunk = @import("../chunk.zig");
const vms = @import("../vm_state.zig");
const VMContext = vms.VMContext;
const vmgc = @import("../vm_gc.zig");
const vmod = @import("../value.zig");
const Value = vmod.Value;
const Object = vmod.Object;
const MapEntry = vmod.MapEntry;
const MaxNativeArgs = @import("native_ids.zig").MaxNativeArgs;

fn makeWire(tag: host_abi.WireTag, flags: u8, payload: u64, len: u32) host_abi.ValueWire {
    return .{ .tag = @intFromEnum(tag), .flags = flags, .reserved = 0, .payload = payload, .len = len, .reserved2 = 0 };
}

pub fn nullWire() host_abi.ValueWire {
    return makeWire(.null, 0, 0, 0);
}

pub fn checkCallStatus(st: host_abi.CallStatus) !void {
    switch (st) {
        .ok => {},
        .unsupported => return error.HostNativeUnsupported,
        .denied => return error.PermissionDenied,
        .bad_args => return error.HostNativeBadArgs,
        .failed => return error.HostNativeFailed,
    }
}

pub fn nativeCallChecked(id: host_abi.HostCall, args: []const host_abi.ValueWire, out: *host_abi.ValueWire) !void {
    try checkCallStatus(host_abi.nativeCall(id, args, out));
}

pub fn nativeCallRawChecked(id: u16, args: []const host_abi.ValueWire, out: *host_abi.ValueWire) !void {
    try checkCallStatus(host_abi.nativeCallRaw(id, args, out));
}

// Scripts fully control the shape of values passed to a host module function
// (callHostModule serializes every argument through this function before the
// host ever sees it), and arrays/maps are mutable in place (`a[0] = a` is
// ordinary, reachable Gengo code), so a script can build either a
// self-referential container or an arbitrarily deep nesting chain with a
// trivial loop. Without a bound here, that recursion walks the native call
// stack with no backstop and crashes the whole process (stack overflow),
// not a catchable script error — the same hazard std.json's stringifier
// guards against with its own MaxDepth (see json.zig). A plain depth counter
// is enough: it terminates both unbounded nesting and cycles (a cycle just
// keeps incrementing depth forever until the cap trips), so no separate
// ancestor/cycle tracking is needed.
const MaxWireDepth: u32 = 64;

// A host-facing wire `len` field is u32; a >4 GiB Gengo string/array/map
// would silently truncate (wrong length handed to the host) or, in a
// safety-checked build, trip @intCast's overflow panic — a process abort
// reachable from an ordinary script given a large enough configured heap.
// Fail with a catchable error instead of trusting the cast.
fn wireLen(n: usize) !u32 {
    if (n > std.math.maxInt(u32)) return error.HostValueTooLarge;
    return @intCast(n);
}

pub fn wireFromValue(ctx: VMContext, v: Value) !host_abi.ValueWire {
    return wireFromValueDepth(ctx, v, 0);
}

fn wireFromValueDepth(ctx: VMContext, v: Value, depth: u32) !host_abi.ValueWire {
    if (depth >= MaxWireDepth) return error.HostValueTooDeep;
    return switch (v) {
        .null => nullWire(),
        .boolean => |b| makeWire(.boolean, 0, if (b) 1 else 0, 0),
        .int => |n| makeWire(.number, host_abi.FLAG_INTEGER, @bitCast(n), 0),
        .float => |n| makeWire(.number, 0, @bitCast(n), 0),
        .rune => |r| makeWire(.number, host_abi.FLAG_RUNE, @as(u64, r), 0),
        .decimal => |d| makeWire(.number, host_abi.FLAG_DECIMAL, @as(u64, @bitCast(d)), 0),
        .string => |s| makeWire(.string, 0, @intCast(@intFromPtr(s.bytes.ptr)), try wireLen(s.bytes.len)),
        .error_value => |msg| makeWire(.@"error", 0, @intCast(@intFromPtr(msg.bytes.ptr)), try wireLen(msg.bytes.len)),
        .object => |o| switch (o.*) {
            .dyn_string => makeWire(.string, 0, @intCast(@intFromPtr(o.dyn_string.ptr)), try wireLen(o.dyn_string.len)),
            .string_view => makeWire(.string, 0, @intCast(@intFromPtr(o.string_view.bytes.ptr)), try wireLen(o.string_view.bytes.len)),
            .array, .array_managed, .array_view, .array_capacity => {
                const items = try vms.asArraySlice(o);
                const wires = (ctx.hs.bump(host_abi.ValueWire, items.len) orelse return error.OutOfMemory)[0..items.len];
                for (items, 0..) |item, i| {
                    wires[i] = try wireFromValueDepth(ctx, item, depth + 1);
                }
                return makeWire(.array, 0, @intCast(@intFromPtr(wires.ptr)), try wireLen(items.len));
            },
            .map, .map_managed, .map_hashed => {
                const entries = try vms.asMapSlice(o);
                const wires = (ctx.hs.bump(host_abi.ValueWire, entries.len * 2) orelse return error.OutOfMemory)[0 .. entries.len * 2];
                for (entries, 0..) |entry, i| {
                    wires[i * 2] = try wireFromValueDepth(ctx, entry.key, depth + 1);
                    wires[i * 2 + 1] = try wireFromValueDepth(ctx, entry.value, depth + 1);
                }
                return makeWire(.map, 0, @intCast(@intFromPtr(wires.ptr)), try wireLen(entries.len));
            },
            .variant_value => |vv| {
                const wires = (ctx.hs.bump(host_abi.ValueWire, 4) orelse return error.OutOfMemory)[0..4];
                wires[0] = try wireFromValueDepth(ctx, .{ .string = try ctx.cs.internStr("tag") }, depth + 1);
                wires[1] = try wireFromValueDepth(ctx, .{ .string = try ctx.cs.internStr(vv.tag) }, depth + 1);
                wires[2] = try wireFromValueDepth(ctx, .{ .string = try ctx.cs.internStr("value") }, depth + 1);
                wires[3] = try wireFromValueDepth(ctx, vv.payload, depth + 1);
                return makeWire(.map, 0, @intCast(@intFromPtr(wires.ptr)), 2);
            },
            else => return error.UnsupportedHostValueType,
        },
        .inline_variant => |iv| {
            const ordinal = vmod.inlineVariantOrdinal(iv);
            const tag = vmod.objectAtIdx(iv.typ_idx).variant_type.arms[ordinal].name;
            const wires = (ctx.hs.bump(host_abi.ValueWire, 4) orelse return error.OutOfMemory)[0..4];
            wires[0] = try wireFromValueDepth(ctx, .{ .string = try ctx.cs.internStr("tag") }, depth + 1);
            wires[1] = try wireFromValueDepth(ctx, .{ .string = try ctx.cs.internStr(tag) }, depth + 1);
            wires[2] = try wireFromValueDepth(ctx, .{ .string = try ctx.cs.internStr("value") }, depth + 1);
            wires[3] = try wireFromValueDepth(ctx, vmod.inlineVariantPayload(iv), depth + 1);
            return makeWire(.map, 0, @intCast(@intFromPtr(wires.ptr)), 2);
        },
        // actor values are task-table-relative and meaningless outside this
        // process's scheduler — same treatment as any other
        // no-host-representation value.
        .actor_ref => return error.UnsupportedHostValueType,
    };
}

pub fn valueFromWire(ctx: VMContext, w: host_abi.ValueWire) !Value {
    return valueFromWireDepth(ctx, w, 0);
}

// Mirrors wireFromValueDepth's guard, in the opposite direction: a host that
// echoes back a script-supplied wire is already bounded by MaxWireDepth on
// the way out, but a host constructing its own deeply-nested/cyclic reply
// independently would otherwise recurse this VM-native call with no backstop
// — the same native-stack-overflow hazard, just triggered by a misbehaving
// host instead of a malicious script.
fn valueFromWireDepth(ctx: VMContext, w: host_abi.ValueWire, depth: u32) !Value {
    if (depth >= MaxWireDepth) return error.HostValueTooDeep;
    const tag: host_abi.WireTag = @enumFromInt(w.tag);
    return switch (tag) {
        .null => .null,
        .boolean => .{ .boolean = w.payload != 0 },
        .number => if ((w.flags & host_abi.FLAG_DECIMAL) != 0) {
            return Value{ .decimal = @bitCast(w.payload) };
        } else if ((w.flags & host_abi.FLAG_RUNE) != 0) {
            return Value{ .rune = @intCast(w.payload) };
        } else if ((w.flags & host_abi.FLAG_INTEGER) != 0) {
            return Value{ .int = @bitCast(w.payload) };
        } else {
            return Value{ .float = @bitCast(w.payload) };
        },
        .@"error" => {
            if (w.len == 0) return Value{ .error_value = try ctx.cs.internStr("") };
            const data = @as([*]u8, @ptrFromInt(@as(usize, @intCast(w.payload))))[0..@as(usize, @intCast(w.len))];
            const copy = try vmgc.vmAllocManagedBytes(ctx, w.len);
            @memcpy(copy[0..w.len], data);
            return .{ .error_value = try ctx.cs.internStr(copy[0..w.len]) };
        },
        .string => {
            if (w.len == 0) return Value{ .string = try ctx.cs.internStr("") };
            const data = @as([*]u8, @ptrFromInt(@as(usize, @intCast(w.payload))))[0..@as(usize, @intCast(w.len))];
            return vmgc.makeDynString(ctx, data);
        },
        .array => {
            const count = w.len;
            const elem_wires = @as([*]const host_abi.ValueWire, @ptrFromInt(@as(usize, @intCast(w.payload))))[0..count];
            const arr_obj = try vmgc.allocTempRooted(ctx, .{ .array_managed = &[_]Value{} });
            defer ctx.vs.popTempRoot();
            const items = try vmgc.vmAllocManagedSlice(ctx, Value, count);
            // GC-audit 2026-09 (project_gc_rooting_hardening): pre-fill and
            // publish the full length immediately rather than "publish
            // empty, grow visible by one" — that older pattern wrote
            // through the captured `items` local (a stale-pointer hazard
            // once compactManagedHeap relocates arr_obj's backing, which
            // valueFromWireDepth's recursion can trigger), and separately
            // sized any mid-loop relocation from the *currently visible*
            // length, permanently losing the reserved-but-unwritten tail
            // of the allocation. Every slot is a valid, traceable .null
            // from the start, so no incremental visibility is needed; the
            // loop below reads/writes through arr_obj's own field instead
            // of `items`, which is the only thing relocation keeps current.
            for (items) |*slot| slot.* = .null;
            arr_obj.* = .{ .array_managed = items[0..count] };
            for (elem_wires, 0..) |ew, i| {
                const v = try valueFromWireDepth(ctx, ew, depth + 1);
                arr_obj.array_managed[i] = v;
            }
            return .{ .object = arr_obj };
        },
        .map => {
            const count = w.len;
            const pair_wires = @as([*]const host_abi.ValueWire, @ptrFromInt(@as(usize, @intCast(w.payload))))[0 .. count * 2];
            const map_obj = try vmgc.allocTempRooted(ctx, .{ .map_managed = &[_]MapEntry{} });
            defer ctx.vs.popTempRoot();
            const entries = try vmgc.vmAllocManagedSlice(ctx, MapEntry, count);
            // Same reasoning as the .array branch above.
            for (entries) |*slot| slot.* = .{ .key = .null, .value = .null };
            map_obj.* = .{ .map_managed = entries[0..count] };
            for (0..count) |i| {
                const k = try valueFromWireDepth(ctx, pair_wires[i * 2], depth + 1);
                try ctx.vs.pushTempRoot(k);
                const v = try valueFromWireDepth(ctx, pair_wires[i * 2 + 1], depth + 1);
                ctx.vs.popTempRoot();
                map_obj.map_managed[i] = .{ .key = k, .value = v };
            }
            return .{ .object = map_obj };
        },
    };
}

pub fn wireNumberToU64(w: host_abi.ValueWire) !u64 {
    const tag: host_abi.WireTag = @enumFromInt(w.tag);
    if (tag != .number) return error.HostNativeBadReturnType;
    // wireFromValueDepth's own .int arm bitcasts the i64 straight into
    // payload (FLAG_INTEGER set), not through an f64 bit pattern — the same
    // convention a host built against this ABI would naturally follow.
    // Reading every FLAG_INTEGER reply as if it were f64 bits (the previous
    // behavior here) reinterprets the raw integer bit pattern as garbage,
    // which for ensureHostReady's abi_version check meant a host reporting
    // its version the idiomatic way could spuriously fail the handshake.
    if ((w.flags & host_abi.FLAG_INTEGER) != 0) {
        const n: i64 = @bitCast(w.payload);
        if (n < 0) return error.HostNativeBadReturnValue;
        return @intCast(n);
    }
    const n: f64 = @bitCast(w.payload);
    if (n < 0) return error.HostNativeBadReturnValue;
    const tr = @trunc(n);
    if (tr != n) return error.HostNativeBadReturnValue;
    if (tr > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.HostNativeBadReturnValue;
    return @intFromFloat(tr);
}

// std natives are never host-overridable — see dev-docs/roadmap.md and
// CHANGELOG.md: a host used to be able to swap the implementation of
// std.core.len/append/bytelen and std.conv.to_int/to_float/to_bool/to_string
// (io.println had its own inline equivalent), which meant the same call
// could silently behave differently depending on the embedding host. These
// helpers now always run the embedded implementation; host modules
// (`import("host:x")`, callHostModule) are unaffected — a different,
// explicitly host-owned namespace with no bearing on std semantics.
pub fn callNativeVariadic(ctx: vms.VMContext, argc: u8, start: usize, comptime nativeFn: anytype) !void {
    const result = try @call(.auto, nativeFn, .{ ctx, start, argc });
    ctx.vs.vmPopArgs(argc);
    try ctx.vs.vmPush(result);
}

pub fn callNative1(ctx: vms.VMContext, argc: u8, comptime nativeFn: anytype) !void {
    const out = try @call(.auto, nativeFn, .{ ctx, ctx.vs.vmTop(0) });
    ctx.vs.vmPopArgs(argc);
    try ctx.vs.vmPush(out);
}

pub fn ensureHostReady(ctx: VMContext) !void {
    if (ctx.vs.policy.native_backend != .host) return;
    if (ctx.vs.host_checked) return;

    var out = nullWire();

    var empty: [0]host_abi.ValueWire = .{};
    const st_ver = host_abi.nativeCall(.abi_version, empty[0..], &out);
    switch (st_ver) {
        .ok => {},
        .unsupported => {
            ctx.vs.host_checked = true;
            return;
        },
        .denied => return error.PermissionDenied,
        .bad_args => return error.HostNativeBadArgs,
        .failed => return error.HostNativeFailed,
    }
    const version = try wireNumberToU64(out);
    if (version != host_abi.ABI_VERSION) return error.HostAbiVersionMismatch;
    ctx.vs.host_checked = true;
}

// Regression: wireFromValue serializes every argument a script passes to a
// host module function (see callHostModule in native/main.zig). Arrays are
// mutable in place, so ordinary script code (`a[0] = a`, or a loop that
// wraps a value in a new one-element array each iteration) can hand it a
// self-referential or arbitrarily deep container. Before the depth counter
// was added, wireFromValue recursed once per nesting level with no bound at
// all, which for a self-cycle recurses forever and for deep-but-finite
// nesting still eventually blows the native call stack — a process-level
// crash, not a catchable script error. This builds nesting deeper than the
// cap and checks it now fails cleanly instead of recursing without limit.
test "wireFromValue rejects arbitrarily deep nested arrays" {
    const Runtime = @import("../../runtime/runtime.zig").Runtime;
    var rt: Runtime = undefined;
    rt.initWithPolicy(.{ .allow_io = false }) catch return error.TestFailed;
    defer rt.deinit();

    const ctx = VMContext.fromActive();

    const depth: usize = 100;
    var inner: Value = .null;
    var pushed: usize = 0;
    for (0..depth) |_| {
        const arr = try vmgc.allocTempRootedManagedValueArray(ctx, 1);
        arr.set(0, inner);
        inner = .{ .object = arr.obj };
        pushed += 1;
    }
    defer for (0..pushed) |_| ctx.vs.popTempRoot();

    try std.testing.expectError(error.HostValueTooDeep, wireFromValue(ctx, inner));
}

// Regression: valueFromWire (the opposite direction — a host's ValueWire
// reply converted into a script Value, see callHostModule in native/main.zig)
// had the identical unbounded-recursion shape as wireFromValue above, just
// triggered by a host constructing deeply-nested reply data instead of a
// script. Same fix, same test shape: a chain of single-element array wires
// deeper than MaxWireDepth must fail cleanly instead of blowing the native
// call stack.
test "valueFromWire rejects arbitrarily deep nested wire arrays" {
    const Runtime = @import("../../runtime/runtime.zig").Runtime;
    var rt: Runtime = undefined;
    rt.initWithPolicy(.{ .allow_io = false }) catch return error.TestFailed;
    defer rt.deinit();

    const ctx = VMContext.fromActive();

    const depth = 100;
    var wires: [depth]host_abi.ValueWire = undefined;
    wires[0] = nullWire();
    for (1..depth) |i| {
        wires[i] = makeWire(.array, 0, @intCast(@intFromPtr(&wires[i - 1])), 1);
    }

    try std.testing.expectError(error.HostValueTooDeep, valueFromWire(ctx, wires[depth - 1]));
}

// Regression: wireFromValueDepth's .int arm bitcasts the raw i64 into
// payload with FLAG_INTEGER set (not an f64 bit pattern) — the natural
// encoding a host built against this ABI would use for an integer reply.
// wireNumberToU64 previously always reinterpreted payload as f64 bits
// regardless of flags, so a host reporting its ABI version this way could
// spuriously fail ensureHostReady's version check.
test "wireNumberToU64 honors FLAG_INTEGER encoding" {
    const w = makeWire(.number, host_abi.FLAG_INTEGER, @bitCast(@as(i64, 42)), 0);
    try std.testing.expectEqual(@as(u64, 42), try wireNumberToU64(w));
}

test "checkCallStatus maps every CallStatus variant to its documented outcome" {
    try checkCallStatus(.ok);
    try std.testing.expectError(error.HostNativeUnsupported, checkCallStatus(.unsupported));
    try std.testing.expectError(error.PermissionDenied, checkCallStatus(.denied));
    try std.testing.expectError(error.HostNativeBadArgs, checkCallStatus(.bad_args));
    try std.testing.expectError(error.HostNativeFailed, checkCallStatus(.failed));
}

test "wireNumberToU64 rejects negative, non-integral, and too-large floats, and non-number wires" {
    const ok_w = makeWire(.number, 0, @bitCast(@as(f64, 7.0)), 0);
    try std.testing.expectEqual(@as(u64, 7), try wireNumberToU64(ok_w));

    const negative_w = makeWire(.number, 0, @bitCast(@as(f64, -1.0)), 0);
    try std.testing.expectError(error.HostNativeBadReturnValue, wireNumberToU64(negative_w));

    const fractional_w = makeWire(.number, 0, @bitCast(@as(f64, 1.5)), 0);
    try std.testing.expectError(error.HostNativeBadReturnValue, wireNumberToU64(fractional_w));

    const huge_w = makeWire(.number, 0, @bitCast(@as(f64, 1e30)), 0);
    try std.testing.expectError(error.HostNativeBadReturnValue, wireNumberToU64(huge_w));

    const non_number_w = nullWire();
    try std.testing.expectError(error.HostNativeBadReturnType, wireNumberToU64(non_number_w));
}

// wireFromValue/valueFromWire back every scalar Value variant with a direct
// bit/pointer encoding (see wireFromValueDepth's switch) — round-trip each
// one and confirm the decoded Value matches the original.
test "wireFromValue/valueFromWire round-trip every scalar Value variant" {
    const Runtime = @import("../../runtime/runtime.zig").Runtime;
    var rt: Runtime = undefined;
    rt.initWithPolicy(.{ .allow_io = false }) catch return error.TestFailed;
    defer rt.deinit();

    const ctx = VMContext.fromActive();

    {
        const w = try wireFromValue(ctx, .null);
        const v = try valueFromWire(ctx, w);
        try std.testing.expect(v == .null);
    }
    {
        const w = try wireFromValue(ctx, .{ .boolean = true });
        const v = try valueFromWire(ctx, w);
        try std.testing.expect(v == .boolean);
        try std.testing.expectEqual(true, v.boolean);
    }
    {
        const w = try wireFromValue(ctx, .{ .int = -12345 });
        const v = try valueFromWire(ctx, w);
        try std.testing.expect(v == .int);
        try std.testing.expectEqual(@as(i64, -12345), v.int);
    }
    {
        const w = try wireFromValue(ctx, .{ .float = 3.5 });
        const v = try valueFromWire(ctx, w);
        try std.testing.expect(v == .float);
        try std.testing.expectEqual(@as(f64, 3.5), v.float);
    }
    {
        const w = try wireFromValue(ctx, .{ .rune = 0x1F600 });
        const v = try valueFromWire(ctx, w);
        try std.testing.expect(v == .rune);
        try std.testing.expectEqual(@as(u21, 0x1F600), v.rune);
    }
    {
        // .decimal is a raw i64 carrier at the Value level (no scale info
        // here — see known-limitations.md on ABI v2 decimal wire values).
        const w = try wireFromValue(ctx, .{ .decimal = 12345 });
        const v = try valueFromWire(ctx, w);
        try std.testing.expect(v == .decimal);
        try std.testing.expectEqual(@as(i64, 12345), v.decimal);
    }
    {
        const s = try ctx.cs.internStr("hello");
        const w = try wireFromValue(ctx, .{ .string = s });
        const v = try valueFromWire(ctx, w);
        try std.testing.expectEqualStrings("hello", try vms.asStringValue(v));
    }
    {
        const msg = try ctx.cs.internStr("boom");
        const w = try wireFromValue(ctx, .{ .error_value = msg });
        const v = try valueFromWire(ctx, w);
        try std.testing.expect(v == .error_value);
        try std.testing.expectEqualStrings("boom", v.error_value.bytes);
    }
}

test "wireFromValue/valueFromWire round-trip an array and a map with nested elements" {
    const Runtime = @import("../../runtime/runtime.zig").Runtime;
    var rt: Runtime = undefined;
    rt.initWithPolicy(.{ .allow_io = false }) catch return error.TestFailed;
    defer rt.deinit();

    const ctx = VMContext.fromActive();

    {
        const arr = try vmgc.allocTempRootedManagedValueArray(ctx, 3);
        defer ctx.vs.popTempRoot();
        arr.set(0, .{ .int = 1 });
        arr.set(1, try vmgc.makeDynString(ctx, "two"));
        arr.set(2, .null);

        const w = try wireFromValue(ctx, .{ .object = arr.obj });
        const v = try valueFromWire(ctx, w);
        try std.testing.expect(v == .object);
        const items = try vms.asArraySlice(v.object);
        try std.testing.expectEqual(@as(usize, 3), items.len);
        try std.testing.expect(items[0] == .int);
        try std.testing.expectEqual(@as(i64, 1), items[0].int);
        try std.testing.expectEqualStrings("two", try vms.asStringValue(items[1]));
        try std.testing.expect(items[2] == .null);
    }
    {
        const map_obj = try vmgc.allocTempRooted(ctx, .{ .map = &[_]MapEntry{} });
        defer ctx.vs.popTempRoot();
        const entries = try vmgc.vmAllocManagedSlice(ctx, MapEntry, 1);
        map_obj.* = .{ .map_managed = entries };
        entries[0] = .{ .key = try vmgc.makeDynString(ctx, "a"), .value = .{ .int = 1 } };

        const w = try wireFromValue(ctx, .{ .object = map_obj });
        const v = try valueFromWire(ctx, w);
        try std.testing.expect(v == .object);
        const map_entries = try vms.asMapSlice(v.object);
        try std.testing.expectEqual(@as(usize, 1), map_entries.len);
        try std.testing.expectEqualStrings("a", try vms.asStringValue(map_entries[0].key));
        try std.testing.expect(map_entries[0].value == .int);
        try std.testing.expectEqual(@as(i64, 1), map_entries[0].value.int);
    }
}

// A real compiled variant instance goes through wireFromValueDepth's
// .object.variant_value prong or its top-level .inline_variant prong
// depending on Zig's own small-payload inlining heuristic — either way, the
// wire form is always the same 2-entry {"tag": name, "value": payload} map,
// so this round-trips correctly regardless of which representation the
// compiler picked, exercising whichever prong actually fired.
test "wireFromValue/valueFromWire round-trip a compiled variant instance" {
    const api = @import("../../runtime/api.zig");
    var rt = try api.Runtime.init(.{ .allow_io = false, .allocator = std.testing.allocator });
    defer rt.deinit();

    switch (rt.run(
        \\type Shape variant {
        \\    Circle(radius int),
        \\    Rect { w int, h int },
        \\}
        \\func makeCircle() Shape { return Shape.Circle(5) }
        \\func makeRect() Shape { return Shape.Rect{w: 2, h: 3} }
    )) {
        .ok => {},
        else => return error.TestFailed,
    }

    const ctx = VMContext.fromActive();

    inline for (.{ "makeCircle", "makeRect" }) |name| {
        const shape_val = switch (rt.call(name, &.{})) {
            .ok => |v| v,
            .runtime_error => return error.TestFailed,
        };
        const w = try wireFromValue(ctx, shape_val);
        const v = try valueFromWire(ctx, w);
        try std.testing.expect(v == .object);
        const entries = try vms.asMapSlice(v.object);
        try std.testing.expectEqual(@as(usize, 2), entries.len);
        try std.testing.expectEqualStrings("tag", try vms.asStringValue(entries[0].key));
        try std.testing.expectEqualStrings("value", try vms.asStringValue(entries[1].key));
    }
}
