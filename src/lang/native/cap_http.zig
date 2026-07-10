const std = @import("std");
const builtin = @import("builtin");
const heap = @import("../../runtime/heap.zig");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const Value = @import("../value.zig").Value;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const http_state = @import("http_state.zig");
const globals = @import("../globals.zig");
const MapEntry = @import("../value.zig").MapEntry;
const Object = @import("../value.zig").Object;
const FieldTypeAlt = @import("../value.zig").FieldTypeAlt;
const FieldTypeSpec = @import("../value.zig").FieldTypeSpec;
const StructFieldSpec = @import("../value.zig").StructFieldSpec;
const StructTypeObj = @import("../value.zig").StructTypeObj;
const chunk = @import("../chunk.zig");

const ResponseTypeQualifiedName = "@cap_type:http.Response";

const VMContext = vms.VMContext;

fn buildResponseStruct(ctx: VMContext, status: i32, body: []const u8, hdr_map: std.StringHashMap([]const u8), ok: bool) !Value {
    const resp_type_val = ctx.gs.get(ResponseTypeQualifiedName) orelse return error.CapabilityError;
    const resp_type_obj = switch (resp_type_val) {
        .object => |o| o,
        else => return error.CapabilityError,
    };

    const inst_fields = try vmgc.vmAllocManagedSlice(ctx, MapEntry, 4);
    const inst_obj = try vmgc.vmAllocObject(ctx);
    try ctx.vs.pushTempRoot(.{ .object = inst_obj });
    defer ctx.vs.popTempRoot();
    inst_obj.* = .{ .struct_instance = .{ .typ = resp_type_obj, .fields = inst_fields } };

    // body — root it immediately so it survives header allocations below
    const body_val = try vmgc.makeDynString(ctx, body);
    try ctx.vs.pushTempRoot(body_val);
    defer ctx.vs.popTempRoot();

    // headers map — pre-init entries to .null so GC can safely trace mid-loop
    const hdr_count = hdr_map.count();
    const hdr_entries = try vmgc.vmAllocManagedSlice(ctx, MapEntry, hdr_count);
    for (hdr_entries) |*e| e.* = .{ .key = .null, .value = .null };
    const hdr_obj = try vmgc.allocTempRooted(ctx, .{ .map = &[_]MapEntry{} });
    defer ctx.vs.popTempRoot();
    // Assign map_managed before the loop so GC traces completed entries each iteration
    hdr_obj.* = .{ .map_managed = hdr_entries };
    {
        var it = hdr_map.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            const key_val = try vmgc.makeDynString(ctx, entry.key_ptr.*);
            // Root key_val across the val allocation so GC can't collect it
            try ctx.vs.pushTempRoot(key_val);
            defer ctx.vs.popTempRoot();
            const val_val = try vmgc.makeDynString(ctx, entry.value_ptr.*);
            hdr_entries[i] = .{ .key = key_val, .value = val_val };
        }
    }

    inst_fields[0] = .{ .key = .{ .string = try ctx.cs.internStr("status") }, .value = .{ .int = @as(i64, status) } };
    inst_fields[1] = .{ .key = .{ .string = try ctx.cs.internStr("body") }, .value = body_val };
    inst_fields[2] = .{ .key = .{ .string = try ctx.cs.internStr("headers") }, .value = .{ .object = hdr_obj } };
    inst_fields[3] = .{ .key = .{ .string = try ctx.cs.internStr("ok") }, .value = .{ .boolean = ok } };

    return .{ .object = inst_obj };
}

fn pushOkPair(ctx: VMContext, resp: Value) !void {
    // resp.object is unrooted on entry (caller popped its temp root); protect it before GC fires
    try ctx.vs.pushTempRoot(resp);
    defer ctx.vs.popTempRoot();
    const arr = try vmgc.allocTempRootedManagedValueArray(ctx, 2);
    defer ctx.vs.popTempRoot();
    arr.values[0] = resp;
    arr.values[1] = .null;
    arr.publish(2);
    try ctx.vs.vmPush(.{ .object = arr.obj });
}

fn pushErrPair(ctx: VMContext, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    const copy = try vmgc.vmAllocManagedBytes(ctx, msg.len);
    @memcpy(copy[0..msg.len], msg);

    const arr = try vmgc.allocTempRootedManagedValueArray(ctx, 2);
    defer ctx.vs.popTempRoot();
    arr.values[0] = .null;
    arr.values[1] = .{ .error_value = try ctx.cs.internStr(copy[0..msg.len]) };
    arr.publish(2);
    try ctx.vs.vmPush(.{ .object = arr.obj });
}

pub fn dispatch(ctx: VMContext, nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .cap_http_get => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try ctx.vs.vmPop();
            const url = try vms.asStringValue(arg0);
            _ = try ctx.vs.vmPop();

            var result = http_state.httpFetch("GET", url, null, null, 0) catch |err| {
                if (err == error.CapabilityNotAvailable) return error.CapabilityError;
                try pushErrPair(ctx, "http.get: {s}: {s}", .{ url, @errorName(err) });
                return;
            };
            defer result.deinit();

            const resp_val = try buildResponseStruct(ctx, result.status, result.body, result.headers, result.ok);
            try pushOkPair(ctx, resp_val);
        },
        .cap_http_post => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try ctx.vs.vmPop();
            const arg0 = try ctx.vs.vmPop();
            const url = try vms.asStringValue(arg0);
            const body = try vms.asStringValue(arg1);
            _ = try ctx.vs.vmPop();

            var result = http_state.httpFetch("POST", url, body, null, 0) catch |err| {
                if (err == error.CapabilityNotAvailable) return error.CapabilityError;
                try pushErrPair(ctx, "http.post: {s}: {s}", .{ url, @errorName(err) });
                return;
            };
            defer result.deinit();

            const resp_val = try buildResponseStruct(ctx, result.status, result.body, result.headers, result.ok);
            try pushOkPair(ctx, resp_val);
        },
        .cap_http_fetch => {
            if (argc != 2) return error.ArityMismatch;
            const arg1 = try ctx.vs.vmPop();
            const arg0 = try ctx.vs.vmPop();
            const url = try vms.asStringValue(arg0);
            const opts = switch (arg1) {
                .object => |o| o,
                else => return error.TypeError,
            };
            _ = try ctx.vs.vmPop();

            // Extract options from the map
            var method: []const u8 = "GET";
            var body: ?[]const u8 = null;
            var timeout_ms: i64 = 0;
            var req_headers = std.StringHashMap([]const u8).init(std.heap.page_allocator);
            defer req_headers.deinit();

            switch (opts.*) {
                .map, .map_managed, .map_hashed => {
                    const entries = try vms.asMapSlice(opts);
                    for (entries) |entry| {
                        const key = switch (entry.key) {
                            .string => |s| s.bytes,
                            else => continue,
                        };
                        if (std.mem.eql(u8, key, "method")) {
                            method = switch (entry.value) {
                                .string => |s| s.bytes,
                                else => return error.TypeError,
                            };
                        } else if (std.mem.eql(u8, key, "body")) {
                            const b = switch (entry.value) {
                                .string => |s| s.bytes,
                                else => return error.TypeError,
                            };
                            body = b;
                        } else if (std.mem.eql(u8, key, "timeout_ms")) {
                            timeout_ms = switch (entry.value) {
                                .int => |n| n,
                                .float => |n| blk: {
                                    if (n < @as(f64, @floatFromInt(std.math.minInt(i64))) or n >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
                                    break :blk @as(i64, @intFromFloat(n));
                                },
                                else => return error.TypeError,
                            };
                        } else if (std.mem.eql(u8, key, "headers")) {
                            const hdr_obj = switch (entry.value) {
                                .object => |o| o,
                                else => return error.TypeError,
                            };
                            const hdr_entries = try vms.asMapSlice(hdr_obj);
                            for (hdr_entries) |he| {
                                const hk = switch (he.key) {
                                    .string => |s| s.bytes,
                                    else => continue,
                                };
                                const hv = switch (he.value) {
                                    .string => |s| s.bytes,
                                    else => continue,
                                };
                                try req_headers.put(hk, hv);
                            }
                        }
                    }
                },
                else => return error.TypeError,
            }

            var result = http_state.httpFetch(method, url, body, req_headers, timeout_ms) catch |err| {
                if (err == error.CapabilityNotAvailable) return error.CapabilityError;
                try pushErrPair(ctx, "http.fetch: {s} {s}: {s}", .{ method, url, @errorName(err) });
                return;
            };
            defer result.deinit();

            const resp_val = try buildResponseStruct(ctx, result.status, result.body, result.headers, result.ok);
            try pushOkPair(ctx, resp_val);
        },
        else => unreachable,
    }
}

pub fn registerResponseType(ctx: VMContext, gs: *globals.State) !void {
    if (gs.has(ResponseTypeQualifiedName)) return;

    const any_alts = ctx.hs.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
    any_alts[0] = .{ .typ = .any };
    const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };

    const field_specs = (ctx.hs.bump(StructFieldSpec, 4) orelse return error.OutOfMemory)[0..4];
    field_specs[0] = .{ .name = "status", .typ = any_spec, .is_const = true };
    field_specs[1] = .{ .name = "body", .typ = any_spec, .is_const = true };
    field_specs[2] = .{ .name = "headers", .typ = any_spec, .is_const = true };
    field_specs[3] = .{ .name = "ok", .typ = any_spec, .is_const = true };

    const typ_obj = try vmgc.vmAllocObject(ctx);
    try ctx.vs.pushTempRoot(.{ .object = typ_obj });
    defer ctx.vs.popTempRoot();
    typ_obj.* = .{ .struct_type = StructTypeObj{
        .name = "Response",
        .qualified_name = ResponseTypeQualifiedName,
        .fields = field_specs,
    } };

    try gs.def(ResponseTypeQualifiedName, .{ .object = typ_obj });
}
