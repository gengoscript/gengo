const common = @import("common.zig");
const vms = @import("vm_state.zig");
const vmgc = @import("vm_gc.zig");
const vmperf = @import("vm_perf.zig");
const heap = @import("../runtime/heap.zig");
const Value = @import("value.zig").Value;
const Object = @import("value.zig").Object;
const MapEntry = @import("value.zig").MapEntry;

pub fn mapKeyEquals(a: Value, b: Value) bool {
    if (vms.isStringValue(a) and vms.isStringValue(b)) {
        const sa = vms.asStringValue(a) catch return false;
        const sb = vms.asStringValue(b) catch return false;
        return common.streq(sa, sb);
    }
    return Value.equals(a, b);
}

fn hashMix64(a: u64, b: u64) u64 {
    return a *% 0x9e3779b97f4a7c15 +% b;
}

pub fn mapHashValue(v: Value) u64 {
    return switch (v) {
        .int => |n| @bitCast(n),
        .float => |n| @bitCast(n),
        .decimal => |d| @bitCast(@as(f64, @floatFromInt(d))),
        .rune => |r| @as(u64, r) *% 11400714819323198485,
        .boolean => |b| if (b) 0x9e3779b97f4a7c15 else 0x94d049bb133111eb,
        .string => |s| common.hashBytes(s),
        .error_value => |s| common.hashBytes(s),
        // dyn_string keys must hash by content, not pointer, so that a static .string
        // literal and a heap-allocated dyn_string with the same content land in the
        // same bucket and are found by mapFindHashedIndex.
        .object => |o| switch (o.*) {
            .dyn_string => |s| common.hashBytes(s),
            .string_view => |sv| common.hashBytes(sv.bytes),
            // enum_value, named_value, and variant_value use structural equality in
            // mapKeyEquals, so they must hash structurally too.  Pointer identity
            // would break open-addressed lookups after promotion.
            .enum_value => |ev| hashMix64(@intFromPtr(ev.typ), @intCast(ev.ordinal)),
            .named_value => |nv| hashMix64(@intFromPtr(nv.typ), mapHashValue(nv.value)),
            .variant_value => |vv| hashMix64(hashMix64(@intFromPtr(vv.typ), common.hashBytes(vv.tag)), mapHashValue(vv.payload)),
            else => @intFromPtr(o),
        },
        .null => 0xcbf29ce484222325,
    };
}

pub fn mapBucketsForCount(entry_count: usize) usize {
    const n: usize = if (entry_count < 4) 8 else entry_count * 2;
    var p: usize = 1;
    while (p < n) p <<= 1;
    return p;
}

pub fn mapFindLinear(items: []const MapEntry, key: Value) ?usize {
    for (items, 0..) |entry, i| {
        if (mapKeyEquals(entry.key, key)) return i;
    }
    return null;
}

pub fn mapFindHashedIndex(entries: []MapEntry, buckets: []i32, key: Value) ?usize {
    if (buckets.len == 0) return null;
    const mask = buckets.len - 1;
    var idx: usize = @intCast(mapHashValue(key) & mask);
    for (0..buckets.len) |probes| {
        const b = buckets[idx];
        if (b < 0) { vmperf.countMapProbe(probes + 1); return null; }
        const ei: usize = @intCast(b);
        if (ei < entries.len and mapKeyEquals(entries[ei].key, key)) {
            vmperf.countMapProbe(probes + 1);
            return ei;
        }
        idx = (idx + 1) & mask;
    }
    vmperf.countMapProbe(buckets.len);
    return null;
}

pub fn mapBuildHashedBuckets(entries: []MapEntry, buckets: []i32) void {
    for (buckets) |*b| b.* = -1;
    if (buckets.len == 0) return;
    const mask = buckets.len - 1;
    for (entries, 0..) |e, i| {
        var idx: usize = @intCast(mapHashValue(e.key) & mask);
        for (0..buckets.len) |_| {
            const cur = buckets[idx];
            if (cur < 0) {
                buckets[idx] = @intCast(i);
                break;
            }
            const curi: usize = @intCast(cur);
            if (mapKeyEquals(entries[curi].key, e.key)) {
                // Preserve first-in semantics for duplicate keys.
                break;
            }
            idx = (idx + 1) & mask;
        }
    }
}

pub fn mapInsertHashed(obj: *Object, key: Value, val: Value) !void {
    if (obj.* != .map_hashed) return error.TypeError;

    if (obj.map_hashed.buckets.len == 0 or
        obj.map_hashed.len >= obj.map_hashed.entries.len or
        ((obj.map_hashed.len + 1) * 10 >= obj.map_hashed.buckets.len * 7))
    {
        try vms.pushTempRoot(.{ .object = obj });
        defer vms.popTempRoot();

        const old = obj.map_hashed;
        const new_len = old.len + 1;
        const new_cap = if (old.entries.len < 8) 8 else old.entries.len * 2;
        const out_cap = if (new_cap < new_len) new_len else new_cap;
        const out_entries = try vmgc.vmAllocManagedSlice(MapEntry, out_cap);
        if (old.len > 0) @memcpy(out_entries[0..old.len], old.entries[0..old.len]);
        const bcount = mapBucketsForCount(out_cap);
        const out_buckets = try vmgc.vmAllocManagedSlice(i32, bcount);
        mapBuildHashedBuckets(out_entries[0..old.len], out_buckets);
        heap.freeManagedSlice(MapEntry, old.entries);
        heap.freeManagedSlice(i32, old.buckets);
        obj.* = .{ .map_hashed = .{ .entries = out_entries[0..out_cap], .len = old.len, .buckets = out_buckets } };
    }

    var hm = &obj.map_hashed;
    const mask = hm.buckets.len - 1;
    var slot: usize = @intCast(mapHashValue(key) & mask);
    for (0..hm.buckets.len) |_| {
        const b = hm.buckets[slot];
        if (b < 0) {
            const ei = hm.len;
            hm.entries[ei] = .{ .key = key, .value = val };
            hm.buckets[slot] = @intCast(ei);
            hm.len += 1;
            return;
        }
        const ei: usize = @intCast(b);
        if (ei < hm.len and mapKeyEquals(hm.entries[ei].key, key)) {
            hm.entries[ei].value = val;
            return;
        }
        slot = (slot + 1) & mask;
    }
    return error.OutOfMemory;
}
