// Task/actor scheduler state — dev-docs/design/task-actor-design.md.
//
// One shared heap, one shared chunk/globals (unchanged process-wide state);
// what's new per task is its own vm_state.State (stack/frames/defer stack —
// "one thread of execution", per the design's §3.2), plus a mailbox and a
// watcher list that live outside Gengo value semantics entirely (native
// FIFOs, not Gengo arrays — §5).
//
// Slot 0 is permanently reserved as the null actor (never occupied by a
// real task); real tasks live in slots 1..MaxTasks-1. A slot's generation
// increments every time it is reused, so a stale ActorRef captured before
// a task died and its slot was reused for a new spawn compares unequal to
// the new occupant (§7 — the ABA guard).

const std = @import("std");
const builtin = @import("builtin");
const vm_state = @import("vm_state.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const cfg = @import("runtime_config");

// Ada-scale, not Erlang-scale, by design (§2): a modest number of
// long-lived concurrent units, not spawn-per-request swarms.
pub const MaxTasks = 64;

pub const TaskId = value_mod.ActorRefValue;

pub const TaskStatus = enum {
    empty, // slot never used, or fully reclaimed after death
    ready, // in the ready queue, waiting for a scheduler turn
    running, // currently the active task
    blocked_receive, // parked in receive() with an empty mailbox
    sleeping, // parked in std.time.sleep()
    dead, // finished (return/panic); generation still matches until reused
};

pub const TaskSlot = struct {
    generation: u32 = 0,
    status: TaskStatus = .empty,
    vs: ?*vm_state.State = null,
    // False for the main-program slot, whose vs is Runtime.vm_state — a
    // struct field, not a heap allocation this table owns. Destroying it
    // on clear() would be memory corruption, not a leak fix. True for
    // every spawned task, whose vm_state.State this table alloc'd itself
    // (claimSlot) and must free.
    owns_vs: bool = false,
    // Every task has a mailbox (§8.2's mailbox-less split was cut before
    // shipping — see compiler_decls.zig's taskDeclBody).
    mailbox: std.ArrayListUnmanaged(Value) = .empty,

    fn clear(self: *TaskSlot, allocator: std.mem.Allocator) void {
        if (self.owns_vs) {
            if (self.vs) |vs| {
                vs.deinit();
                allocator.destroy(vs);
            }
        }
        self.mailbox.deinit(allocator);
        self.* = .{ .generation = self.generation };
    }
};

pub const State = struct {
    slots: [MaxTasks]TaskSlot = [_]TaskSlot{.{}} ** MaxTasks,
    // Ready queue holds slot indices, strict FIFO (§4.2 — one global
    // ready queue, nothing ever jumps it).
    ready_queue: std.ArrayListUnmanaged(u32) = .empty,
    // Slot index of the task currently executing. 0 (the reserved null
    // slot) doubles as "no task is running yet / scheduler idle".
    current: u32 = 0,
    allocator: std.mem.Allocator = std.heap.page_allocator,

    pub fn reset(self: *State) void {
        for (self.slots[0..]) |*slot| slot.clear(self.allocator);
        self.ready_queue.clearRetainingCapacity();
        self.current = 0;
    }

    pub fn deinit(self: *State) void {
        for (self.slots[0..]) |*slot| slot.clear(self.allocator);
        self.ready_queue.deinit(self.allocator);
        self.* = .{};
    }

    pub fn idFor(self: *const State, idx: u32) TaskId {
        return .{ .index = idx, .generation = self.slots[idx].generation };
    }

    // ActorRef of the task currently executing. Only valid once the
    // scheduler has claimed a slot for the running program's own
    // top-level code (task_state.zig's caller does this before the first
    // instruction ever runs — see Runtime's scheduler entry point).
    pub fn currentId(self: *const State) TaskId {
        return self.idFor(self.current);
    }

    // Find a free slot (empty, or dead-and-being-recycled) and claim it —
    // bump its generation, install a fresh vm_state, mark it `.ready`
    // (caller still has to set up its initial call frame and actually
    // enqueue it). Slot 0 is never returned. Null if the table is full —
    // resource exhaustion, the caller reports this as a runtime error at
    // the spawn site (same family as TooManyGlobals).
    //
    // wasm32: rejected outright. vm_state.State's backing arrays
    // (stack/frames/defer_stack/panic_frames) point at ONE static struct
    // on this target (g_wasm_backing — see vm_state.zig), the same
    // aliasing hazard §3.1 rejected per-task Runtimes over in the first
    // place, just recurring one layer down: every vm_state.State.init()
    // call on wasm32 binds to that same singleton, so a second live
    // vm_state (main already holds the first) would silently alias
    // main's own stack — found by actually running the WASM conformance
    // suite, not by review; it corrupted state and produced wrong output
    // rather than crashing, which is a worse failure mode than what
    // this guard produces (a clean, immediate runtime error). The
    // design doc's §3.2 correction already named the real fix (a
    // build-time-sized per-task backing pool, mirroring the array
    // g_wasm_backing already is on struct_type's WasmBacking) — this
    // guard exists so the gap between "known and named" and "actually
    // built" doesn't mean silent corruption in the meantime.
    pub fn claimSlot(self: *State) !struct { idx: u32, id: TaskId } {
        if (comptime builtin.target.cpu.arch == .wasm32) return error.TasksNotYetSupportedOnWasm;
        var idx: u32 = 1;
        while (idx < MaxTasks) : (idx += 1) {
            const slot = &self.slots[idx];
            if (slot.status != .empty and slot.status != .dead) continue;
            if (slot.status == .dead) slot.clear(self.allocator);
            slot.generation +%= 1;
            // generation 0 is reserved for the permanently-empty/null
            // shape; skip it on wraparound so idFor() never mints a
            // TaskId indistinguishable from the null ref.
            if (slot.generation == 0) slot.generation = 1;
            // status is set to .ready only AFTER vs is fully created and
            // initialized (not before, as this used to do): a failure in
            // create()/init() (realistically OutOfMemory) must leave the
            // slot .empty and reclaimable by a later claimSlot call, not
            // stuck .ready with vs == null -- that used to permanently
            // remove the slot from the pool for the rest of the process's
            // life (an .empty/.dead check is all that lets a slot be
            // reused; .ready never matches either). Under sustained memory
            // pressure with repeated spawn attempts, this could exhaust
            // the task table and produce spurious TooManyTasks well before
            // 64 *live* tasks exist.
            const vs = try self.allocator.create(vm_state.State);
            errdefer self.allocator.destroy(vs);
            vs.* = .{};
            try vs.init(vm_state.MaxStack, vm_state.MaxFrames, cfg.max_defers, 0, self.allocator);
            slot.status = .ready;
            slot.vs = vs;
            slot.owns_vs = true;
            return .{ .idx = idx, .id = self.idFor(idx) };
        }
        return error.TooManyTasks;
    }

    // Register the running program's own top-level code as a task (§9 —
    // "main is task 0") in slot 1, reusing the caller-owned vm_state
    // (Runtime.vm_state) rather than allocating a fresh one — main's
    // execution state already exists and is not this table's to own or
    // free. Called once per run, right after reset() has cleared the
    // table.
    pub fn claimMainSlot(self: *State, vs: *vm_state.State) TaskId {
        const idx: u32 = 1;
        const slot = &self.slots[idx];
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.status = .ready;
        slot.vs = vs;
        slot.owns_vs = false;
        self.current = idx;
        return self.idFor(idx);
    }

    // Resolve an ActorRef to its slot index, without regard to whether the
    // task is currently alive — generation match is all that's checked.
    // Null means the slot has been recycled for a different task (or the
    // ref is out of range / the reserved null ref): per §5/§7, this is
    // the "nothing to check against, just drop" case. Use isAlive() on the
    // result to distinguish a live target from one that died with its
    // slot not yet reused.
    pub fn resolveSameGeneration(self: *const State, id: TaskId) ?u32 {
        if (id.index == 0 or id.index >= MaxTasks) return null;
        if (self.slots[id.index].generation != id.generation) return null;
        return id.index;
    }

    pub fn isAlive(self: *const State, idx: u32) bool {
        const st = self.slots[idx].status;
        return st != .empty and st != .dead;
    }

    pub fn enqueueReady(self: *State, idx: u32) !void {
        self.slots[idx].status = .ready;
        try self.ready_queue.append(self.allocator, idx);
    }

    pub fn popReady(self: *State) ?u32 {
        if (self.ready_queue.items.len == 0) return null;
        return self.ready_queue.orderedRemove(0);
    }
};

var g_default_state: State = .{};
pub threadlocal var g_state: *State = &g_default_state;

pub fn setActive(state: *State) void {
    g_state = state;
}

pub fn reset() void {
    g_state.reset();
}
