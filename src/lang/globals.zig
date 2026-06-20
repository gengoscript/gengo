const common = @import("common.zig");
const Value = @import("value.zig").Value;

pub const MaxGlobals = 2048;
pub const TableSize = 4096; // power-of-two, keep load factor <= 0.5 at MaxGlobals
const GEntry = struct {
    name: []const u8 = "",
    value: Value = .null,
    compact_idx: u16 = 0,
    occupied: bool = false,
};
pub const State = struct {
    entries: [TableSize]GEntry = undefined,
    compact_values: [MaxGlobals]Value = undefined,
    globals_len: usize = 0,
};

var g_default_state: State = .{};
var g_state: *State = &g_default_state;

fn slotFor(name: []const u8) ?usize {
    const mask: usize = TableSize - 1;
    var idx: usize = @intCast(common.hashBytes(name) & mask);
    for (0..TableSize) |_| {
        const e = g_state.entries[idx];
        if (!e.occupied) return null;
        if (common.streq(e.name, name)) return idx;
        idx = (idx + 1) & mask;
    }
    return null;
}

fn slotForInsert(name: []const u8) ?usize {
    const mask: usize = TableSize - 1;
    var idx: usize = @intCast(common.hashBytes(name) & mask);
    for (0..TableSize) |_| {
        const e = g_state.entries[idx];
        if (!e.occupied or common.streq(e.name, name)) return idx;
        idx = (idx + 1) & mask;
    }
    return null;
}

pub fn reset() void {
    @memset(g_state.entries[0..TableSize], .{});
    g_state.globals_len = 0;
}

pub fn compactValue(i: usize) Value {
    return g_state.compact_values[i];
}

pub fn get(name: []const u8) ?Value {
    const idx = slotFor(name) orelse return null;
    return g_state.entries[idx].value;
}

// Returns the raw table slot index, or null if name not found. Used by IC.
pub fn findSlot(name: []const u8) ?u16 {
    return if (slotFor(name)) |idx| @intCast(idx) else null;
}

pub fn getAt(slot: u16) Value {
    if (slot >= TableSize) return .null;
    return g_state.entries[slot].value;
}

pub fn setAt(slot: u16, value: Value) void {
    if (slot >= TableSize) return;
    g_state.entries[slot].value = value;
    g_state.compact_values[g_state.entries[slot].compact_idx] = value;
}

pub fn has(name: []const u8) bool {
    return slotFor(name) != null;
}

pub fn set(name: []const u8, value: Value) bool {
    const idx = slotFor(name) orelse return false;
    g_state.entries[idx].value = value;
    g_state.compact_values[g_state.entries[idx].compact_idx] = value;
    return true;
}

pub fn def(name: []const u8, value: Value) !void {
    if (g_state.globals_len >= MaxGlobals and !has(name)) return error.TooManyGlobals;
    const idx = slotForInsert(name) orelse return error.TooManyGlobals;
    if (!g_state.entries[idx].occupied) {
        g_state.entries[idx].occupied = true;
        g_state.entries[idx].name = name;
        g_state.entries[idx].compact_idx = @intCast(g_state.globals_len);
        g_state.globals_len += 1;
    }
    g_state.entries[idx].value = value;
    g_state.compact_values[g_state.entries[idx].compact_idx] = value;
}

pub fn len() usize {
    return g_state.globals_len;
}

pub fn valueAt(i: usize) Value {
    var seen: usize = 0;
    for (g_state.entries[0..TableSize]) |e| {
        if (!e.occupied) continue;
        if (seen == i) return e.value;
        seen += 1;
    }
    return .null;
}

pub fn nameAt(i: usize) []const u8 {
    var seen: usize = 0;
    for (g_state.entries[0..TableSize]) |e| {
        if (!e.occupied) continue;
        if (seen == i) return e.name;
        seen += 1;
    }
    return "";
}

pub fn debugSlotCount() usize {
    var n: usize = 0;
    for (g_state.entries[0..TableSize]) |e| {
        if (e.occupied) n += 1;
    }
    return n;
}

pub fn setActive(state: *State) void {
    g_state = state;
}
