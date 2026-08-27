const common = @import("common.zig");
const vms = @import("vm_state.zig");
const VMContext = vms.VMContext;
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
        .string => |s| common.hashBytes(s.bytes),
        .error_value => |s| common.hashBytes(s.bytes),
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
        .inline_variant => |iv| {
            const vmod = @import("value.zig");
            return hashMix64(hashMix64(@intFromPtr(vmod.objectAtIdx(iv.typ_idx)), @as(u64, iv.ordinal)), mapHashValue(vmod.inlineVariantPayload(iv)));
        },
        .actor_ref => |r| hashMix64(@as(u64, r.index), @as(u64, r.generation)),
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
        if (b < 0) {
            vmperf.countMapProbe(probes + 1);
            return null;
        }
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

// ---------------------------------------------------------------------------
// Unified map operations — dispatch over all map representations
// ---------------------------------------------------------------------------

pub fn mapGet(obj: *Object, key: Value) !?Value {
    switch (obj.*) {
        .map, .map_managed => {
            const items = try vms.asMapSlice(obj);
            return if (mapFindLinear(items, key)) |fi| items[fi].value else null;
        },
        .map_hashed => |*hm| {
            return if (mapFindHashedIndex(hm.entries[0..hm.len], hm.buckets, key)) |fi| hm.entries[fi].value else null;
        },
        else => return error.TypeError,
    }
}

pub fn mapHas(obj: *Object, key: Value) !bool {
    switch (obj.*) {
        .map, .map_managed => {
            const items = try vms.asMapSlice(obj);
            return mapFindLinear(items, key) != null;
        },
        .map_hashed => |*hm| {
            return mapFindHashedIndex(hm.entries[0..hm.len], hm.buckets, key) != null;
        },
        else => return error.TypeError,
    }
}

pub fn mapSet(ctx: VMContext, container: Value, key: Value, val: Value) !void {
    // Callers (opSetIndex/opSetField) have already popped key/val off the VM
    // stack by the time this runs, so they are invisible to collectGarbage's
    // root scan. Root them for the whole function: both the map_hashed
    // delegation below and the growth path further down can allocate
    // (vmAllocManagedSlice), which can trigger a full mark-sweep before key
    // or val is ever stored somewhere reachable.
    try ctx.vs.pushTempRoot(key);
    defer ctx.vs.popTempRoot();
    try ctx.vs.pushTempRoot(val);
    defer ctx.vs.popTempRoot();
    if (container.object.* == .map_hashed) return mapInsertHashed(ctx, container.object, key, val);
    const items = try vms.asMapSlice(container.object);
    if (mapFindLinear(items, key)) |fi| {
        items[fi].value = val;
        return;
    }
    try ctx.vs.pushTempRoot(container);
    defer ctx.vs.popTempRoot();
    const old_len = items.len;
    const new_len = old_len + 1;
    const ext = try vmgc.vmAllocManagedSlice(ctx, MapEntry, new_len);
    // Re-derive after the allocation above, which can compact and
    // relocate container.object's backing — `items` was captured before
    // it and cannot be trusted here.
    const items_now = try vms.asMapSlice(container.object);
    @memcpy(ext[0..old_len], items_now);
    ext[old_len] = .{ .key = key, .value = val };
    // Publish before freeing the old slice so paranoia doesn't see a live
    // object (container.object) still pointing at the bytes being freed.
    const old_to_free: ?[]MapEntry = if (container.object.* == .map_managed) container.object.map_managed else null;
    container.object.* = .{ .map_managed = ext[0..new_len] };
    if (old_to_free) |old| ctx.hs.freeManagedSlice(MapEntry, old);
    if (new_len > 8) {
        const bcount = mapBucketsForCount(new_len);
        const buckets = try vmgc.vmAllocManagedSlice(ctx, i32, bcount);
        mapBuildHashedBuckets(ext[0..new_len], buckets);
        container.object.* = .{ .map_hashed = .{ .entries = ext[0..new_len], .len = new_len, .buckets = buckets } };
    }
}

pub fn mapDelete(obj: *Object, key: Value) !Value {
    switch (obj.*) {
        .map, .map_managed => {
            const items = try vms.asMapSlice(obj);
            const fi = mapFindLinear(items, key) orelse return .null;
            const removed = items[fi].value;
            items[fi] = items[items.len - 1];
            const shrunk = items[0 .. items.len - 1];
            if (obj.* == .map_managed) {
                obj.* = .{ .map_managed = shrunk };
            } else {
                obj.* = .{ .map = shrunk };
            }
            return removed;
        },
        .map_hashed => {
            const hm = &obj.map_hashed;
            const fi = mapFindHashedIndex(hm.entries[0..hm.len], hm.buckets, key) orelse return .null;
            const removed = hm.entries[fi].value;
            hm.entries[fi] = hm.entries[hm.len - 1];
            hm.len -= 1;
            mapBuildHashedBuckets(hm.entries[0..hm.len], hm.buckets);
            return removed;
        },
        else => return error.TypeError,
    }
}

pub fn mapInsertHashed(ctx: VMContext, obj: *Object, key: Value, val: Value) !void {
    if (obj.* != .map_hashed) return error.TypeError;

    if (obj.map_hashed.buckets.len == 0 or
        obj.map_hashed.len >= obj.map_hashed.entries.len or
        ((obj.map_hashed.len + 1) * 10 >= obj.map_hashed.buckets.len * 7))
    {
        try ctx.vs.pushTempRoot(.{ .object = obj });
        defer ctx.vs.popTempRoot();

        // Keep only plain numbers (immune to relocation) across the
        // allocations below — a by-value copy of obj.map_hashed (its
        // `old` slices) would go stale exactly like any other slice
        // captured before an allocation that can compact.
        const old_len = obj.map_hashed.len;
        const old_entries_cap = obj.map_hashed.entries.len;
        const new_len = old_len + 1;
        const new_cap = if (old_entries_cap < 8) 8 else old_entries_cap * 2;
        const out_cap = if (new_cap < new_len) new_len else new_cap;
        const out_entries = try vmgc.vmAllocManagedSlice(ctx, MapEntry, out_cap);
        // Re-derive obj.map_hashed.entries now, after the allocation above.
        if (old_len > 0) @memcpy(out_entries[0..old_len], obj.map_hashed.entries[0..old_len]);
        // Snapshot the slices to free fresh, right before freeing them —
        // not a copy captured before the allocation above, which is
        // exactly what used to let this free a stale (relocated-away)
        // address, corrupting the free lists rather than just misreading
        // data. Neither is read again (entries already copied into
        // out_entries; buckets get rebuilt from scratch below).
        const old_entries_to_free = obj.map_hashed.entries;
        const old_buckets_to_free = obj.map_hashed.buckets;
        // Publish out_entries onto obj now, before freeing the old slices
        // (so paranoia doesn't see stale live refs) and before allocating
        // out_buckets below: a freshly allocated managed block that isn't
        // yet reachable from any live object is invisible to compaction's
        // relocation bookkeeping, so the out_buckets allocation could
        // otherwise silently pack live data on top of out_entries while
        // it's still just a local variable.
        obj.* = .{ .map_hashed = .{ .entries = out_entries[0..out_cap], .len = old_len, .buckets = &[_]i32{} } };
        ctx.hs.freeManagedSlice(MapEntry, old_entries_to_free);
        ctx.hs.freeManagedSlice(i32, old_buckets_to_free);

        const bcount = mapBucketsForCount(out_cap);
        const out_buckets = try vmgc.vmAllocManagedSlice(ctx, i32, bcount);
        // Re-derive again: the allocation above can compact and relocate
        // obj.map_hashed.entries.
        mapBuildHashedBuckets(obj.map_hashed.entries[0..old_len], out_buckets);
        obj.* = .{ .map_hashed = .{ .entries = obj.map_hashed.entries, .len = old_len, .buckets = out_buckets } };
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
