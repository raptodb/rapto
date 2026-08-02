//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of map value.

/// Map value type represented as hashmap of scalar type entries.
/// Each entry has key as String and value as any scalar value.
/// The serialized Map has a prefixed-length layout for any item.
const Map = @This();

const std = @import("std");
const frames = @import("../../frames.zig");
const glob = @import("../../glob.zig");
const assert = std.debug.assert;

const Value = @import("../../object.zig").Value;
const Scalar = @import("../scalar.zig").Scalar;
const String = @import("../scalar.zig").String;

pub const MapContext = struct {
    pub fn hash(_: @This(), s: []const u8) u64 {
        return std.hash.Wyhash.hash(0, s);
    }
    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

pub const HashMap = std.HashMapUnmanaged(
    []const u8,
    Scalar,
    MapContext,
    std.hash_map.default_max_load_percentage,
);

ptr: *HashMap,

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Map {
    const map_ptr = try allocator.create(HashMap);
    errdefer allocator.destroy(map_ptr);
    map_ptr.* = .empty;
    return .{ .ptr = map_ptr };
}

pub fn deinit(self: Map, allocator: std.mem.Allocator) void {
    self.removeAll(allocator);
    self.ptr.deinit(allocator);
    allocator.destroy(self.ptr);
}

pub fn dupe(self: Map, allocator: std.mem.Allocator) std.mem.Allocator.Error!Map {
    const map_ptr = try allocator.create(HashMap);
    errdefer allocator.destroy(map_ptr);

    map_ptr.* = .empty;
    try map_ptr.ensureTotalCapacity(allocator, @intCast(self.count()));
    errdefer map_ptr.deinit(allocator);

    var iterator = self.get();
    while (iterator.next()) |pair| {
        const key_copy = try allocator.dupe(u8, pair.getKey());
        errdefer allocator.free(key_copy);

        const value_copy = try pair.getValue().dupe(allocator);
        errdefer value_copy.deinit(allocator);

        const result = try map_ptr.getOrPut(allocator, key_copy);
        assert(!result.found_existing);

        result.key_ptr.* = key_copy;
        result.value_ptr.* = value_copy;
    }

    return .{ .ptr = map_ptr };
}

pub const PutError = std.mem.Allocator.Error || error{
    InvalidFormat,
    UnknownType,
    MismatchType,
    InvalidKey,
};

/// Keys are internally duplicated and owned by the Map.
/// Caller retains ownership of serialized input.
pub fn put(
    self: Map,
    allocator: std.mem.Allocator,
    key: []const u8,
    serialized: []const u8,
) PutError!void {
    if (glob.classify(key) != .literal) return error.InvalidKey;

    const gop = try self.ptr.getOrPut(allocator, key);

    const value_type, const value_content = try Value.splitSerialized(serialized);
    const new_value: Scalar = try .initFromContent(allocator, value_type, value_content);
    errdefer new_value.deinit(allocator);

    if (gop.found_existing) {
        gop.value_ptr.deinit(allocator);
    } else {
        const key_copy = try allocator.dupe(u8, key);
        gop.key_ptr.* = key_copy;
    }

    gop.value_ptr.* = new_value;
}

pub fn ensure(
    self: Map,
    allocator: std.mem.Allocator,
    key: []const u8,
    serialized: []const u8,
) PutError!void {
    if (glob.classify(key) != .literal) return error.InvalidKey;

    const gop = try self.ptr.getOrPut(allocator, key);
    if (gop.found_existing) return;

    const value_type, const value_content = try Value.splitSerialized(serialized);
    const new_value: Scalar = try .initFromContent(allocator, value_type, value_content);
    errdefer new_value.deinit(allocator);

    const key_copy = try allocator.dupe(u8, key);
    gop.key_ptr.* = key_copy;
    gop.value_ptr.* = new_value;
}

pub const Pair = struct {
    entry: HashMap.Entry,

    pub fn from(key: []const u8, scalar_value: Scalar) Pair {
        return .{ .key = key, .value = scalar_value };
    }

    pub fn getKey(self: Pair) []const u8 {
        return self.entry.key_ptr.*;
    }

    pub fn getValue(self: Pair) Scalar {
        return self.entry.value_ptr.*;
    }

    /// Assumes writer is derived from std.Io.Writer.Allocating.
    pub fn serializeToWriter(pair: Pair, writer: *std.Io.Writer) std.mem.Allocator.Error!void {
        try pair.serializeKeyToWriter(writer);
        try pair.serializeValueToWriter(writer);
    }

    /// Assumes writer is derived from std.Io.Writer.Allocating.
    pub fn serializeKeyToWriter(pair: Pair, writer: *std.Io.Writer) std.mem.Allocator.Error!void {
        var builder: frames.Builder = try .begin(writer);
        defer builder.end();
        writer.writeAll(pair.getKey()) catch |err| return switch (err) {
            error.WriteFailed => error.OutOfMemory,
        };
    }

    /// Assumes writer is derived from std.Io.Writer.Allocating.
    pub fn serializeValueToWriter(pair: Pair, writer: *std.Io.Writer) std.mem.Allocator.Error!void {
        var builder: frames.Builder = try .begin(writer);
        defer builder.end();
        pair.entry.value_ptr.serializeToWriter(writer) catch |err| return switch (err) {
            error.WriteFailed => error.OutOfMemory,
        };
    }
};

pub const PairIterator = struct {
    wrapped_iterator: HashMap.Iterator,

    pub fn next(self: *PairIterator) ?Pair {
        const entry = self.wrapped_iterator.next() orelse return null;
        return .{ .entry = entry };
    }
};

pub const Serializer = struct {
    writer: *std.Io.Writer,

    /// Assumes writer is derived from std.Io.Writer.Allocating.
    pub fn begin(writer: *std.Io.Writer) std.mem.Allocator.Error!Serializer {
        Value.Type.serializeToWriter(
            .map,
            writer,
        ) catch |err| return switch (err) {
            error.WriteFailed => error.OutOfMemory,
        };
        return .{ .writer = writer };
    }

    /// Assumes writer is derived from std.Io.Writer.Allocating.
    pub fn append(self: Serializer, pair: Pair) std.mem.Allocator.Error!void {
        try pair.serializeToWriter(self.writer);
    }

    /// For conventional purpose; this is no-op.
    pub fn end(self: Serializer) void {
        _ = self;
    }
};

pub fn get(self: Map) PairIterator {
    return .{ .wrapped_iterator = self.ptr.iterator() };
}

pub fn getKeys(self: Map) HashMap.KeyIterator {
    return self.ptr.keyIterator();
}

pub fn getByKey(self: Map, key: []const u8) error{MapKeyNotFound}!Scalar {
    return self.ptr.get(key) orelse error.MapKeyNotFound;
}

pub fn removeByKey(
    self: Map,
    allocator: std.mem.Allocator,
    key: []const u8,
) error{MapKeyNotFound}!void {
    const entry = self.ptr.fetchRemove(key) orelse return error.MapKeyNotFound;
    allocator.free(entry.key);
    entry.value.deinit(allocator);
}

pub fn removeAll(self: Map, allocator: std.mem.Allocator) void {
    var iterator = self.get();
    while (iterator.next()) |pair| {
        allocator.free(pair.getKey());
        pair.getValue().deinit(allocator);
    }
    self.ptr.clearAndFree(allocator);
}

pub fn exists(self: Map, key: []const u8) bool {
    return self.ptr.contains(key);
}

pub fn count(self: Map) u64 {
    return self.ptr.count();
}

/// Iterator of serialized entries in a serialized Map.
pub const Iterator = struct {
    wrapped_iterator: frames.Iterator,

    const Entry = struct {
        key: []const u8,
        serialized_value: []const u8,
    };

    pub fn init(content: []const u8) Iterator {
        return .{ .wrapped_iterator = .init(content) };
    }

    /// Iterates the next serialized entry in the Map.
    pub fn next(self: *Iterator) error{InvalidFormat}!?Entry {
        return .{
            .key = self.wrapped_iterator.next() orelse return null,
            .serialized_value = self.wrapped_iterator.next() orelse return error.InvalidFormat,
        };
    }
};

test "Map" {
    const allocator = std.testing.allocator;

    var int_item: Scalar = try .initFromContent(allocator, .integer, &@as([8]u8, @bitCast(@as(i64, 42))));
    defer int_item.deinit(allocator);
    var dec_item: Scalar = try .initFromContent(allocator, .decimal, &@as([8]u8, @bitCast(@as(f64, 3.14))));
    defer dec_item.deinit(allocator);
    var flag_item: Scalar = try .initFromContent(allocator, .flag, &@as([8]u8, @bitCast(@as(u64, 1))));
    defer flag_item.deinit(allocator);
    var str_item: Scalar = try .initFromContent(allocator, .string, "hello");
    defer str_item.deinit(allocator);
    var void_item: Scalar = try .initFromContent(allocator, .void, &.{});
    defer void_item.deinit(allocator);

    var point_buf: [24]u8 = undefined;
    var point_writer: std.Io.Writer = .fixed(&point_buf);
    try point_writer.writeInt(u64, @bitCast(@as(f64, 1.0)), .little);
    try point_writer.writeInt(u64, @bitCast(@as(f64, 2.0)), .little);
    try point_writer.writeInt(u64, @bitCast(@as(f64, 3.0)), .little);
    var point_item: Scalar = try .initFromContent(allocator, .point, point_writer.buffered());
    defer point_item.deinit(allocator);

    const sv_int = try serializeScalar(allocator, int_item);
    defer allocator.free(sv_int);
    const sv_dec = try serializeScalar(allocator, dec_item);
    defer allocator.free(sv_dec);
    const sv_flag = try serializeScalar(allocator, flag_item);
    defer allocator.free(sv_flag);
    const sv_str = try serializeScalar(allocator, str_item);
    defer allocator.free(sv_str);
    const sv_void = try serializeScalar(allocator, void_item);
    defer allocator.free(sv_void);
    const sv_point = try serializeScalar(allocator, point_item);
    defer allocator.free(sv_point);

    const k_count = "count";
    const k_pi = "pi";
    const k_active = "active";
    const k_name = "name";
    const k_empty = "empty";
    const k_pos = "pos";
    const k_missing = "missing";
    const k_ghost = "ghost";
    const k_new = "newkey";

    var m: Map = try .init(allocator);
    defer m.deinit(allocator);

    try m.put(allocator, k_count, sv_int);
    try m.put(allocator, k_pi, sv_dec);
    try m.put(allocator, k_active, sv_flag);
    try m.put(allocator, k_name, sv_str);
    try m.put(allocator, k_empty, sv_void);
    try m.put(allocator, k_pos, sv_point);

    try std.testing.expect(m.count() == 6);

    try std.testing.expect((try m.getByKey(k_count)).integer.get() == 42);
    try std.testing.expect((try m.getByKey(k_pi)).decimal.isApproxEqualTo(3.14));
    try std.testing.expect((try m.getByKey(k_active)).flag.get() == .true);
    try std.testing.expectEqualStrings("hello", (try m.getByKey(k_name)).string.get());
    _ = (try m.getByKey(k_empty)).void.get();
    {
        const ax = (try m.getByKey(k_pos)).point.get();
        try std.testing.expect(ax.x.get() == 1.0);
        try std.testing.expect(ax.y.get() == 2.0);
        try std.testing.expect(ax.z.get() == 3.0);
    }

    try std.testing.expectError(error.MapKeyNotFound, m.getByKey(k_missing));

    try std.testing.expect(m.exists(k_count));
    try std.testing.expect(m.exists(k_pos));
    try std.testing.expect(!m.exists(k_ghost));

    var int_item2: Scalar = try .initFromContent(allocator, .integer, &@as([8]u8, @bitCast(@as(i64, 99))));
    defer int_item2.deinit(allocator);
    const sv_int2 = try serializeScalar(allocator, int_item2);
    defer allocator.free(sv_int2);

    try m.put(allocator, k_count, sv_int2);
    try std.testing.expect(m.count() == 6);
    try std.testing.expect((try m.getByKey(k_count)).integer.get() == 99);

    try m.put(allocator, k_new, sv_flag);
    try std.testing.expect(m.count() == 7);
    try std.testing.expect((try m.getByKey(k_new)).flag.get() == .true);

    try m.removeByKey(allocator, k_new);
    try std.testing.expect(m.count() == 6);
    try std.testing.expectError(error.MapKeyNotFound, m.getByKey(k_new));
    try std.testing.expectError(error.MapKeyNotFound, m.removeByKey(allocator, k_ghost));

    {
        var iter = m.get();
        var found: u64 = 0;
        while (iter.next()) |_| found += 1;
        try std.testing.expect(found == m.count());
    }

    m.removeAll(allocator);
    try std.testing.expect(m.count() == 0);
    try std.testing.expectError(error.MapKeyNotFound, m.getByKey(k_pi));

    try m.put(allocator, k_pi, sv_dec);
    try m.put(allocator, k_name, sv_str);
    try std.testing.expect(m.count() == 2);

    {
        var al: std.Io.Writer.Allocating = .init(allocator);
        defer al.deinit();

        {
            var serializer: Serializer = try .begin(&al.writer);
            defer serializer.end();
            var iter = m.get();
            while (iter.next()) |pair| try serializer.append(pair);
        }

        const serialized = try al.toOwnedSlice();
        defer allocator.free(serialized);

        _, const content = try Value.splitSerialized(serialized);

        var m2: Map = try .init(allocator);
        defer m2.deinit(allocator);

        var frame_iter: Iterator = .init(content);
        while (try frame_iter.next()) |entry| {
            try m2.put(allocator, entry.key, entry.serialized_value);
        }

        try std.testing.expect(m2.count() == m.count());
        try std.testing.expect((try m2.getByKey(k_pi)).decimal.isApproxEqualTo(3.14));
        try std.testing.expectEqualStrings("hello", (try m2.getByKey(k_name)).string.get());
    }
}

fn serializeScalar(allocator: std.mem.Allocator, item: Scalar) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();
    try item.serializeToWriter(&allocating.writer);
    return allocating.toOwnedSlice();
}
