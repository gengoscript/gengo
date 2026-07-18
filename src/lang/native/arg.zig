const vmod = @import("../value.zig");
const Object = vmod.Object;
const VMContext = @import("../vm_state.zig").VMContext;

// Qualified name must match the "@mod:std.X" pattern the compiler builds
// when it resolves a type annotation written as `std.Arg`.
pub const ArgQualifiedName = @import("../module_descriptor.zig").ArgQualifiedName;

const arg_arms = [_]vmod.VariantArmSpec{
    .{ .name = "Int", .has_payload = true },
    .{ .name = "Float", .has_payload = true },
    .{ .name = "Decimal", .has_payload = true },
    .{ .name = "Rune", .has_payload = true },
    .{ .name = "Bool", .has_payload = true },
    .{ .name = "Str", .has_payload = true },
    .{ .name = "Err", .has_payload = true },
};

pub fn argGetType(ctx: VMContext) !*Object {
    if (ctx.vs.arg_type_cache) |t| return t;
    const buf = ctx.hs.bump(Object, 1) orelse return error.OutOfMemory;
    const obj: *Object = @ptrCast(buf);
    obj.* = .{ .variant_type = .{
        .name = "Arg",
        .qualified_name = ArgQualifiedName,
        .arms = &arg_arms,
    } };
    ctx.vs.arg_type_cache = obj;
    return obj;
}
