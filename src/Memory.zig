//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of memory.

const Memory = @This();

const std = @import("std");
const value = @import("value.zig");
const rapidhash = .{ .micro = @import("rapidhash").rapidhashMicro };
const assert = std.debug.assert;

const Record = @import("Memory/Record.zig");

const load_factor = 75;

pub const Config = struct {
    /// Preallocation of hashmap during initialization
    /// based on quantity of expected keys.
    initial_keys: u32,

    fn initialCapacity(config: Config) u32 {
        if (config.initial_keys == 0) return 0;
        const cap: u32 = config.initial_keys * 100 / load_factor + 1;
        // 8 is the minimal capacity defined in `std.HashMapUnmanaged`.
        return @max(8, std.math.ceilPowerOfTwoAssert(u32, cap));
    }
};

const SearchContext = struct {
    pub fn hash(_: @This(), key: []const u8) u64 {
        return rapidhash.micro(key.ptr, key.len);
    }
    pub fn eql(_: @This(), key_a: []const u8, record_b: Record) bool {
        const metadata_b = record_b.metadata();
        if (key_a.len != metadata_b.key_len) return false;
        const key_b = record_b.key();
        return std.mem.eql(u8, key_a, key_b);
    }
};

const PutContext = struct {
    pub fn hash(_: @This(), s: Record) u64 {
        return (SearchContext{}).hash(s.key());
    }
    pub fn eql(_: @This(), a: Record, b: Record) bool {
        return std.mem.eql(u8, a.key(), b.key());
    }
};

const Hashset = std.HashMapUnmanaged(Record, void, PutContext, load_factor);

config: Config,

hashset: Hashset,

pub fn init(allocator: std.mem.Allocator, config: Config) std.mem.Allocator.Error!Memory {
    var self: Memory = .{ .hashset = .empty, .config = config };
    try self.hashset.ensureTotalCapacity(allocator, config.initial_keys);
    return self;
}

pub fn deinit(self: *Memory, allocator: std.mem.Allocator) void {
    self.removeAll(allocator);
    self.hashset.deinit(allocator);
}

pub const Ref = struct {
    value: value.Union,
    metadata: Record.Metadata,
    /// Likely to not be accessed directly.
    ptr: *const Record,

    fn from(record: *const Record) Ref {
        const metadata = record.metadata().*;
        const val = value.Union.fromOwnedSlice(
            metadata.value_type,
            record.valueAsBytes(),
        ) catch |err| switch (err) {
            error.InvalidFormat => unreachable,
        };
        return .{ .value = val, .metadata = metadata, .ptr = record };
    }

    pub fn lock(self: Ref) bool {
        const mutable_metadata = self.ptr.metadata();
        if (mutable_metadata.locked) return false;
        // Unlocked record, so we can lock it.
        mutable_metadata.locked = true;
        return true;
    }

    pub fn unlock(self: Ref) void {
        const mutable_metadata = self.ptr.metadata();
        mutable_metadata.locked = false;
    }
};

pub fn get(self: *Memory, key: []const u8) ?Ref {
    const record = self.hashset.getKeyPtrAdapted(key, SearchContext{}) orelse return null;
    return .from(record);
}

pub const PutError = Record.Error;

pub fn put(
    self: *Memory,
    allocator: std.mem.Allocator,
    key: []const u8,
    val: value.Union,
) PutError!void {
    const gop = try self.hashset.getOrPutAdapted(allocator, key, SearchContext{});

    if (gop.found_existing) {
        try gop.key_ptr.set(allocator, val.type(), val.bytes());
    } else {
        errdefer self.hashset.removeByPtr(gop.key_ptr);
        gop.key_ptr.* = try .init(allocator, key, val.type(), val.bytes());
    }
}

pub fn remove(self: *Memory, allocator: std.mem.Allocator, ref: Ref) void {
    ref.ptr.deinit(allocator);
    // `removeByPtr()` never modifies pointer.
    // Fix: https://codeberg.org/ziglang/zig/pulls/37187
    // (requested by me and merged for Zig 0.17.1)
    self.hashset.removeByPtr(@constCast(ref.ptr));
}

pub fn removeAll(self: *Memory, allocator: std.mem.Allocator) void {
    if (self.count() == 0) return;
    var iter = self.iterator();
    while (iter.next()) |entry| self.remove(allocator, entry.ref);
    self.hashset.clearRetainingCapacity();
}

pub fn count(self: *Memory) u32 {
    return self.hashset.count();
}

/// Clears records maintaining the preallocation of initial keys.
pub fn clear(self: *Memory, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
    // Other functions never reduce capacity less than initial keys.
    assert(self.hashset.capacity() >= self.config.initialCapacity());

    if (self.hashset.capacity() == self.config.initialCapacity()) {
        // We don't need hashset resizing to
        // keep the initial keys preallocated.
        self.removeAll(allocator);
    } else {
        const new_memory: Memory = try .init(allocator, self.config);
        self.deinit(allocator);
        self.* = new_memory;
    }

    assert(self.hashset.capacity() == self.config.initialCapacity());
}

pub const Iterator = struct {
    memory: *const Memory,
    wrapped_iterator: Hashset.KeyIterator,

    pub fn next(self: *Memory.Iterator) ?struct { key: []const u8, ref: Ref } {
        const record = self.wrapped_iterator.next() orelse return null;
        return .{ .key = record.key(), .ref = .from(record) };
    }

    pub fn skip(self: *Memory.Iterator, n: u64) void {
        for (0..n) |_| _ = self.next() orelse return;
    }

    pub fn reset(self: *Memory.Iterator) void {
        self.wrapped_iterator = self.memory.hashset.keyIterator();
    }
};

pub fn iterator(self: *const Memory) Memory.Iterator {
    return .{ .memory = self, .wrapped_iterator = self.hashset.keyIterator() };
}

test "put/get/remove" {
    const allocator = std.testing.allocator;

    var memory: Memory = try .init(allocator, .{ .initial_keys = 4 });
    defer memory.deinit(allocator);

    try memory.put(allocator, "a", .{ .integer = .from(10) });
    try memory.put(allocator, "b", .{ .integer = .from(10) });

    try std.testing.expectEqual(2, memory.count());

    const ref = memory.get("a").?;
    try std.testing.expectEqual(.integer, ref.value.type());
    try std.testing.expectEqual(@as(i64, 10), ref.value.integer.value);

    try std.testing.expectEqual(null, memory.get("missing"));

    try memory.put(allocator, "a", .{ .string = .from("hello") });
    const ref_after = memory.get("a").?;
    try std.testing.expectEqual(.string, ref_after.value.type());
    try std.testing.expectEqualStrings("hello", ref_after.value.string.value);
    try std.testing.expectEqual(2, memory.count());

    memory.remove(allocator, ref_after);
    try std.testing.expectEqual(1, memory.count());
    try std.testing.expectEqual(null, memory.get("a"));

    try std.testing.expectEqual(null, memory.get("a"));
    const ref_b = memory.get("b").?;
    try std.testing.expectEqual(.integer, ref_b.value.type());
}

test "iterator" {
    const allocator = std.testing.allocator;

    var memory: Memory = try .init(allocator, .{ .initial_keys = 8 });
    defer memory.deinit(allocator);

    const keys = [_][]const u8{ "k0", "k1", "k2", "k3" };
    for (keys) |k| try memory.put(allocator, k, .{ .integer = .from(0) });

    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();

    var it = memory.iterator();
    var visited: usize = 0;
    while (it.next()) |kv| : (visited += 1) {
        try seen.put(kv.key, {});
    }
    try std.testing.expectEqual(keys.len, visited);
    try std.testing.expectEqual(keys.len, seen.count());

    var it2 = memory.iterator();
    it2.skip(std.math.maxInt(u64));
    try std.testing.expect(it2.next() == null);

    it2.reset();
    var recount: usize = 0;
    while (it2.next()) |_| recount += 1;
    try std.testing.expectEqual(keys.len, recount);
}

test "clear" {
    const allocator = std.testing.allocator;

    var memory: Memory = try .init(allocator, .{ .initial_keys = 4 });
    defer memory.deinit(allocator);

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var buf: [8]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "key{d}", .{i}) catch unreachable;
        try memory.put(allocator, k, .{ .integer = .from(0) });
    }
    try std.testing.expectEqual(50, memory.count());

    try memory.clear(allocator);

    try std.testing.expectEqual(0, memory.count());
    try std.testing.expectEqual(null, memory.get("key0"));

    try memory.put(allocator, "new", .{ .integer = .from(0) });
    try std.testing.expectEqual(1, memory.count());
    const ref = memory.get("new").?;
    try std.testing.expectEqual(@as(i64, 0), ref.value.integer.value);

    try memory.clear(allocator);
    try std.testing.expectEqual(0, memory.count());
}
