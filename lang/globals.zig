const common = @import("common.zig");
const Value = @import("value.zig").Value;

const MaxGlobals = 256;
const TableSize = 512; // keep load factor <= 0.5 at MaxGlobals
const GEntry = struct {
    name: []const u8 = "",
    value: Value = .null,
    occupied: bool = false,
};
var g_entries: [TableSize]GEntry = undefined;
var g_globals_len: usize = 0;

fn slotFor(name: []const u8) ?usize {
    const mask: usize = TableSize - 1;
    var idx: usize = @intCast(common.hashBytes(name) & mask);
    var probes: usize = 0;
    while (probes < TableSize) : (probes += 1) {
        const e = g_entries[idx];
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
        const e = g_entries[idx];
        if (!e.occupied or common.streq(e.name, name)) return idx;
        idx = (idx + 1) & mask;
    }
    return null;
}

pub fn reset() void {
    var i: usize = 0;
    while (i < TableSize) : (i += 1) g_entries[i] = .{};
    g_globals_len = 0;
}

pub fn get(name: []const u8) ?Value {
    const idx = slotFor(name) orelse return null;
    return g_entries[idx].value;
}

pub fn has(name: []const u8) bool {
    return slotFor(name) != null;
}

pub fn set(name: []const u8, value: Value) bool {
    const idx = slotFor(name) orelse return false;
    g_entries[idx].value = value;
    return true;
}

pub fn def(name: []const u8, value: Value) !void {
    if (g_globals_len >= MaxGlobals and !has(name)) return error.TooManyGlobals;
    const idx = slotForInsert(name) orelse return error.TooManyGlobals;
    if (!g_entries[idx].occupied) {
        g_entries[idx].occupied = true;
        g_entries[idx].name = name;
        g_globals_len += 1;
    }
    g_entries[idx].value = value;
}

pub fn len() usize {
    return g_globals_len;
}

pub fn valueAt(i: usize) Value {
    var seen: usize = 0;
    var slot: usize = 0;
    while (slot < TableSize) : (slot += 1) {
        if (!g_entries[slot].occupied) continue;
        if (seen == i) return g_entries[slot].value;
        seen += 1;
    }
    return .null;
}

pub fn nameAt(i: usize) []const u8 {
    var seen: usize = 0;
    var slot: usize = 0;
    while (slot < TableSize) : (slot += 1) {
        if (!g_entries[slot].occupied) continue;
        if (seen == i) return g_entries[slot].name;
        seen += 1;
    }
    return "";
}

pub fn debugSlotCount() usize {
    var n: usize = 0;
    var slot: usize = 0;
    while (slot < TableSize) : (slot += 1) {
        if (g_entries[slot].occupied) n += 1;
    }
    return n;
}
