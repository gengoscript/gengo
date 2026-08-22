const std = @import("std");
const vms = @import("vm_state.zig");
const VMContext = vms.VMContext;
const heap = @import("../runtime/heap.zig");
const chunk = @import("chunk.zig");
const Op = @import("op.zig").Op;

/// Errors that represent VM integrity failures — not recoverable user errors.
/// When one of these fires, the correct response is always a hard stop with
/// diagnostics, never a user-visible panic that unwinds through script frames.
pub const Error = error{
    /// The compiled bytecode chunk has an impossible instruction sequence
    /// (unknown opcode, out-of-bounds jump target, impossible back-edge offset).
    InvalidChunkShape,

    /// An object pointer was used after it became dead, or points outside the
    /// object pool entirely. Indicates a GC root-tracking bug.
    /// Note: detection requires -Dheap_paranoia=true; see heap.zig assertNotLive.
    CorruptedObjectHandle,

    /// The temp-root stack push/pop is unbalanced: either overflow (more pushes
    /// than the fixed-size temp-root array allows) or underflow (pop when empty).
    BadTempRootDiscipline,

    /// An opcode was reached in a VM state that the compiler invariants guarantee
    /// can never occur (e.g. a `ret` opcode with frame_top == 0, or a
    /// `get_upvalue` in a frame with no closure).
    ImpossibleOpcodeState,

    /// The garbage collector detected an inconsistency in its own mark/sweep
    /// data structures (worklist exhausted, live view points to dead source).
    GCInvariantFailure,
};

/// Diagnostic snapshot of VM state at the moment of an integrity failure.
pub const Snapshot = struct {
    ip: usize,
    opcode: []const u8,
    frame_depth: usize,
    stack_top: usize,
    temp_root_depth: usize,
    gc_live_count: usize,
};

pub fn capture(ctx: VMContext) Snapshot {
    const state = ctx.vs;
    const op_name = blk: {
        const ip = state.ip;
        if (ip > 0 and ip - 1 < ctx.cs.codeLen()) {
            const raw = ctx.cs.codeByteAt(ip - 1);
            if (raw < std.meta.fields(Op).len) {
                break :blk @tagName(@as(Op, @enumFromInt(raw)));
            }
        }
        break :blk "?";
    };
    return .{
        .ip = state.ip,
        .opcode = op_name,
        .frame_depth = state.frame_top,
        .stack_top = state.stack_top,
        .temp_root_depth = state.temp_root_top,
        .gc_live_count = ctx.hs.liveObjectCount(),
    };
}

/// Returns true if err is a VM integrity failure rather than a recoverable
/// user-program error.
pub fn isIntegrityError(err: anyerror) bool {
    return switch (err) {
        error.InvalidChunkShape,
        error.CorruptedObjectHandle,
        error.BadTempRootDiscipline,
        error.ImpossibleOpcodeState,
        error.GCInvariantFailure,
        => true,
        else => false,
    };
}

/// Hard-stop with a structured diagnostic. Captures VM state and calls
/// std.debug.panic — this path never unwinds to user code.
pub fn fatal(ctx: VMContext, err: anyerror) noreturn {
    const snap = capture(ctx);
    std.debug.panic(
        "VM integrity failure [{s}] op={s} ip={d} frames={d} stack={d} temp_roots={d} gc_live={d}",
        .{
            @errorName(err),
            snap.opcode,
            snap.ip,
            snap.frame_depth,
            snap.stack_top,
            snap.temp_root_depth,
            snap.gc_live_count,
        },
    );
}

const testing = std.testing;

test "capture snapshots a fresh VM's zeroed state and reports the unknown opcode" {
    const Runtime = @import("../runtime/runtime.zig").Runtime;
    var rt: Runtime = undefined;
    rt.initWithPolicy(.{ .allow_io = false }) catch return error.TestFailed;
    defer rt.deinit();
    const ctx = VMContext.fromActive();

    const snap = capture(ctx);
    try testing.expectEqual(@as(usize, 0), snap.ip);
    try testing.expectEqualStrings("?", snap.opcode);
    try testing.expectEqual(@as(usize, 0), snap.frame_depth);
    try testing.expectEqual(@as(usize, 0), snap.stack_top);
    try testing.expectEqual(@as(usize, 0), snap.temp_root_depth);
}

test "isIntegrityError classifies VM-integrity errors as true and everything else as false" {
    try testing.expect(isIntegrityError(error.InvalidChunkShape));
    try testing.expect(isIntegrityError(error.CorruptedObjectHandle));
    try testing.expect(isIntegrityError(error.BadTempRootDiscipline));
    try testing.expect(isIntegrityError(error.ImpossibleOpcodeState));
    try testing.expect(isIntegrityError(error.GCInvariantFailure));

    try testing.expect(!isIntegrityError(error.TypeError));
    try testing.expect(!isIntegrityError(error.OutOfMemory));
}
