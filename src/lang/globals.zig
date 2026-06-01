const common = @import("common.zig");
const Value = @import("value.zig").Value;

pub const MaxGlobals = 256;
pub const TableSize = 512; // keep load factor <= 0.5 at MaxGlobals
const GEntry = struct {
    name: []const u8 = "",
    value: Value = .null,
    occupied: bool = false,
};
pub const State = struct {
    entries: [TableSize]GEntry = undefined,
    globals_len: usize = 0,
};

var g_default_state: State = .{};
var g_state: *State = &g_default_state;

fn slotFor(name: []const u8) ?usize {
    const mask: usize = TableSize - 1;
    var idx: usize = @intCast(common.hashBytes(name) & mask);
    var probes: usize = 0;
    while (probes < TableSize) : (probes += 1) {
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
    var probes: usize = 0;
    while (probes < TableSize) : (probes += 1) {
        const e = g_state.entries[idx];
        if (!e.occupied or common.streq(e.name, name)) return idx;
        idx = (idx + 1) & mask;
    }
    return null;
}

pub fn reset() void {
    var i: usize = 0;
    while (i < TableSize) : (i += 1) g_state.entries[i] = .{};
    g_state.globals_len = 0;
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
    return g_state.entries[slot].value;
}

pub fn setAt(slot: u16, value: Value) void {
    g_state.entries[slot].value = value;
}

pub fn has(name: []const u8) bool {
    return slotFor(name) != null;
}

pub fn set(name: []const u8, value: Value) bool {
    const idx = slotFor(name) orelse return false;
    g_state.entries[idx].value = value;
    return true;
}

pub fn def(name: []const u8, value: Value) !void {
    if (g_state.globals_len >= MaxGlobals and !has(name)) return error.TooManyGlobals;
    const idx = slotForInsert(name) orelse return error.TooManyGlobals;
    if (!g_state.entries[idx].occupied) {
        g_state.entries[idx].occupied = true;
        g_state.entries[idx].name = name;
        g_state.globals_len += 1;
    }
    g_state.entries[idx].value = value;
}

pub fn len() usize {
    return g_state.globals_len;
}

pub fn valueAt(i: usize) Value {
    var seen: usize = 0;
    var slot: usize = 0;
    while (slot < TableSize) : (slot += 1) {
        if (!g_state.entries[slot].occupied) continue;
        if (seen == i) return g_state.entries[slot].value;
        seen += 1;
    }
    return .null;
}

pub fn nameAt(i: usize) []const u8 {
    var seen: usize = 0;
    var slot: usize = 0;
    while (slot < TableSize) : (slot += 1) {
        if (!g_state.entries[slot].occupied) continue;
        if (seen == i) return g_state.entries[slot].name;
        seen += 1;
    }
    return "";
}

pub fn debugSlotCount() usize {
    var n: usize = 0;
    var slot: usize = 0;
    while (slot < TableSize) : (slot += 1) {
        if (g_state.entries[slot].occupied) n += 1;
    }
    return n;
}

pub fn setActive(state: *State) void {
    g_state = state;
}
