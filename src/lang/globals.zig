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

    fn slotFor(self: *const State, name: []const u8) ?usize {
        const mask: usize = TableSize - 1;
        var idx: usize = @intCast(common.hashBytes(name) & mask);
        for (0..TableSize) |_| {
            const e = self.entries[idx];
            if (!e.occupied) return null;
            if (common.streq(e.name, name)) return idx;
            idx = (idx + 1) & mask;
        }
        return null;
    }

    fn slotForInsert(self: *const State, name: []const u8) ?usize {
        const mask: usize = TableSize - 1;
        var idx: usize = @intCast(common.hashBytes(name) & mask);
        for (0..TableSize) |_| {
            const e = self.entries[idx];
            if (!e.occupied or common.streq(e.name, name)) return idx;
            idx = (idx + 1) & mask;
        }
        return null;
    }

    pub fn reset(self: *State) void {
        @memset(self.entries[0..TableSize], .{});
        self.globals_len = 0;
    }

    pub fn compactValue(self: *const State, i: usize) Value {
        return self.compact_values[i];
    }

    pub fn get(self: *const State, name: []const u8) ?Value {
        const idx = self.slotFor(name) orelse return null;
        return self.entries[idx].value;
    }

    pub fn findSlot(self: *const State, name: []const u8) ?u16 {
        return if (self.slotFor(name)) |idx| @intCast(idx) else null;
    }

    pub fn getAt(self: *const State, slot: u16) Value {
        if (slot >= TableSize) return .null;
        return self.entries[slot].value;
    }

    pub fn setAt(self: *State, slot: u16, value: Value) void {
        if (slot >= TableSize) return;
        self.entries[slot].value = value;
        self.compact_values[self.entries[slot].compact_idx] = value;
    }

    pub fn has(self: *const State, name: []const u8) bool {
        return self.slotFor(name) != null;
    }

    pub fn set(self: *State, name: []const u8, value: Value) bool {
        const idx = self.slotFor(name) orelse return false;
        self.entries[idx].value = value;
        self.compact_values[self.entries[idx].compact_idx] = value;
        return true;
    }

    pub fn def(self: *State, name: []const u8, value: Value) !void {
        if (self.globals_len >= MaxGlobals and !self.has(name)) return error.TooManyGlobals;
        const idx = self.slotForInsert(name) orelse return error.TooManyGlobals;
        if (!self.entries[idx].occupied) {
            self.entries[idx].occupied = true;
            self.entries[idx].name = name;
            self.entries[idx].compact_idx = @intCast(self.globals_len);
            self.globals_len += 1;
        }
        self.entries[idx].value = value;
        self.compact_values[self.entries[idx].compact_idx] = value;
    }

    pub fn len(self: *const State) usize {
        return self.globals_len;
    }

    pub fn valueAt(self: *const State, i: usize) Value {
        var seen: usize = 0;
        for (self.entries[0..TableSize]) |e| {
            if (!e.occupied) continue;
            if (seen == i) return e.value;
            seen += 1;
        }
        return .null;
    }

    pub fn nameAt(self: *const State, i: usize) []const u8 {
        var seen: usize = 0;
        for (self.entries[0..TableSize]) |e| {
            if (!e.occupied) continue;
            if (seen == i) return e.name;
            seen += 1;
        }
        return "";
    }

    pub fn debugSlotCount(self: *const State) usize {
        var n: usize = 0;
        for (self.entries[0..TableSize]) |e| {
            if (e.occupied) n += 1;
        }
        return n;
    }
};

var g_default_state: State = .{};
var g_state: *State = &g_default_state;

pub fn setActive(state: *State) void {
    g_state = state;
}

pub fn activeState() *State {
    return g_state;
}

pub fn reset() void                              { g_state.reset(); }
