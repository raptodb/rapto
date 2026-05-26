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
const frames = @import("../../../frames.zig");
const value = @import("../../value.zig");

const ScalarItem = @import("../scalar.zig").ScalarItem;
const String = @import("../scalar.zig").String;

pub const MapContext = struct {
    pub fn hash(_: @This(), s: KeyString) u64 {
        return std.hash.Wyhash.hash(0, s.get());
    }
    pub fn eql(_: @This(), a: KeyString, b: KeyString) bool {
        return std.mem.eql(u8, a.get(), b.get());
    }
};

pub const HashMap = std.HashMapUnmanaged(
    KeyString,
    ScalarItem,
    MapContext,
    std.hash_map.default_max_load_percentage,
);

/// Slice wrapper of key string. Used as key of Map.
/// Duplicated and owned by Map, so the content of KeyString is never modified by Map.
pub const KeyString = struct {
    str: []const u8,

    pub fn init(content: []const u8) KeyString {
        return .{ .str = content };
    }

    pub fn get(self: KeyString) []const u8 {
        return self.str;
    }

    pub fn serializeToWriter(self: KeyString, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return value.serializeToWriter(writer, .string, self.get());
    }
};

ptr: *HashMap,

pub fn initFromContent(
    allocator: std.mem.Allocator,
    content: []const u8,
) error{ InvalidFormat, UnknownType, MismatchType, OutOfMemory }!Map {
    const map_ptr = try allocator.create(HashMap);
    errdefer allocator.destroy(map_ptr);

    map_ptr.* = .empty;
    try putSerializedMap(map_ptr, allocator, content);
    return .{ .ptr = map_ptr };
}

pub fn set(
    self: *Map,
    allocator: std.mem.Allocator,
    content: []const u8,
) (std.mem.Allocator.Error || error{ UnknownType, InvalidFormat, MismatchType })!void {
    self.removeAll(allocator);
    try putSerializedMap(self.ptr, allocator, content);
}

/// Keys are internally duplicated and owned by the Map.
/// Caller retains ownership of serialized input.
pub fn put(
    self: Map,
    allocator: std.mem.Allocator,
    serialized_key: []const u8,
    serialized_value: []const u8,
) (std.mem.Allocator.Error || error{ MismatchType, InvalidFormat, UnknownType })!void {
    const key_type, const key_content = try value.splitSerialized(serialized_key);
    if (key_type != .string) return error.MismatchType;
    const key: KeyString = .init(key_content);
    const gop = try self.ptr.getOrPut(allocator, key);

    const value_type, const value_content = try value.splitSerialized(serialized_value);
    const new_value: ScalarItem = try .fromContent(allocator, value_type, value_content);
    errdefer new_value.deinit(allocator);

    if (gop.found_existing) {
        gop.value_ptr.deinit(allocator);
    } else {
        const key_copy = try allocator.dupe(u8, key_content);
        gop.key_ptr.* = .init(key_copy);
    }

    gop.value_ptr.* = new_value;
}

pub fn get(self: Map) HashMap.Iterator {
    return self.ptr.iterator();
}

pub fn getByKey(
    self: Map,
    serialized: []const u8,
) error{ MismatchType, MapKeyNotFound, InvalidFormat, UnknownType }!ScalarItem {
    const key_type, const content = try value.splitSerialized(serialized);
    if (key_type != .string) return error.MismatchType;

    const key: KeyString = .init(content);
    return self.ptr.get(key) orelse error.MapKeyNotFound;
}

pub fn removeByKey(
    self: Map,
    allocator: std.mem.Allocator,
    serialized: []const u8,
) error{ MismatchType, MapKeyNotFound, InvalidFormat, UnknownType }!void {
    const key_type, const content = try value.splitSerialized(serialized);
    if (key_type != .string) return error.MismatchType;

    const key: KeyString = .init(content);
    const entry = self.ptr.fetchRemove(key) orelse return error.MapKeyNotFound;
    allocator.free(entry.key.str);
    entry.value.deinit(allocator);
}

pub fn removeAll(self: Map, allocator: std.mem.Allocator) void {
    var iterator = self.get();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.str);
        entry.value_ptr.deinit(allocator);
    }
    self.ptr.clearAndFree(allocator);
}

pub fn exists(
    self: Map,
    serialized: []const u8,
) error{ MismatchType, InvalidFormat, UnknownType }!bool {
    const key_type, const content = try value.splitSerialized(serialized);
    if (key_type != .string) return error.MismatchType;

    const key: KeyString = .init(content);
    return self.ptr.contains(key);
}

pub fn count(self: Map) u64 {
    return self.ptr.count();
}

pub fn deinit(self: Map, allocator: std.mem.Allocator) void {
    self.removeAll(allocator);
    self.ptr.deinit(allocator);
    allocator.destroy(self.ptr);
}

pub fn serializeKeysToWriter(self: Map, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try value.Type.serializeToWriter(.list, writer);
    var iterator = self.ptr.keyIterator();
    while (iterator.next()) |key| {
        var builder: frames.Builder = try .begin(writer);
        defer builder.end();
        try key.serializeToWriter(writer);
    }
}

pub fn serializeValuesToWriter(self: Map, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try value.Type.serializeToWriter(.list, writer);
    var iterator = self.ptr.valueIterator();
    while (iterator.next()) |item| {
        var builder: frames.Builder = try .begin(writer);
        defer builder.end();
        try item.serializeToWriter(writer);
    }
}

pub fn serializeContentToWriter(self: Map, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var iterator = self.get();
    while (iterator.next()) |pair| {
        {
            var builder: frames.Builder = try .begin(writer);
            defer builder.end();
            try pair.key_ptr.serializeToWriter(writer);
        }
        {
            var builder: frames.Builder = try .begin(writer);
            defer builder.end();
            try pair.value_ptr.serializeToWriter(writer);
        }
    }
}

fn putSerializedMap(
    items: *HashMap,
    allocator: std.mem.Allocator,
    serialized: []const u8,
) (std.mem.Allocator.Error || error{ UnknownType, InvalidFormat, MismatchType })!void {
    var iterator = try serializedEntriesIterator(serialized);
    const self: Map = .{ .ptr = items };

    while (iterator.next()) |entry|
        try self.put(allocator, entry.serialized_key, entry.serialized_value);
}

/// Iterator of serialized entries in a serialized Map.
const Iterator = struct {
    wrapped_iterator: frames.Iterator,

    const Entry = struct {
        serialized_key: []const u8,
        serialized_value: []const u8,
    };

    /// Iterates the next serialized entry in the Map.
    fn next(self: *Iterator) ?Entry {
        return .{
            .serialized_key = self.wrapped_iterator.next() orelse return null,
            .serialized_value = self.wrapped_iterator.next() orelse return null,
        };
    }
};

fn serializedEntriesIterator(
    serialized: []const u8,
) error{ MismatchType, UnknownType, InvalidFormat }!Iterator {
    const value_type, const content = try value.splitSerialized(serialized);
    if (value_type != .map) return error.MismatchType;
    return .{ .wrapped_iterator = .init(content) };
}

const MapEntry = struct {
    key: []const u8,
    serialized_value: []const u8,
};

fn serializeEntries(allocator: std.mem.Allocator, entries: []const MapEntry) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();
    var writer = &allocating.writer;

    try value.Type.serializeToWriter(.map, writer);

    for (entries) |entry| {
        {
            var builder: frames.Builder = try .begin(writer);
            defer builder.end();
            try value.serializeToWriter(writer, .string, entry.key);
        }
        {
            var builder: frames.Builder = try .begin(writer);
            defer builder.end();
            try writer.writeAll(entry.serialized_value);
        }
    }

    return allocating.toOwnedSlice();
}

test "Map" {
    const allocator = std.testing.allocator;

    var int_item = try ScalarItem.fromContent(allocator, .integer, &@as([8]u8, @bitCast(@as(i64, 42))));
    defer int_item.deinit(allocator);
    var dec_item = try ScalarItem.fromContent(allocator, .decimal, &@as([8]u8, @bitCast(@as(f64, 3.14))));
    defer dec_item.deinit(allocator);
    var flag_item = try ScalarItem.fromContent(allocator, .flag, &@as([8]u8, @bitCast(@as(u64, 1))));
    defer flag_item.deinit(allocator);
    var str_item = try ScalarItem.fromContent(allocator, .string, "hello");
    defer str_item.deinit(allocator);
    var void_item = try ScalarItem.fromContent(allocator, .void, &.{});
    defer void_item.deinit(allocator);

    var point_buf: [24]u8 = undefined;
    var point_writer: std.Io.Writer = .fixed(&point_buf);
    try point_writer.writeInt(u64, @bitCast(@as(f64, 1.0)), .little);
    try point_writer.writeInt(u64, @bitCast(@as(f64, 2.0)), .little);
    try point_writer.writeInt(u64, @bitCast(@as(f64, 3.0)), .little);
    var point_item = try ScalarItem.fromContent(allocator, .point, point_writer.buffered());
    defer point_item.deinit(allocator);

    const sv_int = try serializeScalarItem(allocator, int_item);
    defer allocator.free(sv_int);
    const sv_dec = try serializeScalarItem(allocator, dec_item);
    defer allocator.free(sv_dec);
    const sv_flag = try serializeScalarItem(allocator, flag_item);
    defer allocator.free(sv_flag);
    const sv_str = try serializeScalarItem(allocator, str_item);
    defer allocator.free(sv_str);
    const sv_void = try serializeScalarItem(allocator, void_item);
    defer allocator.free(sv_void);
    const sv_point = try serializeScalarItem(allocator, point_item);
    defer allocator.free(sv_point);

    const k_count = "count";
    const k_pi = "pi";
    const k_active = "active";
    const k_name = "name";
    const k_empty = "empty";
    const k_pos = "pos";

    const sk_count = try serializeKey(allocator, k_count);
    defer allocator.free(sk_count);
    const sk_pi = try serializeKey(allocator, k_pi);
    defer allocator.free(sk_pi);
    const sk_active = try serializeKey(allocator, k_active);
    defer allocator.free(sk_active);
    const sk_name = try serializeKey(allocator, k_name);
    defer allocator.free(sk_name);
    const sk_empty = try serializeKey(allocator, k_empty);
    defer allocator.free(sk_empty);
    const sk_pos = try serializeKey(allocator, k_pos);
    defer allocator.free(sk_pos);
    const sk_miss = try serializeKey(allocator, "missing");
    defer allocator.free(sk_miss);
    const sk_ghost = try serializeKey(allocator, "ghost");
    defer allocator.free(sk_ghost);
    const sk_new = try serializeKey(allocator, "newkey");
    defer allocator.free(sk_new);

    const serialized_all = try serializeEntries(allocator, &.{
        .{ .key = k_count, .serialized_value = sv_int },
        .{ .key = k_pi, .serialized_value = sv_dec },
        .{ .key = k_active, .serialized_value = sv_flag },
        .{ .key = k_name, .serialized_value = sv_str },
        .{ .key = k_empty, .serialized_value = sv_void },
        .{ .key = k_pos, .serialized_value = sv_point },
    });
    defer allocator.free(serialized_all);

    try std.testing.expect(serialized_all[0] == @intFromEnum(value.Type.map));

    var m: Map = try .initFromContent(allocator, serialized_all);
    defer m.deinit(allocator);

    try std.testing.expect(m.count() == 6);

    try std.testing.expect((try m.getByKey(sk_count)).integer.get() == 42);
    try std.testing.expect((try m.getByKey(sk_pi)).decimal.isApproxEqualTo(3.14));
    try std.testing.expect((try m.getByKey(sk_active)).flag.get() == .true);
    try std.testing.expectEqualStrings("hello", (try m.getByKey(sk_name)).string.get());
    _ = (try m.getByKey(sk_empty)).void.get();
    {
        const ax = (try m.getByKey(sk_pos)).point.get();
        try std.testing.expect(ax.x.get() == 1.0);
        try std.testing.expect(ax.y.get() == 2.0);
        try std.testing.expect(ax.z.get() == 3.0);
    }

    try std.testing.expectError(error.MapKeyNotFound, m.getByKey(sk_miss));
    try std.testing.expectError(error.MismatchType, m.getByKey(sv_int));

    try std.testing.expect(try m.exists(sk_count));
    try std.testing.expect(try m.exists(sk_pos));
    try std.testing.expect(!(try m.exists(sk_ghost)));
    try std.testing.expectError(error.MismatchType, m.exists(sv_int));

    var int_item2 = try ScalarItem.fromContent(allocator, .integer, &@as([8]u8, @bitCast(@as(i64, 99))));
    defer int_item2.deinit(allocator);
    const sv_int2 = try serializeScalarItem(allocator, int_item2);
    defer allocator.free(sv_int2);

    try m.put(allocator, sk_count, sv_int2);
    try std.testing.expect(m.count() == 6);
    try std.testing.expect((try m.getByKey(sk_count)).integer.get() == 99);

    try m.put(allocator, sk_new, sv_flag);
    try std.testing.expect(m.count() == 7);
    try std.testing.expect((try m.getByKey(sk_new)).flag.get() == .true);

    try m.removeByKey(allocator, sk_new);
    try std.testing.expect(m.count() == 6);
    try std.testing.expectError(error.MapKeyNotFound, m.getByKey(sk_new));
    try std.testing.expectError(error.MapKeyNotFound, m.removeByKey(allocator, sk_ghost));
    try std.testing.expectError(error.MismatchType, m.removeByKey(allocator, sv_int));

    {
        var iter = m.get();
        var found: u64 = 0;
        while (iter.next()) |_| found += 1;
        try std.testing.expect(found == m.count());
    }

    {
        var al: std.Io.Writer.Allocating = .init(allocator);
        defer al.deinit();
        try m.serializeKeysToWriter(&al.writer);
        try std.testing.expect(al.written()[0] == @intFromEnum(value.Type.list));
    }

    {
        var al: std.Io.Writer.Allocating = .init(allocator);
        defer al.deinit();
        try m.serializeValuesToWriter(&al.writer);
        try std.testing.expect(al.written()[0] == @intFromEnum(value.Type.list));
    }

    const serialized_small = try serializeEntries(allocator, &.{
        .{ .key = k_pi, .serialized_value = sv_dec },
        .{ .key = k_name, .serialized_value = sv_str },
    });
    defer allocator.free(serialized_small);

    try m.set(allocator, serialized_small);
    try std.testing.expect(m.count() == 2);
    try std.testing.expectError(error.MapKeyNotFound, m.getByKey(sk_count));
    try std.testing.expect((try m.getByKey(sk_pi)).decimal.isApproxEqualTo(3.14));
    try std.testing.expectEqualStrings("hello", (try m.getByKey(sk_name)).string.get());

    const serialized_empty = try serializeEntries(allocator, &.{});
    defer allocator.free(serialized_empty);

    try m.set(allocator, serialized_empty);
    try std.testing.expect(m.count() == 0);
    try std.testing.expectError(error.MapKeyNotFound, m.getByKey(sk_pi));

    m.removeAll(allocator);
    try std.testing.expect(m.count() == 0);

    try m.set(allocator, serialized_all);
    try std.testing.expect(m.count() == 6);

    {
        var al: std.Io.Writer.Allocating = .init(allocator);
        defer al.deinit();
        try value.Type.serializeToWriter(.map, &al.writer);
        try m.serializeContentToWriter(&al.writer);
        const roundtrip_buf = try al.toOwnedSlice();
        defer allocator.free(roundtrip_buf);

        var m2: Map = try .initFromContent(allocator, roundtrip_buf);
        defer m2.deinit(allocator);

        try std.testing.expect(m2.count() == m.count());
        try std.testing.expect((try m2.getByKey(sk_pi)).decimal.isApproxEqualTo(3.14));
        {
            const ax = (try m2.getByKey(sk_pos)).point.get();
            try std.testing.expect(ax.x.get() == 1.0);
            try std.testing.expect(ax.y.get() == 2.0);
            try std.testing.expect(ax.z.get() == 3.0);
        }
    }
}

fn serializeScalarItem(allocator: std.mem.Allocator, item: ScalarItem) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();
    try item.serializeToWriter(&allocating.writer);
    return allocating.toOwnedSlice();
}

fn serializeKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();
    try value.serializeToWriter(&allocating.writer, .string, key);
    return allocating.toOwnedSlice();
}
