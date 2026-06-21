const std = @import("std");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const vmmap = @import("../vm_map.zig");
const heap = @import("../../runtime/heap.zig");
const vmod = @import("../value.zig");
const Value = vmod.Value;
const Object = vmod.Object;
const MapEntry = vmod.MapEntry;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;

// ── JSONValue variant type ─────────────────────────────────────────────────
// Synthesised at runtime, mirroring what the user would write as:
//   type JSONValue variant {
//       jnull, jbool(bool), jint(int), jfloat(float), jstr(string),
//       jarray([]JSONValue), jobject([string]JSONValue),
//   }

pub const JsonValueQualifiedName = "@std.json.Value";

const jv_arms = [_]vmod.VariantArmSpec{
    .{ .name = "jnull" },
    .{ .name = "jbool",   .has_payload = true },
    .{ .name = "jint",    .has_payload = true },
    .{ .name = "jfloat",  .has_payload = true },
    .{ .name = "jstr",    .has_payload = true },
    .{ .name = "jarray",  .has_payload = true },
    .{ .name = "jobject", .has_payload = true },
};

var jv_type_cache: ?*Object = null;

pub fn jsonValueClearCache() void {
    jv_type_cache = null;
}

pub fn jsonValueGetType() !*Object {
    if (jv_type_cache) |t| return t;
    // Bump-allocate: permanent singleton; never swept, never triggers GC
    const buf = heap.bump(Object, 1) orelse return error.OutOfMemory;
    const obj: *Object = @ptrCast(buf);
    obj.* = .{ .variant_type = .{
        .name = "JSONValue",
        .qualified_name = JsonValueQualifiedName,
        .arms = &jv_arms,
    } };
    jv_type_cache = obj;
    return obj;
}

const JVArm = enum(usize) { jnull = 0, jbool = 1, jint = 2, jfloat = 3, jstr = 4, jarray = 5, jobject = 6 };

fn makeJV(arm: JVArm, payload: Value) !Value {
    const typ = try jsonValueGetType(); // bump: no alloc, no GC
    // Protect payload if it's an object (e.g. dyn_string for .jstr) before vmAllocObject triggers GC
    const payload_is_obj = switch (payload) { .object => true, else => false };
    if (payload_is_obj) try vms.pushTempRoot(payload);
    defer if (payload_is_obj) vms.popTempRoot();
    const obj = try vmgc.vmAllocObject();
    obj.* = .{ .variant_value = .{
        .typ = typ,
        .tag = jv_arms[@intFromEnum(arm)].name,
        .ordinal = @intFromEnum(arm),
        .payload = payload,
    } };
    return .{ .object = obj };
}

fn jsonValueToTyped(jv: std.json.Value) !Value {
    return switch (jv) {
        .null          => makeJV(.jnull, .null),
        .bool   => |b| makeJV(.jbool,  .{ .boolean = b }),
        .integer => |i| makeJV(.jint,  .{ .int = i }),
        .float  => |f| makeJV(.jfloat, .{ .float = f }),
        .number_string => |s| makeJV(.jfloat, .{ .float = try std.fmt.parseFloat(f64, s) }),
        .string => |s| makeJV(.jstr,   try vmgc.makeDynString(s)),
        .array  => |arr| {
            const n = arr.items.len;
            const items_obj = try vmgc.allocTempRooted(.{ .array_managed = &[_]Value{} });
            defer vms.popTempRoot();
            const items = try vmgc.vmAllocManagedSlice(Value, n);
            items_obj.* = .{ .array_managed = items[0..0] };
            for (0..n) |i| {
                items[i] = try jsonValueToTyped(arr.items[i]);
                items_obj.* = .{ .array_managed = items[0 .. i + 1] };
            }
            return makeJV(.jarray, .{ .object = items_obj });
        },
        .object => |obj_map| {
            const n = obj_map.keys().len;
            const map_obj = try vmgc.allocTempRooted(.{ .map = &[_]MapEntry{} });
            defer vms.popTempRoot();
            const entries = try vmgc.vmAllocManagedSlice(MapEntry, n);
            map_obj.* = .{ .map = entries[0..0] };
            const keys = obj_map.keys();
            const vals = obj_map.values();
            for (0..n) |i| {
                const k = try vmgc.makeDynString(keys[i]);
                try vms.pushTempRoot(k);
                entries[i].key = k;
                entries[i].value = try jsonValueToTyped(vals[i]);
                vms.popTempRoot();
                map_obj.* = .{ .map = entries[0 .. i + 1] };
            }
            if (n > 0) {
                const bcount = vmmap.mapBucketsForCount(n);
                const buckets = try vmgc.vmAllocManagedSlice(i32, bcount);
                vmmap.mapBuildHashedBuckets(entries[0..n], buckets);
                map_obj.* = .{ .map_hashed = .{ .entries = entries[0..n], .len = n, .buckets = buckets } };
            }
            return makeJV(.jobject, .{ .object = map_obj });
        },
    };
}

pub fn jsonParseValueNative() !Value {
    const src = try vms.asStringValue(vms.vmTop(0));
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, src, .{}) catch |e| {
        vms.setRuntimeErr("json.parse_value: {s}", .{@errorName(e)});
        return error.TypeError;
    };
    defer parsed.deinit();
    return jsonValueToTyped(parsed.value);
}

fn jsonValueToGengo(jv: std.json.Value) !Value {
    return switch (jv) {
        .null => .null,
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .float = try std.fmt.parseFloat(f64, s) },
        .string => |s| try vmgc.makeDynString(s),
        .array => |arr| {
            const n = arr.items.len;
            if (n == 0) {
                const obj = try vmgc.vmAllocObject();
                obj.* = .{ .array_managed = &[_]Value{} };
                return .{ .object = obj };
            }
            const obj = try vmgc.allocTempRooted(.{ .array_managed = &[_]Value{} });
            defer vms.popTempRoot();
            const items = try vmgc.vmAllocManagedSlice(Value, n);
            obj.* = .{ .array_managed = items[0..0] }; // publish immediately so GC traces partial contents
            for (0..n) |i| {
                items[i] = try jsonValueToGengo(arr.items[i]);
                obj.* = .{ .array_managed = items[0 .. i + 1] }; // grow visible length
            }
            return .{ .object = obj };
        },
        .object => |obj_map| {
            const n = obj_map.keys().len;
            if (n == 0) {
                const obj = try vmgc.vmAllocObject();
                obj.* = .{ .map = &[_]MapEntry{} };
                return .{ .object = obj };
            }
            const obj = try vmgc.allocTempRooted(.{ .map = &[_]MapEntry{} });
            defer vms.popTempRoot();
            const items = try vmgc.vmAllocManagedSlice(MapEntry, n);
            obj.* = .{ .map = items[0..0] }; // root items immediately; grow length as entries are filled
            const keys = obj_map.keys();
            const vals = obj_map.values();
            for (0..n) |i| {
                const k = try vmgc.makeDynString(keys[i]);
                try vms.pushTempRoot(k);
                items[i].key = k;
                items[i].value = try jsonValueToGengo(vals[i]);
                vms.popTempRoot();
                obj.* = .{ .map = items[0 .. i + 1] };
            }
            obj.* = .{ .map = items[0..n] };
            const bcount = vmmap.mapBucketsForCount(n);
            const buckets = try vmgc.vmAllocManagedSlice(i32, bcount);
            vmmap.mapBuildHashedBuckets(items[0..n], buckets);
            obj.* = .{ .map_hashed = .{ .entries = items[0..n], .len = n, .buckets = buckets } };
            return .{ .object = obj };
        },
    };
}

const MaxDepth = 32;

fn jsonStringifyValueDepth(s: *std.json.Stringify, gv: Value, depth: u32, ancestors: *[MaxDepth]*const Object, anc_count: *usize) !void {
    if (depth >= MaxDepth) {
        try s.write(null);
        return;
    }
    if (vmod.decimalRawAndScale(gv)) |drs| {
        var tmp: [64]u8 = undefined;
        const str = vmod.formatDecimalString(drs.raw, drs.scale, &tmp);
        try s.writer.writeAll(str);
        return;
    }
    const uv = vms.unboxNamed(gv);
    switch (uv) {
        .null => try s.write(null),
        .boolean => |b| try s.write(b),
        .int => |n| try s.write(n),
        .float => |n| try s.write(n),
        .decimal => unreachable,
        .rune => |r| try s.write(@as(i64, @intCast(r))),
        .string => |str| try s.write(str.bytes),
        .object => |obj| switch (obj.*) {
            .dyn_string => |str| try s.write(str),
            .string_view => |sv| try s.write(sv.bytes),
            .array, .array_managed, .array_capacity => {
                for (ancestors[0..anc_count.*]) |a| {
                    if (a == obj) {
                        try s.write(null);
                        return;
                    }
                }
                ancestors[anc_count.*] = obj;
                anc_count.* += 1;
                try s.beginArray();
                for (try vms.asArraySlice(obj)) |item| {
                    try jsonStringifyValueDepth(s, item, depth + 1, ancestors, anc_count);
                }
                try s.endArray();
                anc_count.* -= 1;
            },
            .map, .map_managed, .map_hashed => {
                for (ancestors[0..anc_count.*]) |a| {
                    if (a == obj) {
                        try s.write(null);
                        return;
                    }
                }
                ancestors[anc_count.*] = obj;
                anc_count.* += 1;
                try s.beginObject();
                for (try vms.asMapSlice(obj)) |entry| {
                    const key = vms.unboxNamed(entry.key);
                    const key_str = try vms.asStringValue(key);
                    try s.objectField(key_str);
                    try jsonStringifyValueDepth(s, entry.value, depth + 1, ancestors, anc_count);
                }
                try s.endObject();
                anc_count.* -= 1;
            },
            else => try s.write(null),
        },
        .error_value => try s.write(null),
    }
}

fn jsonStringifyValue(s: *std.json.Stringify, gv: Value) !void {
    var ancestors: [MaxDepth]*const Object = undefined;
    var anc_count: usize = 0;
    try jsonStringifyValueDepth(s, gv, 0, &ancestors, &anc_count);
}

pub fn jsonParseNative() !Value {
    const src = try vms.asStringValue(vms.vmTop(0));
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, src, .{}) catch |e| {
        vms.setRuntimeErr("json.parse: {s}", .{@errorName(e)});
        return error.TypeError;
    };
    defer parsed.deinit();
    return jsonValueToGengo(parsed.value);
}

pub fn jsonStringifyNative() !Value {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    jsonStringifyValue(&s, vms.vmTop(0)) catch return error.TypeError;
    const buf = out.written();
    return vmgc.makeDynString(buf);
}

pub fn jsonValidNative() !Value {
    const src = try vms.asStringValue(vms.vmTop(0));
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, src, .{}) catch return .{ .boolean = false };
    parsed.deinit();
    return .{ .boolean = true };
}

pub fn jsonIndentNative() !Value {
    const src = try vms.asStringValue(vms.vmTop(1));
    const indent_str = try vms.asStringValue(vms.vmTop(0));
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, src, .{}) catch |e| {
        vms.setRuntimeErr("json.indent: {s}", .{@errorName(e)});
        return error.TypeError;
    };
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    const Ws = @TypeOf(@as(std.json.Stringify.Options, .{}).whitespace);
    const ws: Ws = if (std.mem.eql(u8, indent_str, "\t")) .indent_tab
        else if (std.mem.eql(u8, indent_str, " ")) .indent_1
        else if (std.mem.eql(u8, indent_str, "   ")) .indent_3
        else if (std.mem.eql(u8, indent_str, "        ")) .indent_8
        else if (std.mem.eql(u8, indent_str, "    ")) .indent_4
        else .indent_2;
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = ws } };
    try s.write(parsed.value);
    return vmgc.makeDynString(out.written());
}

pub fn dispatch(nf: NativeFuncObj, argc: u8) !void {
    if (argc != nf.arity) return error.ArityMismatch;
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .json_parse => {
            const out = try jsonParseNative();
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .json_stringify => {
            const out = try jsonStringifyNative();
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .json_valid => {
            const out = try jsonValidNative();
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .json_indent => {
            const out = try jsonIndentNative();
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        .json_parse_value => {
            const out = try jsonParseValueNative();
            vms.vmPopArgs(argc);
            try vms.vmPush(out);
        },
        else => {},
    }
}
