//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of list.

/// List value type represented as list of scalar items.
const List = @This();

const std = @import("std");
const frames = @import("../../frames.zig");
const assert = std.debug.assert;

const Value = @import("../../object.zig").Value;
const Scalar = @import("../scalar.zig").Scalar;

pub const Error = std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType };

ptr: *std.ArrayList(Scalar),

pub fn init(allocator: std.mem.Allocator) Error!List {
    const list_ptr = try allocator.create(std.ArrayList(Scalar));
    errdefer allocator.destroy(list_ptr);
    list_ptr.* = .empty;
    return .{ .ptr = list_ptr };
}

pub fn deinit(self: List, allocator: std.mem.Allocator) void {
    self.removeAll(allocator);
    self.ptr.deinit(allocator);
    allocator.destroy(self.ptr);
}

pub fn insert(
    self: List,
    allocator: std.mem.Allocator,
    index: u64,
    serialized: []const u8,
) Error!void {
    const value_type, const content = try Value.splitSerialized(serialized);
    const item: Scalar = try .initFromContent(allocator, value_type, content);
    errdefer item.deinit(allocator);
    return self.ptr.insert(allocator, @min(index, self.count()), item);
}

pub fn dupe(
    self: List,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!List {
    const list_ptr = try allocator.create(std.ArrayList(Scalar));
    errdefer allocator.destroy(list_ptr);

    list_ptr.* = try .initCapacity(allocator, self.count());
    errdefer list_ptr.deinit(allocator);
    for (self.ptr.items) |item| list_ptr.appendAssumeCapacity(try item.dupe(allocator));

    return .{ .ptr = list_ptr };
}

pub fn setByIndex(
    self: List,
    allocator: std.mem.Allocator,
    index: u64,
    serialized: []const u8,
) Error!void {
    const fixed_index = @min(index, self.count() - 1);
    const value_type, const content = try Value.splitSerialized(serialized);
    self.ptr.items[fixed_index].deinit(allocator);
    self.ptr.items[fixed_index] = try .initFromContent(allocator, value_type, content);
}

pub const Serializer = struct {
    writer: *std.Io.Writer,

    /// Assumes writer is derived from std.Io.Writer.Allocating.
    pub fn begin(writer: *std.Io.Writer) std.mem.Allocator.Error!Serializer {
        Value.Type.serializeToWriter(
            .list,
            writer,
        ) catch |err| return switch (err) {
            error.WriteFailed => error.OutOfMemory,
        };
        return .{ .writer = writer };
    }

    pub fn beginFrame(self: Serializer) std.mem.Allocator.Error!frames.Builder {
        return .begin(self.writer);
    }

    /// For conventional purpose; this is no-op.
    pub fn end(self: Serializer) void {
        _ = self;
    }
};

pub fn get(self: List) []const Scalar {
    if (self.count() == 0) return &.{};
    return self.getByRange(0, self.count()) catch |err| switch (err) {
        error.RangeOverflow => unreachable,
    };
}

pub fn getByRange(self: List, start: u64, len: u64) error{RangeOverflow}![]const Scalar {
    if (start + len > self.count()) return error.RangeOverflow;
    return self.ptr.items[start..][0..len];
}

pub fn indexOfItemInRange(
    self: List,
    allocator: std.mem.Allocator,
    serialized: []const u8,
    from_index: u64,
    to_index: u64,
) (std.mem.Allocator.Error || error{ MismatchType, InvalidFormat, RangeOverflow, ItemNotFound, UnknownType })!u64 {
    if (from_index > to_index or to_index >= self.count()) return error.RangeOverflow;

    const value_type, const content = try Value.splitSerialized(serialized);

    const expected: Scalar = try .initFromContent(allocator, value_type, content);
    defer expected.deinit(allocator);

    for (from_index..to_index + 1) |index| {
        const actual = self.ptr.items[index];
        if (expected.compare(actual)) return index;
    }

    return error.ItemNotFound;
}

pub fn removeByRange(
    self: List,
    allocator: std.mem.Allocator,
    start: u64,
    len: u64,
) error{RangeOverflow}!void {
    if (start + len > self.count()) return error.RangeOverflow;

    for (self.ptr.items[start..][0..len]) |item| item.deinit(allocator);
    self.ptr.replaceRangeAssumeCapacity(start, len, &.{});
}

pub fn removeAll(self: List, allocator: std.mem.Allocator) void {
    if (self.count() == 0) return;
    self.removeByRange(
        allocator,
        0,
        self.count(),
    ) catch |err| switch (err) {
        error.RangeOverflow => unreachable,
    };
}

pub fn count(self: List) u64 {
    return self.ptr.items.len;
}

pub const Iterator = struct {
    wrapped_iterator: frames.Iterator,

    pub fn init(content: []const u8) Iterator {
        return .{ .wrapped_iterator = .init(content) };
    }

    pub fn next(self: *Iterator) ?[]const u8 {
        return self.wrapped_iterator.next();
    }
};

test "List" {
    const allocator = std.testing.allocator;

    var si1: Scalar = try .initFromContent(allocator, .integer, &@as([8]u8, @bitCast(@as(u64, 10))));
    defer si1.deinit(allocator);

    var sf1: Scalar = try .initFromContent(allocator, .flag, &@as([8]u8, @bitCast(@as(u64, 1))));
    defer sf1.deinit(allocator);

    var s: List = try .init(allocator);
    defer s.deinit(allocator);

    var pw_allocating: std.Io.Writer.Allocating = .init(allocator);
    defer pw_allocating.deinit();
    var pw = &pw_allocating.writer;

    _ = pw.consumeAll();
    try si1.serializeToWriter(pw);
    try s.insert(allocator, s.count(), pw.buffered());

    _ = pw.consumeAll();
    try sf1.serializeToWriter(pw);
    try s.insert(allocator, s.count(), pw.buffered());

    try std.testing.expect(s.count() == 2);

    var str_item: Scalar = try .initFromContent(allocator, .string, "example, \"string\"");
    defer str_item.deinit(allocator);
    _ = pw.consumeAll();
    try str_item.serializeToWriter(pw);
    try s.insert(allocator, s.count(), pw.buffered());

    try std.testing.expect(s.count() == 3);

    _ = pw.consumeAll();
    try pw.writeInt(u64, @bitCast(@as(f64, 1)), .little);
    try pw.writeInt(u64, @bitCast(@as(f64, 2)), .little);
    try pw.writeInt(u64, @bitCast(@as(f64, 3)), .little);
    var point_item: Scalar = try .initFromContent(allocator, .point, pw.buffered());
    defer point_item.deinit(allocator);
    _ = pw.consumeAll();
    try point_item.serializeToWriter(pw);
    try s.insert(allocator, 0, pw.buffered());

    try std.testing.expect(s.count() == 4);

    var err_flag: Scalar = try .initFromContent(allocator, .flag, &@as([8]u8, @bitCast(@as(u64, 3))));
    defer err_flag.deinit(allocator);
    _ = pw.consumeAll();
    try err_flag.serializeToWriter(pw);
    try s.insert(allocator, 0, pw.buffered());

    try std.testing.expect(s.count() == 5);

    var dec_item: Scalar = try .initFromContent(allocator, .decimal, &@as([8]u8, @bitCast(@as(u64, @bitCast(@as(f64, 3.14))))));
    defer dec_item.deinit(allocator);
    _ = pw.consumeAll();
    try dec_item.serializeToWriter(pw);
    try s.insert(allocator, 1, pw.buffered());

    try std.testing.expect(s.count() == 6);
    try std.testing.expect((try s.getByRange(0, 1))[0].flag.get() == .@"error");
    try std.testing.expect((try s.getByRange(1, 1))[0].decimal.get() == 3.14);
    {
        const ax = (try s.getByRange(2, 1))[0].point.get();
        try std.testing.expect(ax.x.get() == 1);
        try std.testing.expect(ax.y.get() == 2);
        try std.testing.expect(ax.z.get() == 3);
    }
    try std.testing.expect((try s.getByRange(3, 1))[0].integer.get() == 10);
    try std.testing.expect((try s.getByRange(4, 1))[0].flag.get() == .true);
    try std.testing.expectEqualStrings(
        "example, \"string\"",
        (try s.getByRange(5, 1))[0].string.get(),
    );

    var str2: Scalar = try .initFromContent(allocator, .string, "example2");
    defer str2.deinit(allocator);
    _ = pw.consumeAll();
    try str2.serializeToWriter(pw);
    try s.setByIndex(allocator, 3, pw.buffered());
    try std.testing.expectEqualStrings("example2", (try s.getByRange(3, 1))[0].string.get());

    var void_item: Scalar = try .initFromContent(allocator, .void, &.{});
    defer void_item.deinit(allocator);
    _ = pw.consumeAll();
    try void_item.serializeToWriter(pw);
    try s.setByIndex(allocator, 4, pw.buffered());
    try std.testing.expect(s.count() == 6);

    try std.testing.expectError(error.RangeOverflow, s.getByRange(99, 99));

    try std.testing.expect((try s.getByRange(0, 3)).len == 3);
    try std.testing.expectError(error.RangeOverflow, s.getByRange(99, 1));
    try std.testing.expectError(error.RangeOverflow, s.getByRange(0, 99));

    try std.testing.expect(s.get().len == s.count());

    try s.removeByRange(allocator, 1, 2);
    try std.testing.expect(s.count() == 4);

    _ = pw.consumeAll();
    try err_flag.serializeToWriter(pw);
    try std.testing.expect(try s.indexOfItemInRange(allocator, pw.buffered(), 0, s.count() - 1) == 0);

    var dec_item2: Scalar = try .initFromContent(allocator, .decimal, &@as([8]u8, @bitCast(@as(u64, @bitCast(@as(f64, 3.14))))));
    defer dec_item2.deinit(allocator);
    _ = pw.consumeAll();
    try dec_item2.serializeToWriter(pw);
    try std.testing.expectError(error.ItemNotFound, s.indexOfItemInRange(allocator, pw.buffered(), 0, s.count() - 1));

    _ = pw.consumeAll();
    try err_flag.serializeToWriter(pw);
    try std.testing.expectError(error.RangeOverflow, s.indexOfItemInRange(allocator, pw.buffered(), 2, 1));
    try std.testing.expectError(error.RangeOverflow, s.indexOfItemInRange(allocator, pw.buffered(), 0, 99));

    s.removeAll(allocator);
    try std.testing.expect(s.count() == 0);
    try std.testing.expectError(error.RangeOverflow, s.removeByRange(allocator, 0, 1));
    try std.testing.expectError(error.RangeOverflow, s.removeByRange(allocator, 0, 3));
    try std.testing.expectError(error.RangeOverflow, s.removeByRange(allocator, 10, 1));

    try std.testing.expect(s.get().len == 0);

    try std.testing.expectError(error.MismatchType, Scalar.initFromContent(allocator, .map, &.{}));
    try std.testing.expectError(error.MismatchType, Scalar.initFromContent(allocator, .list, &.{}));
}
