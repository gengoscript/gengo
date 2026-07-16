const std = @import("std");
const builtin = @import("builtin");
const common = @import("../common.zig");
const heap = @import("../../runtime/heap.zig");
const chunk = @import("../chunk.zig");
const host_abi = @import("../../runtime/host_abi.zig");
const io = @import("../../runtime/io.zig");
const globals = @import("../globals.zig");
const module_compile = @import("../module_compile.zig");
const module_descriptor = @import("../module_descriptor.zig");
const vms = @import("../vm_state.zig");
const vmgc = @import("../vm_gc.zig");
const vmmap = @import("../vm_map.zig");
const vmtyp = @import("../vm_types.zig");
const vmstr = @import("../vm_string.zig");
const vmperf = @import("../vm_perf.zig");
const vm = @import("../vm.zig");
const Value = @import("../value.zig").Value;
const Object = @import("../value.zig").Object;
const MapEntry = @import("../value.zig").MapEntry;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const HostModuleFuncObj = @import("../value.zig").HostModuleFuncObj;
const FieldTypeAlt = @import("../value.zig").FieldTypeAlt;
const FieldTypeSpec = @import("../value.zig").FieldTypeSpec;
const StructFieldSpec = @import("../value.zig").StructFieldSpec;
const StructTypeObj = @import("../value.zig").StructTypeObj;

const rand_mod = @import("rand.zig");
const encode_mod = @import("encode.zig");
const time_mod = @import("time.zig");
const core_mod = @import("core.zig");
const string_mod = @import("string.zig");
const io_mod = @import("io.zig");
const arg_mod = @import("arg.zig");
const json_mod = @import("json.zig");
const template_mod = @import("template.zig");
const regexp_mod = @import("regexp.zig");
const host_abi_mod = @import("host_abi.zig");
const math_mod = @import("math.zig");
const conv_mod = @import("conv.zig");
const array_mod = @import("array.zig");
const bytes_mod = @import("bytes.zig");
const sort_mod = @import("sort.zig");
const build_options = @import("build_options");
const cap_net_mod = if (build_options.cap_net) @import("cap_net.zig") else struct {};
const cap_fs_mod = if (build_options.cap_fs) @import("cap_fs.zig") else struct {};
const cap_http_mod = if (build_options.cap_http) @import("cap_http.zig") else struct {};
const cap_env_mod = if (build_options.cap_env) @import("cap_env.zig") else struct {};

const TemplateTypeQualifiedName = "@std.template.obj";

const NativeFnId = @import("native_ids.zig").NativeFnId;
const compare = @import("compare.zig");

const MaxNativeArgs = 255;
const NamespaceEntry = struct {
    name: []const u8,
    value: Value,
};

fn makeNative(ctx: vms.VMContext, id: NativeFnId, arity: u8) !Value {
    // Store in the runtime's backing array outside the GC-managed heap.  This means:
    // - GC never marks or sweeps these objects (isObjectLive returns false).
    // - compactManagedHeap never overwrites them (they are not in heap[]).
    // - Each buildStdModule call refreshes the slot; no separate reset needed.
    const idx = @intFromEnum(id);
    ctx.vs.native_fn_backing[idx] = .{ .native_function = .{ .id = idx, .arity = arity } };
    return .{ .object = &ctx.vs.native_fn_backing[idx] };
}

fn makeNamespace(ctx: vms.VMContext, display_name: []const u8, qualified_name: []const u8, entries: []const NamespaceEntry) !*Object {
    const any_alts = ctx.hs.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
    any_alts[0] = .{ .typ = .any };
    const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };

    const field_specs = ctx.hs.bump(StructFieldSpec, entries.len) orelse return error.OutOfMemory;
    for (field_specs[0..entries.len], entries) |*fs, e| fs.* = .{ .name = e.name, .typ = any_spec, .is_const = true };

    const typ_obj = try vmgc.vmAllocObject(ctx);
    try ctx.vs.pushTempRoot(.{ .object = typ_obj });
    defer ctx.vs.popTempRoot();
    typ_obj.* = .{ .struct_type = StructTypeObj{
        .name = display_name,
        .qualified_name = qualified_name,
        .fields = field_specs[0..entries.len],
    } };

    const inst_fields = try vmgc.vmAllocManagedSlice(ctx, MapEntry, entries.len);
    const inst_obj = try vmgc.vmAllocObject(ctx);
    try ctx.vs.pushTempRoot(.{ .object = inst_obj });
    defer ctx.vs.popTempRoot();
    inst_obj.* = .{ .struct_instance = .{ .typ = typ_obj, .fields = inst_fields } };

    for (inst_fields[0..entries.len], entries) |*f, e| f.* = .{ .key = .{ .string = try ctx.cs.internStr(e.name) }, .value = e.value };
    return inst_obj;
}

pub fn buildStdModule(ctx: vms.VMContext) !*Object {
    if (ctx.vs.std_module) |m| return m;

    var fmt_entries: [module_descriptor.fmtExports.len]NamespaceEntry = undefined;
    for (module_descriptor.fmtExports, 0..) |entry, i| {
        fmt_entries[i] = .{ .name = entry.name, .value = try makeNative(ctx, entry.native_id.?, entry.arity) };
    }
    const fmt_obj = try makeNamespace(ctx,"fmt", "@module_type:std.fmt", &fmt_entries);
    try ctx.vs.pushTempRoot(.{ .object = fmt_obj });
    defer ctx.vs.popTempRoot();

    var io_entries: [module_descriptor.ioExports.len]NamespaceEntry = undefined;
    for (module_descriptor.ioExports, 0..) |entry, i| {
        io_entries[i] = .{ .name = entry.name, .value = try makeNative(ctx, entry.native_id.?, entry.arity) };
    }
    const io_obj = try makeNamespace(ctx,"io", "@module_type:std.io", &io_entries);
    try ctx.vs.pushTempRoot(.{ .object = io_obj });
    defer ctx.vs.popTempRoot();

    var core_entries: [module_descriptor.coreExports.len]NamespaceEntry = undefined;
    for (module_descriptor.coreExports, 0..) |entry, i| {
        core_entries[i] = .{ .name = entry.name, .value = try makeNative(ctx, entry.native_id.?, entry.arity) };
    }
    const core_obj = try makeNamespace(ctx,"core", "@module_type:std.core", &core_entries);
    try ctx.vs.pushTempRoot(.{ .object = core_obj });
    defer ctx.vs.popTempRoot();

    var conv_entries: [module_descriptor.convExports.len]NamespaceEntry = undefined;
    for (module_descriptor.convExports, 0..) |entry, i| {
        conv_entries[i] = .{ .name = entry.name, .value = try makeNative(ctx, entry.native_id.?, entry.arity) };
    }
    const conv_obj = try makeNamespace(ctx,"conv", "@module_type:std.conv", &conv_entries);
    try ctx.vs.pushTempRoot(.{ .object = conv_obj });
    defer ctx.vs.popTempRoot();

    var math_entries: [module_descriptor.mathExports.len]NamespaceEntry = undefined;
    for (module_descriptor.mathExports, 0..) |entry, i| {
        math_entries[i] = .{ .name = entry.name, .value = switch (entry.kind) {
            .function => try makeNative(ctx, entry.native_id.?, entry.arity),
            .value => .{ .float = entry.float_value },
        } };
    }
    const math_obj = try makeNamespace(ctx,"math", "@module_type:std.math", &math_entries);
    try ctx.vs.pushTempRoot(.{ .object = math_obj });
    defer ctx.vs.popTempRoot();

    var rand_entries: [module_descriptor.randExports.len]NamespaceEntry = undefined;
    for (module_descriptor.randExports, 0..) |entry, i| {
        rand_entries[i] = .{ .name = entry.name, .value = try makeNative(ctx, entry.native_id.?, entry.arity) };
    }
    const rand_obj = try makeNamespace(ctx,"rand", "@module_type:std.rand", &rand_entries);
    try ctx.vs.pushTempRoot(.{ .object = rand_obj });
    defer ctx.vs.popTempRoot();

    var string_entries: [module_descriptor.stringExports.len]NamespaceEntry = undefined;
    for (module_descriptor.stringExports, 0..) |entry, i| {
        string_entries[i] = .{ .name = entry.name, .value = try makeNative(ctx, entry.native_id.?, entry.arity) };
    }
    const string_obj = try makeNamespace(ctx,"string", "@module_type:std.string", &string_entries);
    try ctx.vs.pushTempRoot(.{ .object = string_obj });
    defer ctx.vs.popTempRoot();

    const arg_type_obj = try arg_mod.argGetType(ctx);
    try ctx.vs.pushTempRoot(.{ .object = arg_type_obj });
    defer ctx.vs.popTempRoot();

    const jv_type_obj = try json_mod.jsonValueGetType(ctx);
    try ctx.vs.pushTempRoot(.{ .object = jv_type_obj });
    defer ctx.vs.popTempRoot();

    var json_entries: [module_descriptor.jsonExports.len]NamespaceEntry = undefined;
    for (module_descriptor.jsonExports, 0..) |entry, i| {
        json_entries[i] = .{ .name = entry.name, .value = switch (entry.kind) {
            .function => try makeNative(ctx, entry.native_id.?, entry.arity),
            .value => if (entry.is_type_object) .{ .object = jv_type_obj } else .{ .int = entry.int_value },
        } };
    }
    const json_obj = try makeNamespace(ctx,"json", "@module_type:std.json", &json_entries);
    try ctx.vs.pushTempRoot(.{ .object = json_obj });
    defer ctx.vs.popTempRoot();

    var template_entries: [module_descriptor.templateExports.len]NamespaceEntry = undefined;
    for (module_descriptor.templateExports, 0..) |entry, i| {
        template_entries[i] = .{ .name = entry.name, .value = try makeNative(ctx, entry.native_id.?, entry.arity) };
    }
    const template_obj = try makeNamespace(ctx,"template", "@module_type:std.template", &template_entries);
    try ctx.vs.pushTempRoot(.{ .object = template_obj });
    defer ctx.vs.popTempRoot();

    const time_type_obj = try time_mod.timeGetType(ctx);
    try ctx.vs.pushTempRoot(.{ .object = time_type_obj });
    defer ctx.vs.popTempRoot();

    var time_entries: [module_descriptor.timeExports.len + 1]NamespaceEntry = undefined;
    for (module_descriptor.timeExports, 0..) |entry, i| {
        time_entries[i] = .{ .name = entry.name, .value = switch (entry.kind) {
            .function => try makeNative(ctx, entry.native_id.?, entry.arity),
            .value => .{ .int = entry.int_value },
        } };
    }
    time_entries[module_descriptor.timeExports.len] = .{ .name = "__type", .value = .{ .object = time_type_obj } };
    const time_obj = try makeNamespace(ctx,"time", "@module_type:std.time", &time_entries);
    try ctx.vs.pushTempRoot(.{ .object = time_obj });
    defer ctx.vs.popTempRoot();

    var hex_entries: [module_descriptor.hexExports.len]NamespaceEntry = undefined;
    for (module_descriptor.hexExports, 0..) |entry, i| {
        hex_entries[i] = .{ .name = entry.name, .value = try makeNative(ctx, entry.native_id.?, entry.arity) };
    }
    const hex_obj = try makeNamespace(ctx,"hex", "@module_type:std.hex", &hex_entries);
    try ctx.vs.pushTempRoot(.{ .object = hex_obj });
    defer ctx.vs.popTempRoot();

    var base64_entries: [module_descriptor.base64Exports.len]NamespaceEntry = undefined;
    for (module_descriptor.base64Exports, 0..) |entry, i| {
        base64_entries[i] = .{ .name = entry.name, .value = try makeNative(ctx, entry.native_id.?, entry.arity) };
    }
    const base64_obj = try makeNamespace(ctx,"base64", "@module_type:std.base64", &base64_entries);
    try ctx.vs.pushTempRoot(.{ .object = base64_obj });
    defer ctx.vs.popTempRoot();

    const regexp_type_obj = try regexp_mod.reGetType(ctx);
    try ctx.vs.pushTempRoot(.{ .object = regexp_type_obj });
    defer ctx.vs.popTempRoot();

    var regexp_entries: [module_descriptor.regexpExports.len + 1]NamespaceEntry = undefined;
    for (module_descriptor.regexpExports, 0..) |entry, i| {
        regexp_entries[i] = .{ .name = entry.name, .value = try makeNative(ctx, entry.native_id.?, entry.arity) };
    }
    regexp_entries[module_descriptor.regexpExports.len] = .{ .name = "__type", .value = .{ .object = regexp_type_obj } };
    const regexp_obj = try makeNamespace(ctx,"regexp", "@module_type:std.regexp", &regexp_entries);
    try ctx.vs.pushTempRoot(.{ .object = regexp_obj });
    defer ctx.vs.popTempRoot();

    var sort_entries: [module_descriptor.sortExports.len]NamespaceEntry = undefined;
    for (module_descriptor.sortExports, 0..) |entry, i| {
        sort_entries[i] = .{ .name = entry.name, .value = try makeNative(ctx, entry.native_id.?, entry.arity) };
    }
    const sort_obj = try makeNamespace(ctx,"sort", "@module_type:std.sort", &sort_entries);
    try ctx.vs.pushTempRoot(.{ .object = sort_obj });
    defer ctx.vs.popTempRoot();

    var array_entries: [module_descriptor.arrayExports.len]NamespaceEntry = undefined;
    for (module_descriptor.arrayExports, 0..) |entry, i| {
        array_entries[i] = .{ .name = entry.name, .value = try makeNative(ctx, entry.native_id.?, entry.arity) };
    }
    const array_obj = try makeNamespace(ctx,"array", "@module_type:std.array", &array_entries);
    try ctx.vs.pushTempRoot(.{ .object = array_obj });
    defer ctx.vs.popTempRoot();

    var bytes_entries: [module_descriptor.bytesExports.len]NamespaceEntry = undefined;
    for (module_descriptor.bytesExports, 0..) |entry, i| {
        bytes_entries[i] = .{ .name = entry.name, .value = try makeNative(ctx, entry.native_id.?, entry.arity) };
    }
    const bytes_obj = try makeNamespace(ctx,"bytes", "@module_type:std.bytes", &bytes_entries);
    try ctx.vs.pushTempRoot(.{ .object = bytes_obj });
    defer ctx.vs.popTempRoot();

    const std_entries = [_]NamespaceEntry{
        .{ .name = "io", .value = .{ .object = io_obj } },
        .{ .name = "fmt", .value = .{ .object = fmt_obj } },
        .{ .name = "core", .value = .{ .object = core_obj } },
        .{ .name = "conv", .value = .{ .object = conv_obj } },
        .{ .name = "math", .value = .{ .object = math_obj } },
        .{ .name = "rand", .value = .{ .object = rand_obj } },
        .{ .name = "string", .value = .{ .object = string_obj } },
        .{ .name = "json", .value = .{ .object = json_obj } },
        .{ .name = "template", .value = .{ .object = template_obj } },
        .{ .name = "time", .value = .{ .object = time_obj } },
        .{ .name = "hex", .value = .{ .object = hex_obj } },
        .{ .name = "base64", .value = .{ .object = base64_obj } },
        .{ .name = "regexp", .value = .{ .object = regexp_obj } },
        .{ .name = "sort", .value = .{ .object = sort_obj } },
        .{ .name = "array", .value = .{ .object = array_obj } },
        .{ .name = "bytes", .value = .{ .object = bytes_obj } },
        .{ .name = "Arg",      .value = .{ .object = arg_type_obj } },
        .{ .name = "Time",     .value = .{ .object = time_type_obj } },
        .{ .name = "Regexp",   .value = .{ .object = regexp_type_obj } },
        .{ .name = "JSONValue",.value = .{ .object = jv_type_obj } },
    };
    const std_obj = try makeNamespace(ctx,"std", "@module_type:std", &std_entries);
    ctx.vs.std_module = std_obj;
    return std_obj;
}

pub fn installStdGlobal(ctx: vms.VMContext, gs: *globals.State) !void {
    if (gs.has(module_compile.StdModuleGlobalName)) return;
    const std_obj = try buildStdModule(ctx);
    try gs.def(module_compile.StdModuleGlobalName, .{ .object = std_obj });
    try registerNativeTypeGlobal(gs, module_descriptor.ArgQualifiedName, ctx.vs.arg_type_cache.?);
    try registerNativeTypeGlobal(gs, module_descriptor.TimeQualifiedName, ctx.vs.time_type_cache.?);
    try registerNativeTypeGlobal(gs, module_descriptor.RegexpQualifiedName, ctx.vs.regexp_type_cache.?);
    try registerNativeTypeGlobal(gs, module_descriptor.JsonValueQualifiedName, ctx.vs.jv_type_cache.?);
    // Register leaf-node globals for direct-call optimization.
    // Each "module:std.{ns}.{func}" global allows the compiler to emit a single
    // get_global instead of get_global "module:std" + get_field chain + call.
    if (std_obj.* == .struct_instance) {
        const prefix = module_compile.StdModuleGlobalName;
        const top_fields = std_obj.struct_instance.fields;
        for (top_fields) |top_entry| {
            const ns_val = top_entry.value;
            const top_key = try vms.asStringValue(top_entry.key);
            if (ns_val == .object and ns_val.object.* == .struct_instance) {
                const ns_name = top_key;
                const ns_fields = ns_val.object.struct_instance.fields;
                for (ns_fields) |fe| {
                    const fe_key = try vms.asStringValue(fe.key);
                    const needed = prefix.len + 1 + ns_name.len + 1 + fe_key.len;
                    const gbuf = (ctx.hs.bump(u8, needed) orelse return error.OutOfMemory)[0..needed];
                    @memcpy(gbuf[0..prefix.len], prefix);
                    gbuf[prefix.len] = '.';
                    @memcpy(gbuf[prefix.len + 1 .. prefix.len + 1 + ns_name.len], ns_name);
                    gbuf[prefix.len + 1 + ns_name.len] = '.';
                    @memcpy(gbuf[prefix.len + 2 + ns_name.len .. needed], fe_key);
                    if (!gs.has(gbuf)) try gs.def(gbuf, fe.value);
                }
            } else {
                const needed = prefix.len + 1 + top_key.len;
                const gbuf = (ctx.hs.bump(u8, needed) orelse return error.OutOfMemory)[0..needed];
                @memcpy(gbuf[0..prefix.len], prefix);
                gbuf[prefix.len] = '.';
                @memcpy(gbuf[prefix.len + 1 .. needed], top_key);
                if (!gs.has(gbuf)) try gs.def(gbuf, ns_val);
            }
        }
    }
    {
        const exec_buf = (ctx.hs.bump(u8, 64) orelse return error.OutOfMemory)[0..64];
        const exec_key = std.fmt.bufPrint(exec_buf, "{s}.{s}", .{ TemplateTypeQualifiedName, "execute" }) catch return error.OutOfMemory;
        if (!gs.has(exec_key)) {
            const exec_native = try makeNative(ctx, .template_execute, 2);
            try gs.def(exec_key, exec_native);
        }
        const af_buf = (ctx.hs.bump(u8, 64) orelse return error.OutOfMemory)[0..64];
        const af_key = std.fmt.bufPrint(af_buf, "{s}.{s}", .{ TemplateTypeQualifiedName, "add_func" }) catch return error.OutOfMemory;
        if (!gs.has(af_key)) {
            const af_native = try makeNative(ctx, .template_add_func, 3);
            try gs.def(af_key, af_native);
        }
    }
    try installNativeMethods(ctx, gs, &module_descriptor.timeMethods);
    try installNativeMethods(ctx, gs, &module_descriptor.regexpMethods);
}

fn registerNativeTypeGlobal(gs: *globals.State, name: []const u8, typ: *Object) !void {
    if (!gs.has(name)) try gs.def(name, .{ .object = typ });
}

fn installNativeMethods(ctx: vms.VMContext, gs: *globals.State, methods: []const module_descriptor.NativeMethod) !void {
    for (methods) |method| {
        if (!gs.has(method.global_name)) {
            try gs.def(method.global_name, try makeNative(ctx, method.id, method.arity));
        }
    }
}

pub fn installHostModules(ctx: vms.VMContext, gs: *globals.State, host_modules: []const module_compile.HostModuleDesc) !void {
    for (host_modules) |hm| {
        const global_name_buf = (ctx.hs.bump(u8, 5 + hm.name.len) orelse return error.OutOfMemory)[0 .. 5 + hm.name.len];
        @memcpy(global_name_buf[0..5], "host:");
        @memcpy(global_name_buf[5..][0..hm.name.len], hm.name);
        const global_name = global_name_buf[0 .. 5 + hm.name.len];
        if (gs.has(global_name)) continue;

        const entries = hm.functions;
        const any_alts = ctx.hs.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
        any_alts[0] = .{ .typ = .any };
        const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };

        const field_specs = (ctx.hs.bump(StructFieldSpec, entries.len) orelse return error.OutOfMemory)[0..entries.len];
        for (field_specs, 0..) |*fs, i| {
            fs.* = .{ .name = entries[i].name, .typ = any_spec, .is_const = true };
        }

        const qual_name_buf = (ctx.hs.bump(u8, 13 + hm.name.len) orelse return error.OutOfMemory)[0 .. 13 + hm.name.len];
        @memcpy(qual_name_buf[0..13], "@module_type:");
        @memcpy(qual_name_buf[13..][0..hm.name.len], hm.name);
        const qualified_name = qual_name_buf[0 .. 13 + hm.name.len];

        const typ_obj = try vmgc.vmAllocObject(ctx);
        try ctx.vs.pushTempRoot(.{ .object = typ_obj });
        defer ctx.vs.popTempRoot();
        typ_obj.* = .{ .struct_type = StructTypeObj{
            .name = hm.name,
            .qualified_name = qualified_name,
            .fields = field_specs[0..entries.len],
        } };

        const inst_fields = try vmgc.vmAllocManagedSlice(ctx, MapEntry, entries.len);
        const inst_obj = try vmgc.vmAllocObject(ctx);
        try ctx.vs.pushTempRoot(.{ .object = inst_obj });
        defer ctx.vs.popTempRoot();
        inst_obj.* = .{ .struct_instance = .{ .typ = typ_obj, .fields = inst_fields } };

        for (inst_fields, 0..) |*fld, i| {
            const func_obj = try vmgc.vmAllocObject(ctx);
            func_obj.* = .{ .host_module_function = .{
                .call_id = entries[i].call_id,
                .arity = entries[i].arity,
            } };
            fld.* = .{
                .key = .{ .string = try ctx.cs.internStr(entries[i].name) },
                .value = .{ .object = func_obj },
            };
        }

        try gs.def(global_name, .{ .object = inst_obj });
    }
}

pub fn installCapabilityModules(ctx: vms.VMContext, gs: *globals.State, cap_modules: []const module_compile.CapModuleDesc) !void {
    for (cap_modules) |cm| {
        const global_name_buf = (ctx.hs.bump(u8, 4 + cm.name.len) orelse return error.OutOfMemory)[0 .. 4 + cm.name.len];
        @memcpy(global_name_buf[0..4], "cap:");
        @memcpy(global_name_buf[4..][0..cm.name.len], cm.name);
        const global_name = global_name_buf[0 .. 4 + cm.name.len];
        if (gs.has(global_name)) continue;

        const entries = cm.functions;
        const any_alts = ctx.hs.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
        any_alts[0] = .{ .typ = .any };
        const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };

        // Collect unique namespace prefixes (from dotted function names like "local.read").
        var ns_names: [64][]const u8 = undefined;
        var ns_count: usize = 0;
        for (entries) |entry| {
            const dot = std.mem.indexOfScalar(u8, entry.name, '.') orelse continue;
            const prefix = entry.name[0..dot];
            var seen = false;
            for (ns_names[0..ns_count]) |n| {
                if (std.mem.eql(u8, n, prefix)) {
                    seen = true;
                    break;
                }
            }
            if (!seen and ns_count < ns_names.len) {
                ns_names[ns_count] = prefix;
                ns_count += 1;
            }
        }
        var direct_count: usize = 0;
        for (entries) |entry| {
            if (std.mem.indexOfScalar(u8, entry.name, '.') == null) direct_count += 1;
        }
        const top_count = direct_count + ns_count;

        const field_specs = (ctx.hs.bump(StructFieldSpec, top_count) orelse return error.OutOfMemory)[0..top_count];
        var fi: usize = 0;
        for (entries) |entry| {
            if (std.mem.indexOfScalar(u8, entry.name, '.') == null) {
                field_specs[fi] = .{ .name = entry.name, .typ = any_spec, .is_const = true };
                fi += 1;
            }
        }
        for (ns_names[0..ns_count]) |ns| {
            field_specs[fi] = .{ .name = ns, .typ = any_spec, .is_const = true };
            fi += 1;
        }

        const qual_name_buf = (ctx.hs.bump(u8, 10 + cm.name.len) orelse return error.OutOfMemory)[0 .. 10 + cm.name.len];
        @memcpy(qual_name_buf[0..10], "@cap_type:");
        @memcpy(qual_name_buf[10..][0..cm.name.len], cm.name);
        const qualified_name = qual_name_buf[0 .. 10 + cm.name.len];

        const typ_obj = try vmgc.vmAllocObject(ctx);
        try ctx.vs.pushTempRoot(.{ .object = typ_obj });
        defer ctx.vs.popTempRoot();
        typ_obj.* = .{ .struct_type = StructTypeObj{
            .name = cm.name,
            .qualified_name = qualified_name,
            .fields = field_specs[0..top_count],
        } };

        const inst_fields = try vmgc.vmAllocManagedSlice(ctx, MapEntry, top_count);
        const inst_obj = try vmgc.vmAllocObject(ctx);
        try ctx.vs.pushTempRoot(.{ .object = inst_obj });
        defer ctx.vs.popTempRoot();
        inst_obj.* = .{ .struct_instance = .{ .typ = typ_obj, .fields = inst_fields } };

        // Fill direct function fields.
        fi = 0;
        for (entries) |entry| {
            if (std.mem.indexOfScalar(u8, entry.name, '.') != null) continue;
            const func_obj = try vmgc.vmAllocObject(ctx);
            func_obj.* = .{ .native_function = .{ .id = entry.native_id, .arity = entry.arity } };
            inst_fields[fi] = .{ .key = .{ .string = try ctx.cs.internStr(entry.name) }, .value = .{ .object = func_obj } };
            fi += 1;
        }

        // Build a sub-struct for each namespace prefix.
        for (ns_names[0..ns_count]) |ns| {
            var sub_count: usize = 0;
            for (entries) |entry| {
                if (entry.name.len > ns.len and
                    std.mem.startsWith(u8, entry.name, ns) and
                    entry.name[ns.len] == '.') sub_count += 1;
            }

            const sub_field_specs = (ctx.hs.bump(StructFieldSpec, sub_count) orelse return error.OutOfMemory)[0..sub_count];
            var si: usize = 0;
            for (entries) |entry| {
                if (entry.name.len > ns.len and
                    std.mem.startsWith(u8, entry.name, ns) and
                    entry.name[ns.len] == '.')
                {
                    sub_field_specs[si] = .{ .name = entry.name[ns.len + 1 ..], .typ = any_spec, .is_const = true };
                    si += 1;
                }
            }

            const sub_qual_len = 10 + cm.name.len + 1 + ns.len;
            const sub_qual_buf = (ctx.hs.bump(u8, sub_qual_len) orelse return error.OutOfMemory)[0..sub_qual_len];
            @memcpy(sub_qual_buf[0..10], "@cap_type:");
            @memcpy(sub_qual_buf[10..][0..cm.name.len], cm.name);
            sub_qual_buf[10 + cm.name.len] = '.';
            @memcpy(sub_qual_buf[10 + cm.name.len + 1 ..][0..ns.len], ns);

            const sub_typ_obj = try vmgc.vmAllocObject(ctx);
            try ctx.vs.pushTempRoot(.{ .object = sub_typ_obj });
            defer ctx.vs.popTempRoot();
            sub_typ_obj.* = .{ .struct_type = StructTypeObj{
                .name = ns,
                .qualified_name = sub_qual_buf[0..sub_qual_len],
                .fields = sub_field_specs[0..sub_count],
            } };

            const sub_inst_fields = try vmgc.vmAllocManagedSlice(ctx, MapEntry, sub_count);
            const sub_inst_obj = try vmgc.vmAllocObject(ctx);
            try ctx.vs.pushTempRoot(.{ .object = sub_inst_obj });
            defer ctx.vs.popTempRoot();
            sub_inst_obj.* = .{ .struct_instance = .{ .typ = sub_typ_obj, .fields = sub_inst_fields } };

            si = 0;
            for (entries) |entry| {
                if (entry.name.len > ns.len and
                    std.mem.startsWith(u8, entry.name, ns) and
                    entry.name[ns.len] == '.')
                {
                    const func_obj = try vmgc.vmAllocObject(ctx);
                    func_obj.* = .{ .native_function = .{ .id = entry.native_id, .arity = entry.arity } };
                    sub_inst_fields[si] = .{
                        .key = .{ .string = try ctx.cs.internStr(entry.name[ns.len + 1 ..]) },
                        .value = .{ .object = func_obj },
                    };
                    si += 1;
                }
            }

            inst_fields[fi] = .{ .key = .{ .string = try ctx.cs.internStr(ns) }, .value = .{ .object = sub_inst_obj } };
            fi += 1;
        }

        try gs.def(global_name, .{ .object = inst_obj });

        if (comptime build_options.cap_http) {
            if (std.mem.eql(u8, cm.name, "http") and !gs.has("@cap_type:http.Response")) {
                try cap_http_mod.registerResponseType(ctx, gs);
            }
        }

        if (comptime build_options.cap_net) {
            if (std.mem.eql(u8, cm.name, "net") and !gs.has("@cap_type:net.Conn")) {
                const conn_qual_name = "@cap_type:net.Conn";

                const conn_any_alts = ctx.hs.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
                conn_any_alts[0] = .{ .typ = .any };
                const conn_any_spec: FieldTypeSpec = .{ .alts = conn_any_alts[0..1] };

                const conn_field_specs = (ctx.hs.bump(StructFieldSpec, 1) orelse return error.OutOfMemory)[0..1];
                conn_field_specs[0] = .{ .name = "_handle", .typ = conn_any_spec, .is_const = true };

                const conn_typ_obj = try vmgc.vmAllocObject(ctx);
                try ctx.vs.pushTempRoot(.{ .object = conn_typ_obj });
                defer ctx.vs.popTempRoot();
                conn_typ_obj.* = .{ .struct_type = StructTypeObj{
                    .name = "Conn",
                    .qualified_name = conn_qual_name,
                    .fields = conn_field_specs[0..1],
                } };
                try gs.def(conn_qual_name, .{ .object = conn_typ_obj });

                const conn_methods = [_]struct { name: []const u8, id: NativeFnId, arity: u8 }{
                    .{ .name = "read", .id = .cap_net_read, .arity = 2 },
                    .{ .name = "write", .id = .cap_net_write, .arity = 2 },
                    .{ .name = "close", .id = .cap_net_close, .arity = 1 },
                    .{ .name = "local_addr", .id = .cap_net_local_addr, .arity = 1 },
                    .{ .name = "remote_addr", .id = .cap_net_remote_addr, .arity = 1 },
                    .{ .name = "set_deadline", .id = .cap_net_set_deadline, .arity = 2 },
                    .{ .name = "set_read_deadline", .id = .cap_net_set_read_deadline, .arity = 2 },
                    .{ .name = "set_write_deadline", .id = .cap_net_set_write_deadline, .arity = 2 },
                };
                for (conn_methods) |m| {
                    const needed = conn_qual_name.len + 1 + m.name.len;
                    const kbuf = (ctx.hs.bump(u8, needed) orelse return error.OutOfMemory)[0..needed];
                    @memcpy(kbuf[0..conn_qual_name.len], conn_qual_name);
                    kbuf[conn_qual_name.len] = '.';
                    @memcpy(kbuf[conn_qual_name.len + 1 .. needed], m.name);
                    if (!gs.has(kbuf)) {
                        const n = try makeNative(ctx, m.id, m.arity);
                        try gs.def(kbuf, n);
                    }
                }
            }
        }
    }
}

pub fn callHostModule(ctx: vms.VMContext, hmf: HostModuleFuncObj, argc: u8) !void {
    if (hmf.arity != 255 and hmf.arity != argc) return error.ArityMismatch;
    if (argc > MaxNativeArgs) return error.ArityMismatch;
    if (ctx.vs.policy.native_backend != .host) return error.HostNativeUnsupported;
    try host_abi_mod.ensureHostReady(ctx);
    const start = ctx.vs.stack_top - argc;
    var args_wire: [MaxNativeArgs]host_abi.ValueWire = undefined;
    for (args_wire[0..argc], ctx.vs.stack[start .. start + argc]) |*w, v| w.* = try host_abi_mod.wireFromValue(ctx, v);
    var out_wire = host_abi_mod.nullWire();
    try host_abi_mod.nativeCallRawChecked(hmf.call_id, args_wire[0..argc], &out_wire);
    for (0..@as(usize, argc) + 1) |_| _ = try ctx.vs.vmPop();
    const out = try host_abi_mod.valueFromWire(ctx, out_wire);
    try ctx.vs.vmPush(out);
}

pub fn callNative(ctx: vms.VMContext, nf: NativeFuncObj, argc: u8) !void {
    const temp_root_base = ctx.vs.tempRootDepth();
    defer ctx.vs.assertTempRootDepth(temp_root_base, "native dispatch");
    vmperf.countHostcall(nf.id);
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .io_println, .io_print, .io_printf, .io_sprintf, .io_eprint, .io_eprintf, .io_eprintln, .io_read, .io_readline, .fmt_stringify => return io_mod.dispatch(ctx, nf, argc),
        .core_len, .core_append, .core_error, .core_is_error, .core_gc, .core_gc_live_objects, .core_gc_stats, .core_bytelen, .core_gc_stats_ext, .core_delete, .core_has, .core_keys, .core_values, .core_contains, .core_remove, .core_type_of, .core_is_int, .core_is_float, .core_is_string, .core_is_array, .core_is_map, .core_is_struct, .core_is_null, .core_deep_equal, .core_clone, .core_recover => return core_mod.dispatch(ctx, nf, argc),
        .conv_to_int, .conv_to_float, .conv_to_bool, .conv_to_string => return conv_mod.dispatch(ctx, nf, argc),
        .math_abs, .math_sqrt, .math_floor, .math_ceil, .math_round, .math_sin, .math_cos, .math_tan, .math_log, .math_log2, .math_log10, .math_pow, .math_min, .math_max, .math_acos, .math_asin, .math_atan, .math_atan2, .math_cosh, .math_sinh, .math_tanh, .math_exp, .math_exp2, .math_trunc, .math_cbrt, .math_hypot, .math_mod, .math_nan, .math_is_nan, .math_is_inf, .math_clamp, .math_sign => return math_mod.dispatch(ctx, nf, argc),
        .rand_float, .rand_intn, .rand_between, .rand_seed, .rand_choice, .rand_perm, .rand_norm_float => return rand_mod.dispatch(ctx, nf, argc),
        .str_split, .str_join, .str_trim, .str_upper, .str_lower, .str_contains, .str_starts_with, .str_ends_with, .str_index_of, .str_replace, .str_last_index_of, .str_repeat, .str_split_once, .str_builder_new, .str_count, .str_fields, .str_pad_left, .str_pad_right, .str_equal_fold, .str_contains_any, .str_trim_left, .str_trim_right, .str_trim_prefix, .str_trim_suffix, .str_split_n => return string_mod.dispatch(ctx, nf, argc),
        .json_parse, .json_stringify, .json_valid, .json_indent, .json_parse_value => return json_mod.dispatch(ctx, nf, argc),
        .hex_encode, .hex_decode, .base64_encode, .base64_decode, .base64_url_encode, .base64_url_decode => return encode_mod.dispatch(ctx, nf, argc),
        .template_parse, .template_execute, .template_add_func, .template_render, .template_valid => return template_mod.dispatch(ctx, nf, argc),
        .time_now, .time_from_unix, .time_from_unix_ms, .time_parse, .time_unix, .time_unix_ms, .time_parts, .time_format, .time_add_ms, .time_add_s, .time_add_m, .time_add_h, .time_sub, .time_before, .time_after, .time_equal, .time_is_zero, .time_since, .time_until, .time_add_date, .time_parse_duration, .time_iso_week => return time_mod.dispatch(ctx, nf, argc),
        .re_match, .re_find, .re_find_all, .re_replace, .re_split, .re_compile, .re_obj_match, .re_obj_find, .re_obj_find_all, .re_obj_replace, .re_obj_split => return regexp_mod.dispatch(ctx, nf, argc),
        .array_filter, .array_map, .array_reduce, .array_slice, .array_zip, .array_flat, .array_find, .array_find_index, .array_all, .array_any, .array_chunk => return array_mod.dispatch(ctx, nf, argc),
        .sort_asc, .sort_desc, .sort_by => return sort_mod.dispatch(ctx, nf, argc),
        .bytes_u8, .bytes_pack, .bytes_unpack, .bytes_at, .bytes_len, .bytes_slice, .bytes_repeat, .bytes_u16be, .bytes_u32be, .bytes_u64be, .bytes_u16le, .bytes_u32le, .bytes_u64le, .bytes_u16be_at, .bytes_u32be_at, .bytes_u64be_at, .bytes_u16le_at, .bytes_u32le_at, .bytes_u64le_at, .bytes_index_of, .bytes_contains, .bytes_starts_with, .bytes_ends_with, .bytes_count, .bytes_replace, .bytes_f32be, .bytes_f32le, .bytes_f64be, .bytes_f64le, .bytes_f32be_at, .bytes_f32le_at, .bytes_f64be_at, .bytes_f64le_at => return bytes_mod.dispatch(ctx, nf, argc),
        inline else => |id| {
            if (comptime build_options.cap_net) {
                switch (id) {
                    .cap_net_dial, .cap_net_read, .cap_net_write, .cap_net_close, .cap_net_local_addr, .cap_net_remote_addr, .cap_net_set_deadline, .cap_net_set_read_deadline, .cap_net_set_write_deadline => return cap_net_mod.dispatch(ctx, nf, argc),
                    else => {},
                }
            }
            if (comptime build_options.cap_fs) {
                switch (id) {
                    .cap_fs_read,
                    .cap_fs_exists,
                    .cap_fs_write,
                    .cap_fs_list,
                    .cap_fs_delete,
                    .cap_fs_mkdir,
                    => return cap_fs_mod.dispatch(ctx, nf, argc),
                    else => {},
                }
            }
            if (comptime build_options.cap_http) {
                switch (id) {
                    .cap_http_get, .cap_http_post, .cap_http_fetch => return cap_http_mod.dispatch(ctx, nf, argc),
                    else => {},
                }
            }
            if (comptime build_options.cap_env) {
                switch (id) {
                    .cap_env_get, .cap_env_list => return cap_env_mod.dispatch(ctx, nf, argc),
                    else => {},
                }
            }
            return error.NativeFunctionNotFound;
        },
    }
}
