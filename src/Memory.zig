//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of memory.
//!
//! Main data structure of Rapto that stores
//! the key-value pairs of the database. It
//! provides safe CRUD operations to access Ref.
const Memory = @This();

const std = @import("std");
const object = @import("object.zig");
const rapidhash = .{ .micro = @import("rapidhash").rapidhashMicro };
const assert = std.debug.assert;

const SearchContext = struct {
    pub fn hash(_: @This(), s: []const u8) u64 {
        return rapidhash.micro(s.ptr, s.len);
    }
    pub fn eql(_: @This(), a: []const u8, b: object.Key) bool {
        return std.mem.eql(u8, a, b.get());
    }
};

const PutContext = struct {
    pub fn hash(_: @This(), s: object.Key) u64 {
        return (SearchContext{}).hash(s.get());
    }
    pub fn eql(_: @This(), a: object.Key, b: object.Key) bool {
        return (SearchContext{}).eql(a.get(), b);
    }
};

const load_factor: u32 = 75;
const Map = std.HashMapUnmanaged(
    object.Key,
    object.Value,
    PutContext,
    load_factor,
);

pub const Config = struct {
    /// Preallocation of hashmap during initialization
    /// based on quantity of expected keys.
    initial_keys: u32,

    fn initialCapacity(config: Config) u32 {
        const cap: u32 = config.initial_keys * 100 / load_factor + 1;
        return std.math.ceilPowerOfTwo(u32, cap) catch unreachable;
    }
};

config: Config,
/// Hashmap of objects. Internal API
/// should not be used directly.
map: Map,

pub fn init(allocator: std.mem.Allocator, config: Config) std.mem.Allocator.Error!Memory {
    var self: Memory = .{ .config = config, .map = .empty };
    try self.map.ensureTotalCapacity(allocator, config.initial_keys);
    return self;
}

pub fn deinit(self: *Memory, allocator: std.mem.Allocator) void {
    self.removeAll(allocator);
    self.map.deinit(allocator);
}

pub const PutError = error{
    InvalidKey,
    InvalidFormat,
    MismatchType,
    UnknownType,
} || std.mem.Allocator.Error;

pub fn put(
    self: *Memory,
    allocator: std.mem.Allocator,
    key: []const u8,
    value_type: object.Value.Type,
    content: []const u8,
) PutError!object.Ref {
    const entry = try self.map.getOrPutAdapted(allocator, key, SearchContext{});
    const ref: object.Ref = .wrap(entry.key_ptr, entry.value_ptr);

    if (entry.found_existing) {
        try ref.setValueFromContent(allocator, value_type, content);
    } else {
        errdefer self.map.removeByPtr(entry.key_ptr);
        entry.key_ptr.*, entry.value_ptr.* = try object.init(allocator, key, value_type, content);
    }

    return ref;
}

pub fn copy(
    self: *Memory,
    allocator: std.mem.Allocator,
    src_key: []const u8,
    dst_ref: object.Ref,
) error{ KeyNotFound, InvalidKey, OutOfMemory }!void {
    const src_ref = try self.get(src_key);
    const src_type = src_ref.type();

    const old_type = dst_ref.key_ptr.getValueType();
    dst_ref.key_ptr.setValueType(src_type);
    dst_ref.value_ptr.deinit(allocator, old_type);

    dst_ref.value_ptr.* = switch (src_ref.type()) {
        inline else => |vt| .init(
            vt,
            try src_ref.dupeValue(allocator, vt),
        ),
    };
}

pub const EnsureResult = struct {
    ref: object.Ref,
    found_existing: bool,
};

pub fn ensure(
    self: *Memory,
    allocator: std.mem.Allocator,
    key: []const u8,
    value_type: object.Value.Type,
    content: []const u8,
) PutError!EnsureResult {
    const entry = try self.map.getOrPutAdapted(allocator, key, SearchContext{});
    const ref: object.Ref = .wrap(entry.key_ptr, entry.value_ptr);

    if (!entry.found_existing) {
        errdefer self.map.removeByPtr(entry.key_ptr);
        entry.key_ptr.*, entry.value_ptr.* = try object.init(allocator, key, value_type, content);
    }

    return .{ .ref = ref, .found_existing = entry.found_existing };
}

pub fn get(self: *Memory, key: []const u8) error{KeyNotFound}!object.Ref {
    const entry = self.map.getEntryAdapted(key, SearchContext{}) orelse
        return error.KeyNotFound;
    return .wrap(entry.key_ptr, entry.value_ptr);
}

/// Removes key from memory by ref.
/// Associated object.Ref will be invalidated.
pub fn removeByRef(self: *Memory, allocator: std.mem.Allocator, ref: object.Ref) void {
    object.deinit(allocator, ref.key_ptr.*, ref.value_ptr.*);
    self.map.removeByPtr(ref.key_ptr);
}

pub fn removeAll(self: *Memory, allocator: std.mem.Allocator) void {
    var iter = self.iterator();
    while (iter.next()) |ref| {
        object.deinit(allocator, ref.key_ptr.*, ref.value_ptr.*);
    }
    self.map.clearRetainingCapacity();
}

pub fn count(self: *const Memory) u64 {
    return self.map.count();
}

/// Clears Memory maintaining the preallocation of initial keys.
pub fn clear(self: *Memory, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
    // Other functions never reduce capacity less than initial keys.
    assert(self.map.capacity() >= self.config.initialCapacity());

    if (self.map.capacity() == self.config.initialCapacity()) {
        // We don't need Hashmap resizing to
        // keep the initial keys preallocated.
        self.removeAll(allocator);
    } else {
        self.deinit(allocator);
        self.* = try .init(allocator, self.config);
    }

    assert(self.map.capacity() == self.config.initialCapacity());
}

pub const Iterator = struct {
    memory: *Memory,
    wrapped_iterator: Map.Iterator,

    pub fn next(self: *Iterator) ?object.Ref {
        const entry = self.wrapped_iterator.next() orelse return null;
        return .wrap(entry.key_ptr, entry.value_ptr);
    }

    pub fn skip(self: *Iterator, n: u64) void {
        const cap = self.wrapped_iterator.hm.capacity();
        self.wrapped_iterator.index = @min(self.wrapped_iterator.index + n, cap);
    }

    pub fn reset(self: *Iterator) void {
        self.wrapped_iterator.index = 0;
    }
};

pub fn iterator(self: *Memory) Iterator {
    return .{ .memory = self, .wrapped_iterator = self.map.iterator() };
}

test "put/get/remove" {
    const allocator = std.testing.allocator;

    var memory: Memory = try .init(allocator, .{ .initial_keys = 4 });
    defer memory.deinit(allocator);

    const int_content: [8]u8 = @bitCast(@as(i64, 10));
    _ = try memory.put(allocator, "a", .integer, &int_content);
    _ = try memory.put(allocator, "b", .integer, &int_content);

    try std.testing.expectEqual(2, memory.count());

    const ref_a = try memory.get("a");
    try std.testing.expectEqual(.integer, ref_a.type());
    try std.testing.expectEqual(@as(i64, 10), ref_a.value(.integer).get());

    try std.testing.expectError(error.KeyNotFound, memory.get("missing"));

    _ = try memory.put(allocator, "a", .string, "hello");
    const ref_a_after = try memory.get("a");
    try std.testing.expectEqual(.string, ref_a_after.type());
    try std.testing.expectEqualStrings("hello", ref_a_after.value(.string).get());
    try std.testing.expectEqual(2, memory.count());

    memory.removeByRef(allocator, ref_a_after);
    try std.testing.expectEqual(1, memory.count());
    try std.testing.expectError(error.KeyNotFound, memory.get("a"));

    try std.testing.expectError(error.KeyNotFound, memory.get("a"));
    const ref_b = try memory.get("b");
    try std.testing.expectEqual(.integer, ref_b.type());
}

test "ensure" {
    const allocator = std.testing.allocator;

    var memory: Memory = try .init(allocator, .{ .initial_keys = 4 });
    defer memory.deinit(allocator);

    const first_content: [8]u8 = @bitCast(@as(i64, 1));
    const er1 = try memory.ensure(allocator, "k", .integer, &first_content);
    try std.testing.expect(!er1.found_existing);
    try std.testing.expectEqual(@as(i64, 1), er1.ref.value(.integer).get());

    const second_content: [8]u8 = @bitCast(@as(i64, 999));
    const er2 = try memory.ensure(allocator, "k", .integer, &second_content);
    try std.testing.expect(er2.found_existing);
    try std.testing.expectEqual(@as(i64, 1), er2.ref.value(.integer).get());

    try std.testing.expectEqual(1, memory.count());
    try std.testing.expectEqual(er1.ref.key_ptr, er2.ref.key_ptr);
}

test "iterator" {
    const allocator = std.testing.allocator;

    var memory: Memory = try .init(allocator, .{ .initial_keys = 8 });
    defer memory.deinit(allocator);

    const content: [8]u8 = @bitCast(@as(i64, 0));
    const keys = [_][]const u8{ "k0", "k1", "k2", "k3" };
    for (keys) |k| _ = try memory.put(allocator, k, .integer, &content);

    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();

    var it = memory.iterator();
    var visited: usize = 0;
    while (it.next()) |ref| : (visited += 1) {
        try seen.put(ref.key(), {});
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

    const content: [8]u8 = @bitCast(@as(i64, 0));
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var buf: [8]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "key{d}", .{i}) catch unreachable;
        _ = try memory.put(allocator, k, .integer, &content);
    }
    try std.testing.expectEqual(50, memory.count());

    try memory.clear(allocator);

    try std.testing.expectEqual(0, memory.count());
    try std.testing.expectError(error.KeyNotFound, memory.get("key0"));

    _ = try memory.put(allocator, "new", .integer, &content);
    try std.testing.expectEqual(1, memory.count());
    const ref = try memory.get("new");
    try std.testing.expectEqual(@as(i64, 0), ref.value(.integer).get());
}
