//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of map field.

const std = @import("std");

const ScalarItem = @import("../scalar.zig").ScalarItem;
const String = @import("../scalar.zig").String;
const List = @import("../collection.zig").List;
const Types = @import("../types.zig").Types;

const splitSerialized = @import("../types.zig").splitSerialized;

/// Map field type represented as hashmap of scalar type entries. Each entry has key as String and
/// value as any scalar type field. The serialized Map has a prefixed-length layout for any item.
/// The length header is 4 bytes. (In the example below, H refers to every byte of header)
/// Example: [HHHH[serialized key A]HHHH[serialized value A]HHHH[serialized key B]...]
pub const Map = struct {
    value: *HashMap,

    pub const KeyHeaderType: type = String.HeaderType;
    pub const ValueHeaderType: type = u32;
    pub const key_header_size: u64 = String.header_size;
    pub const value_header_size: u64 = @sizeOf(u32);

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
    };

    pub fn init(
        allocator: std.mem.Allocator,
        serialized: []const u8,
    ) error{ InvalidFormat, UnknownType, MismatchType, OutOfMemory }!Map {
        const map_ptr = try allocator.create(HashMap);
        errdefer allocator.destroy(map_ptr);

        map_ptr.* = .empty;
        try putSerializedMap(map_ptr, allocator, serialized);
        return .{ .value = map_ptr };
    }

    pub fn set(
        self: *Map,
        allocator: std.mem.Allocator,
        serialized: []const u8,
    ) error{ OutOfMemory, UnknownType, InvalidFormat, MismatchType }!void {
        self.removeAll(allocator);
        try putSerializedMap(self.value, allocator, serialized);
    }

    /// Keys are internally duplicated and owned by the Map.
    /// Caller retains ownership of serialized input.
    pub fn put(
        self: Map,
        allocator: std.mem.Allocator,
        serialized_key: []const u8,
        serialized_value: []const u8,
    ) error{ OutOfMemory, MismatchType, InvalidFormat, UnknownType }!void {
        const key_type, const key_content = try splitSerialized(serialized_key);
        if (key_type != .string) return error.MismatchType;
        const key: KeyString = .init(key_content);
        const gop = try self.value.getOrPut(allocator, key);

        const value_type, const value_content = try splitSerialized(serialized_value);
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
        return self.value.iterator();
    }

    pub fn getByKey(
        self: Map,
        serialized: []const u8,
    ) error{ MismatchType, MapKeyNotFound, InvalidFormat, UnknownType }!ScalarItem {
        const key_type, const content = try splitSerialized(serialized);
        if (key_type != .string) return error.MismatchType;

        const key: KeyString = .init(content);
        return self.value.get(key) orelse error.MapKeyNotFound;
    }

    pub fn removeByKey(
        self: Map,
        allocator: std.mem.Allocator,
        serialized: []const u8,
    ) error{ MismatchType, MapKeyNotFound, InvalidFormat, UnknownType }!void {
        const key_type, const content = try splitSerialized(serialized);
        if (key_type != .string) return error.MismatchType;

        const key: KeyString = .init(content);
        const entry = self.value.fetchRemove(key) orelse return error.MapKeyNotFound;
        allocator.free(entry.key.str);
        entry.value.deinit(allocator);
    }

    pub fn removeAll(self: Map, allocator: std.mem.Allocator) void {
        var iterator = self.get();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.str);
            entry.value_ptr.deinit(allocator);
        }
        self.value.clearAndFree(allocator);
    }

    pub fn exists(
        self: Map,
        serialized: []const u8,
    ) error{ MismatchType, InvalidFormat, UnknownType }!bool {
        const key_type, const content = try splitSerialized(serialized);
        if (key_type != .string) return error.MismatchType;

        const key: KeyString = .init(content);
        return self.value.contains(key);
    }

    pub fn count(self: Map) u64 {
        return self.value.count();
    }

    pub fn deinit(self: Map, allocator: std.mem.Allocator) void {
        self.removeAll(allocator);
        self.value.deinit(allocator);
        allocator.destroy(self.value);
    }

    pub fn serializeKeysToWriter(self: Map, writer: *std.Io.Writer) error{WriteFailed}!void {
        try Types.serializeTypeToWriter(.list, writer);
        var iterator = self.value.keyIterator();
        while (iterator.next()) |key|
            try serializeItem(writer, KeyHeaderType, key_header_size, key.*);
    }

    pub fn serializeValuesToWriter(self: Map, writer: *std.Io.Writer) error{WriteFailed}!void {
        try Types.serializeTypeToWriter(.list, writer);
        var iterator = self.value.valueIterator();
        while (iterator.next()) |item|
            try serializeItem(writer, ValueHeaderType, value_header_size, item.*);
    }

    pub fn serializeContentToWriter(self: Map, writer: *std.Io.Writer) error{WriteFailed}!void {
        var iterator = self.get();
        while (iterator.next()) |pair| {
            try serializeItem(writer, KeyHeaderType, key_header_size, pair.key_ptr.*);
            try serializeItem(writer, ValueHeaderType, value_header_size, pair.value_ptr.*);
        }
    }

    fn serializeItem(
        writer: *std.Io.Writer,
        comptime HeaderType: type,
        comptime header_size: u64,
        item: anytype,
    ) error{WriteFailed}!void {
        // each item is wrote as [length header][serialized]
        // [serialized] is [field_type][content]

        // reserve header, writer is derived from std.Io.Writer.Allocating
        const start_header = writer.end;
        // advancing
        try writer.writeInt(HeaderType, 0, .little);

        const start_serialized = writer.end;
        switch (@TypeOf(item)) {
            ScalarItem => try item.serializeToWriter(writer),
            KeyString => try Types.serializeToWriter(.string, writer, item.get()),
            else => unreachable,
        }
        const serialized_size: List.ItemHeaderType = @truncate(writer.end - start_serialized);

        std.mem.writeInt(
            List.ItemHeaderType,
            writer.buffer[start_header .. start_header + header_size][0..header_size],
            serialized_size,
            .little,
        );
    }

    fn putSerializedMap(
        items: *HashMap,
        allocator: std.mem.Allocator,
        serialized: []const u8,
    ) error{ OutOfMemory, UnknownType, InvalidFormat, MismatchType }!void {
        var iterator = try serializedEntriesIterator(serialized);
        const self: Map = .{ .value = items };

        while (try iterator.next()) |entry|
            try self.put(allocator, entry.serialized_key, entry.serialized_value);
    }

    /// Iterator of serialized entries in a serialized Map.
    const Iterator = struct {
        reader: std.Io.Reader,

        const Entry = struct {
            serialized_key: []const u8,
            serialized_value: []const u8,
        };

        fn init(serialized: []const u8) error{ MismatchType, UnknownType, InvalidFormat }!Iterator {
            const field_type, const content = try splitSerialized(serialized);
            if (field_type != .map) return error.MismatchType;
            return .{ .reader = .fixed(content) };
        }

        /// Iterates the next serialized entry in the Map.
        fn next(self: *Iterator) error{InvalidFormat}!?Entry {
            const serialized_key = try self.takeSerialized(KeyHeaderType);
            if (serialized_key == null) return null;
            const serialized_value = try self.takeSerialized(ValueHeaderType);
            if (serialized_value == null) return error.InvalidFormat;

            return .{
                .serialized_key = serialized_key.?,
                .serialized_value = serialized_value.?,
            };
        }

        fn takeSerialized(self: *Iterator, comptime HeaderType: type) error{InvalidFormat}!?[]const u8 {
            const length = self.reader.takeInt(HeaderType, .little) catch return null;
            return self.reader.take(length) catch error.InvalidFormat;
        }
    };

    fn serializedEntriesIterator(
        serialized: []const u8,
    ) error{ MismatchType, UnknownType, InvalidFormat }!Iterator {
        return .init(serialized);
    }
};

const MapEntry = struct {
    key: []const u8,
    serialized_value: []const u8,
};

fn serializeEntries(allocator: std.mem.Allocator, entries: []const MapEntry) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();
    var writer = &allocating.writer;

    try Types.serializeTypeToWriter(.map, writer);

    for (entries) |entry| {
        {
            const hdr_start = writer.end;
            try writer.writeInt(Map.KeyHeaderType, 0, .little);
            const body_start = writer.end;

            try Types.serializeToWriter(.string, writer, entry.key);

            const body_len: Map.KeyHeaderType = @truncate(writer.end - body_start);
            std.mem.writeInt(
                Map.KeyHeaderType,
                writer.buffer[hdr_start .. hdr_start + Map.key_header_size][0..Map.key_header_size],
                body_len,
                .little,
            );
        }
        {
            const hdr_start = writer.end;
            try writer.writeInt(Map.ValueHeaderType, 0, .little);
            const body_start = writer.end;

            try writer.writeAll(entry.serialized_value);

            const body_len: Map.ValueHeaderType = @truncate(writer.end - body_start);
            std.mem.writeInt(
                Map.ValueHeaderType,
                writer.buffer[hdr_start .. hdr_start + Map.value_header_size][0..Map.value_header_size],
                body_len,
                .little,
            );
        }
    }

    return allocating.toOwnedSlice();
}

fn serializeScalarItem(allocator: std.mem.Allocator, item: ScalarItem) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();
    try item.serializeToWriter(&allocating.writer);
    return allocating.toOwnedSlice();
}

fn serializeKey(allocator: std.mem.Allocator, key_with_quotes: []const u8) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();
    try Types.serializeToWriter(.string, &allocating.writer, key_with_quotes);
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

    try std.testing.expect(serialized_all[0] == @intFromEnum(Types.map));

    var m: Map = try .init(allocator, serialized_all);
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
        try std.testing.expect(al.written()[0] == @intFromEnum(Types.list));
    }

    {
        var al: std.Io.Writer.Allocating = .init(allocator);
        defer al.deinit();
        try m.serializeValuesToWriter(&al.writer);
        try std.testing.expect(al.written()[0] == @intFromEnum(Types.list));
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
        try Types.serializeTypeToWriter(.map, &al.writer);
        try m.serializeContentToWriter(&al.writer);
        const roundtrip_buf = try al.toOwnedSlice();
        defer allocator.free(roundtrip_buf);

        var m2: Map = try .init(allocator, roundtrip_buf);
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
