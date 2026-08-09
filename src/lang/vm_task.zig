// send() native behavior and the sendability/clone-at-send mechanics
// behind it — dev-docs/design/task-actor-design.md §3.4, §5. Dispatched
// from vm.zig's opInvokeMethod for .actor_ref receivers.
//
// monitor()/§6 (death notification) is deliberately not implemented —
// cut from v0 scope on audit: it's a genuinely separate feature (watcher
// lists, a death-reason payload, a notification shape) bolted onto the
// spawn/send/receive/self() core, not required for that core to be
// useful. Revisit once the core has seen real use.
//
// v0 scope note: the design's static message-type checking at send()
// is not implemented yet (see task-examples/FINDINGS.md #2 —
// receive() returns `any` for now, so there is no declared message
// type to check a send against). Tightening this later is additive,
// not a breaking change to what's already sendable.

const std = @import("std");
const vms = @import("vm_state.zig");
const VMContext = vms.VMContext;
const vmod = @import("value.zig");
const Value = vmod.Value;
const tasks_mod = @import("task_state.zig");
const vmnative = @import("native/core.zig");

const MaxSendDepth = 64;

// Whether `v` may cross a task boundary (spawn args, message payloads).
//
// Deliberately an ALLOWLIST, not a denylist: the switch is exhaustive
// (no `else`), so adding a new ObjTag anywhere else in the codebase is
// a compile error here until someone decides which bucket it belongs
// in. A denylist's default is "safe unless I remember to list it here"
// — exactly backwards for a check whose entire job is to keep unsafe
// values from crossing the isolation boundary, and exactly the kind of
// silent-drift hazard this session's exhaustive-switch sweeps (ObjTag,
// FieldTypeTag, VTag) kept catching elsewhere. A forgotten case here
// fails LOUD (compile error) instead of quiet (new native-resource type
// shared across tasks by default).
fn isSendable(v: Value, depth: u32) bool {
    if (depth >= MaxSendDepth) return false; // matches clone's depth posture: bounded, not unbounded
    if (v != .object) return true;
    return switch (v.object.*) {
        // Shared mutable state or a native resource: unsafe to let two
        // tasks reference. .function/.closure share upvalue cells;
        // .cell IS an upvalue cell; .iterator holds a native position
        // plus a source pointer into one specific heap value.
        .function, .closure, .cell, .iterator => false,
        .array, .array_managed, .array_view, .array_capacity => blk: {
            const items = vms.asArraySlice(v.object) catch break :blk false;
            for (items) |item| if (!isSendable(item, depth + 1)) break :blk false;
            break :blk true;
        },
        .map, .map_managed, .map_hashed => blk: {
            const entries = vms.asMapSlice(v.object) catch break :blk false;
            for (entries) |e| {
                if (!isSendable(e.key, depth + 1)) break :blk false;
                if (!isSendable(e.value, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .struct_instance => |inst| blk: {
            for (inst.fields) |f| if (!isSendable(f.value, depth + 1)) break :blk false;
            break :blk true;
        },
        .small_struct_instance => |ssi| blk: {
            for (0..@as(usize, ssi.count)) |i| if (!isSendable(ssi.v[i], depth + 1)) break :blk false;
            break :blk true;
        },
        .named_value => |nv| isSendable(nv.value, depth + 1),
        .variant_value => |vv| blk: {
            if (!isSendable(vv.payload, depth + 1)) break :blk false;
            for (vv.shared_values) |sv| if (!isSendable(sv, depth + 1)) break :blk false;
            for (vv.arm_fields) |af| if (!isSendable(af, depth + 1)) break :blk false;
            break :blk true;
        },
        // Immortal type/metadata objects (never mutated after
        // declaration — safe to share a pointer to, same reasoning as
        // §3.5's SharedOwner class) and immutable-or-clones-independent
        // leaf data: nothing further to walk, nothing unsafe to share.
        // string_builder is mutable but cloneObject deep-copies its
        // buffer, so the sender and receiver end up with independent
        // copies, same as any other cloned composite.
        .dyn_string,
        .string_view,
        .native_function,
        .host_module_function,
        .struct_type,
        .interface_type,
        .named_type,
        .enum_type,
        .enum_value,
        .variant_type,
        .variant_ctor,
        .named_type_fn,
        .enum_type_fn,
        .string_builder,
        .bigint,
        .named_error_type,
        .named_error_value,
        .task_type,
        => true,
    };
}

// Clone `v` for delivery across a task boundary (message payload or
// spawn argument). Reuses the general clone engine (std.core.clone's —
// object identity/cycle-preserving deep copy) after checking
// sendability; the clone is rooted on the CALLING task's temp-root
// stack (ctx.vs) for GC safety during the copy — it doesn't need the
// destination task's own vm_state, since the shared heap (§3.2) is
// where the clone actually lives; the destination only needs the
// finished Value once it's pushed onto that task's own stack.
pub fn checkSendableAndClone(ctx: VMContext, v: Value) !Value {
    if (!isSendable(v, 0)) return error.NotSendable;
    return vmnative.nativeClone(ctx, v);
}

pub const SendError = error{NotSendable};

// §5: deep-copy at the crossing point, enqueue into the target's
// mailbox, wake it if it was parked in receive(). Resolves and drops
// silently for a dead/stale target — send never blocks and never fails
// visibly, matching real Erlang. Sender-side error only for a payload
// that isn't sendable at all (§3.4) — that is a program bug at the send
// site, not a routine "target might be gone" outcome.
pub fn send(ctx: VMContext, target: vmod.ActorRefValue, payload: Value) !void {
    const ts = tasks_mod.g_state;
    const idx = ts.resolveSameGeneration(target) orelse return; // stale ref: nothing to check against, just drop
    if (!ts.isAlive(idx)) return; // dead, slot not yet reused: silent drop (§5)
    const clone = try checkSendableAndClone(ctx, payload);
    try ctx.vs.pushTempRoot(clone);
    defer ctx.vs.popTempRoot();
    try ts.slots[idx].mailbox.append(ts.allocator, clone);
    if (ts.slots[idx].status == .blocked_receive) try ts.enqueueReady(idx);
}
