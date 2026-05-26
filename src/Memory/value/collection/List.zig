//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of list.

/// List value type represented as list of scalar items.
const List = @This();

const std = @import("std");
const value = @import("../../value.zig");
const frames = @import("../../../frames.zig");
const assert = std.debug.assert;

const ScalarItem = @import("../scalar.zig").ScalarItem;

ptr: *std.ArrayList(ScalarItem),

pub fn initFromContent(
    allocator: std.mem.Allocator,
    content: []const u8,
) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType })!List {
    const list_ptr = try allocator.create(std.ArrayList(ScalarItem));
    errdefer allocator.destroy(list_ptr);

    list_ptr.* = .empty;
    try appendSerializedList(list_ptr, allocator, content);
    return .{ .ptr = list_ptr };
}

/// Inserts or appends a serialized scalar type or a List.
pub fn insert(
    self: *List,
    allocator: std.mem.Allocator,
    index: u64,
    serialized: []const u8,
) (std.mem.Allocator.Error || error{ MismatchType, InvalidFormat, UnknownType })!void {
    const value_type, const content = try value.splitSerialized(serialized);

    switch (value_type) {
        else => {
            const item: ScalarItem = try .fromContent(allocator, value_type, content);
            return self.insertItem(allocator, index, item);
        },
        .list => {
            var offset: u64 = 0;
            var iterator = try serializedItemsIterator(serialized);
            while (iterator.next()) |serialized_value| : (offset += 1) {
                const value_type_item, const content_item =
                    try value.splitSerialized(serialized_value);

                const item: ScalarItem = try .fromContent(allocator, value_type_item, content_item);
                try self.insertItem(allocator, index + offset, item);
            }
        },

        .map => return error.MismatchType,
    }
}

fn insertItem(
    self: *List,
    allocator: std.mem.Allocator,
    index: u64,
    item: ScalarItem,
) (std.mem.Allocator.Error || error{ MismatchType, InvalidFormat })!void {
    return if (index >= self.count())
        self.ptr.append(allocator, item)
    else
        self.ptr.insert(allocator, index, item);
}

/// Replaces List with a new serialized list.
pub fn set(
    self: *List,
    allocator: std.mem.Allocator,
    serialized: []const u8,
) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType })!void {
    self.removeAll(allocator);
    try appendSerializedList(self.ptr, allocator, serialized);
}

pub fn setByIndex(
    self: List,
    allocator: std.mem.Allocator,
    index: u64,
    serialized: []const u8,
) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, RangeOverflow, UnknownType })!void {
    if (index >= self.count()) return error.RangeOverflow;

    const value_type, const content = try value.splitSerialized(serialized);

    self.ptr.items[index].deinit(allocator);
    self.ptr.items[index] = try .fromContent(allocator, value_type, content);
}

pub fn get(self: List) []const ScalarItem {
    if (self.count() == 0) return &.{};
    return self.getByRange(0, self.count() - 1) catch |err| switch (err) {
        error.RangeOverflow => unreachable,
    };
}

pub fn getByIndex(self: List, index: u64) error{RangeOverflow}!ScalarItem {
    const range = try self.getByRange(index, index);
    return range[0];
}

pub fn getByRange(
    self: List,
    from_index: u64,
    to_index: u64,
) error{RangeOverflow}![]const ScalarItem {
    if (from_index > to_index or to_index >= self.count()) return error.RangeOverflow;
    return self.ptr.items[from_index .. to_index + 1];
}

pub fn indexOfItemInRange(
    self: List,
    allocator: std.mem.Allocator,
    serialized: []const u8,
    from_index: u64,
    to_index: u64,
) (std.mem.Allocator.Error || error{ MismatchType, InvalidFormat, RangeOverflow, ItemNotFound, UnknownType })!u64 {
    if (from_index > to_index or to_index >= self.count()) return error.RangeOverflow;

    const value_type, const content = try value.splitSerialized(serialized);

    const this_item: ScalarItem = try .fromContent(allocator, value_type, content);
    defer this_item.deinit(allocator);

    for (from_index..to_index + 1) |index| {
        const item = self.ptr.items[index];
        if (this_item.compare(item)) return index;
    }

    return error.ItemNotFound;
}

pub fn indexOfItem(
    self: List,
    allocator: std.mem.Allocator,
    serialized: []const u8,
) (std.mem.Allocator.Error || error{ MismatchType, InvalidFormat, RangeOverflow, ItemNotFound, UnknownType })!u64 {
    if (self.count() == 0) return error.ItemNotFound;
    return self.indexOfItemInRange(
        allocator,
        serialized,
        0,
        self.count() - 1,
    ) catch |err| switch (err) {
        else => |e| e,
        error.RangeOverflow => unreachable,
    };
}

pub fn removeByRange(
    self: List,
    allocator: std.mem.Allocator,
    from_index: u64,
    to_index: u64,
) error{RangeOverflow}!void {
    if (self.count() == 0) return;
    if (from_index > to_index or to_index >= self.count()) return error.RangeOverflow;
    for (self.ptr.items[from_index .. to_index + 1]) |item| item.deinit(allocator);
    self.ptr.replaceRangeAssumeCapacity(from_index, to_index - from_index + 1, &.{});
}

pub fn removeAll(self: List, allocator: std.mem.Allocator) void {
    if (self.count() == 0) return;
    self.removeByRange(allocator, 0, self.count() - 1) catch |err| switch (err) {
        error.RangeOverflow => unreachable,
    };
}

pub fn count(self: List) u64 {
    return self.ptr.items.len;
}

pub fn serializeContentInRangeToWriter(
    self: List,
    writer: *std.Io.Writer,
    from_index: u64,
    to_index: u64,
) error{ WriteFailed, RangeOverflow }!void {
    if (from_index > to_index or to_index >= self.count()) return error.RangeOverflow;

    for (self.ptr.items[from_index .. to_index + 1]) |item| {
        var builder: frames.Builder = try .begin(writer);
        defer builder.end();
        try item.serializeToWriter(writer);
    }
}

pub fn serializeContentToWriter(self: List, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const length = self.count();
    if (length == 0) return;
    return self.serializeContentInRangeToWriter(writer, 0, length - 1) catch |err| switch (err) {
        error.WriteFailed => |e| e,
        error.RangeOverflow => unreachable,
    };
}

pub fn deinit(self: List, allocator: std.mem.Allocator) void {
    self.removeAll(allocator);
    self.ptr.deinit(allocator);
    allocator.destroy(self.ptr);
}

fn appendSerializedList(
    items: *std.ArrayList(ScalarItem),
    allocator: std.mem.Allocator,
    serialized_list: []const u8,
) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType })!void {
    var iterator = try serializedItemsIterator(serialized_list);

    while (iterator.next()) |serialized_value| {
        const value_type, const content = try value.splitSerialized(serialized_value);

        const item: ScalarItem = try .fromContent(allocator, value_type, content);
        errdefer item.deinit(allocator);
        try items.append(allocator, item);
    }
}

fn serializedItemsIterator(
    serialized: []const u8,
) error{ MismatchType, InvalidFormat, UnknownType }!frames.Iterator {
    const value_type, const content = try value.splitSerialized(serialized);
    if (value_type != .list) return error.MismatchType;
    return .init(content);
}

test "List" {
    const allocator = std.testing.allocator;

    var si1 = try ScalarItem.fromContent(allocator, .integer, &@as([8]u8, @bitCast(@as(u64, 10))));
    defer si1.deinit(allocator);

    var sf1 = try ScalarItem.fromContent(allocator, .flag, &@as([8]u8, @bitCast(@as(u64, 1))));
    defer sf1.deinit(allocator);

    const serialized = try serializeItems(allocator, &.{ si1, sf1 });
    defer allocator.free(serialized);

    var s: List = try .initFromContent(allocator, serialized);
    defer s.deinit(allocator);

    try std.testing.expect(s.count() == 2);
    try std.testing.expect((try s.getByIndex(0)).integer.get() == 10);
    try std.testing.expect((try s.getByIndex(1)).flag.get() == .true);

    var pw_allocating: std.Io.Writer.Allocating = .init(allocator);
    defer pw_allocating.deinit();
    var pw = &pw_allocating.writer;

    var str_item = try ScalarItem.fromContent(allocator, .string, "example, \"string\"");
    defer str_item.deinit(allocator);
    _ = pw.consumeAll();
    try str_item.serializeToWriter(pw);
    try s.insert(allocator, s.count(), pw.buffered());

    _ = pw.consumeAll();
    try pw.writeInt(u64, @bitCast(@as(f64, 1)), .little);
    try pw.writeInt(u64, @bitCast(@as(f64, 2)), .little);
    try pw.writeInt(u64, @bitCast(@as(f64, 3)), .little);
    var point_item = try ScalarItem.fromContent(allocator, .point, pw.buffered());
    defer point_item.deinit(allocator);
    _ = pw.consumeAll();
    try point_item.serializeToWriter(pw);
    try s.insert(allocator, 0, pw.buffered());

    var err_flag = try ScalarItem.fromContent(allocator, .flag, &@as([8]u8, @bitCast(@as(u64, 3))));
    defer err_flag.deinit(allocator);
    var tmp = try serializeItems(allocator, &.{err_flag});
    try s.insert(allocator, 0, tmp);
    allocator.free(tmp);

    var dec_item = try ScalarItem.fromContent(allocator, .decimal, &@as([8]u8, @bitCast(@as(u64, @bitCast(@as(f64, 3.14))))));
    defer dec_item.deinit(allocator);
    tmp = try serializeItems(allocator, &.{dec_item});
    try s.insert(allocator, 1, tmp);
    allocator.free(tmp);

    try std.testing.expect(s.count() == 6);
    try std.testing.expect((try s.getByIndex(0)).flag.get() == .@"error");
    try std.testing.expect((try s.getByIndex(1)).decimal.get() == 3.14);
    {
        const ax = (try s.getByIndex(2)).point.get();
        try std.testing.expect(ax.x.get() == 1);
        try std.testing.expect(ax.y.get() == 2);
        try std.testing.expect(ax.z.get() == 3);
    }
    try std.testing.expect((try s.getByIndex(3)).integer.get() == 10);
    try std.testing.expect((try s.getByIndex(4)).flag.get() == .true);
    try std.testing.expectEqualStrings("example, \"string\"", (try s.getByIndex(5)).string.get());

    var str2 = try ScalarItem.fromContent(allocator, .string, "example2");
    defer str2.deinit(allocator);
    _ = pw.consumeAll();
    try str2.serializeToWriter(pw);
    try s.setByIndex(allocator, 3, pw.buffered());
    try std.testing.expectEqualStrings("example2", (try s.getByIndex(3)).string.get());

    var void_item = try ScalarItem.fromContent(allocator, .void, &.{});
    defer void_item.deinit(allocator);
    _ = pw.consumeAll();
    try void_item.serializeToWriter(pw);
    try s.setByIndex(allocator, 4, pw.buffered());
    try std.testing.expect(s.count() == 6);

    try std.testing.expectError(error.RangeOverflow, s.setByIndex(allocator, 99, pw.buffered()));

    try std.testing.expectError(error.RangeOverflow, s.getByIndex(99));

    try std.testing.expect((try s.getByRange(0, 2)).len == 3);
    try std.testing.expectError(error.RangeOverflow, s.getByRange(3, 1));
    try std.testing.expectError(error.RangeOverflow, s.getByRange(0, 99));

    try std.testing.expect(s.get().len == s.count());

    try s.removeByRange(allocator, 1, 2);
    try std.testing.expect(s.count() == 4);

    _ = pw.consumeAll();
    try err_flag.serializeToWriter(pw);
    try std.testing.expect(try s.indexOfItem(allocator, pw.buffered()) == 0);

    try std.testing.expectError(error.MismatchType, s.indexOfItem(allocator, serialized));

    var dec_item2 = try ScalarItem.fromContent(allocator, .decimal, &@as([8]u8, @bitCast(@as(u64, @bitCast(@as(f64, 3.14))))));
    defer dec_item2.deinit(allocator);
    _ = pw.consumeAll();
    try dec_item2.serializeToWriter(pw);
    try std.testing.expectError(error.ItemNotFound, s.indexOfItem(allocator, pw.buffered()));

    _ = pw.consumeAll();
    try err_flag.serializeToWriter(pw);
    try std.testing.expectError(error.RangeOverflow, s.indexOfItemInRange(allocator, pw.buffered(), 2, 1));
    try std.testing.expectError(error.RangeOverflow, s.indexOfItemInRange(allocator, pw.buffered(), 0, 99));

    s.removeAll(allocator);
    try s.set(allocator, serialized);
    try std.testing.expect(s.count() > 0);

    s.removeAll(allocator);
    _ = pw.consumeAll();
    try std.testing.expect(s.get().len == 0);
    try std.testing.expectError(error.RangeOverflow, s.serializeContentInRangeToWriter(pw, 0, 0));
    try s.serializeContentToWriter(pw);
    try std.testing.expect(pw.buffered().len == 0);

    try std.testing.expectError(error.MismatchType, ScalarItem.fromContent(allocator, .map, &.{}));
    try std.testing.expectError(error.MismatchType, ScalarItem.fromContent(allocator, .list, &.{}));
}

fn serializeItems(allocator: std.mem.Allocator, items: []const ScalarItem) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();
    const writer = &allocating.writer;

    try value.Type.serializeToWriter(.list, writer);
    for (items) |item| {
        var builder: frames.Builder = try .begin(writer);
        defer builder.end();
        try item.serializeToWriter(writer);
    }

    return allocating.toOwnedSlice();
}
