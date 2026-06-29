const std = @import("std");
const vms = @import("vm_state.zig");
const heap = @import("../runtime/heap.zig");

/// Errors that represent VM integrity failures — not recoverable user errors.
/// When one of these fires, the correct response is always a hard stop with
/// diagnostics, never a user-visible panic that unwinds through script frames.
pub const Error = error{
    /// The compiled bytecode chunk has an impossible instruction sequence
    /// (unknown opcode, out-of-bounds jump target, impossible back-edge offset).
    InvalidChunkShape,

    /// An object pointer was used after it became dead, or points outside the
    /// object pool entirely. Indicates a GC root-tracking bug.
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
    frame_depth: usize,
    stack_top: usize,
    temp_root_depth: usize,
    gc_live_count: usize,
};

pub fn capture() Snapshot {
    const state = vms.vmState();
    return .{
        .ip = state.ip,
        .frame_depth = state.frame_top,
        .stack_top = state.stack_top,
        .temp_root_depth = state.temp_root_top,
        .gc_live_count = heap.liveObjectCount(),
    };
}

/// Returns true if err is a VM integrity failure rather than a recoverable
/// user-program error. Covers both the new named errors and legacy names that
/// the chunk verifier still uses.
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
/// std.debug.panic — this path is never supposed to unwind to user code.
pub fn fatal(err: anyerror) noreturn {
    const snap = capture();
    std.debug.panic(
        "VM integrity failure [{s}] ip={d} frames={d} stack={d} temp_roots={d} gc_live={d}",
        .{
            @errorName(err),
            snap.ip,
            snap.frame_depth,
            snap.stack_top,
            snap.temp_root_depth,
            snap.gc_live_count,
        },
    );
}
