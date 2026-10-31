//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of values.

const std = @import("std");
const frames = @import("frames.zig");
const assert = std.debug.assert;

pub const Integer = extern struct {
    value: i64,

    pub fn fromOwnedSlice(data: []const u8) error{InvalidFormat}!Integer {
        if (data.len != @sizeOf(i64)) return error.InvalidFormat;
        return .{ .value = std.mem.bytesToValue(i64, data) };
    }

    pub fn from(value: i64) Integer {
        return .{ .value = value };
    }

    pub fn add(self: Integer, other: Integer) error{MathOverflow}!Integer {
        const result = std.math.add(i64, self.value, other.value) catch
            return error.MathOverflow;
        return .from(result);
    }

    pub fn sub(self: Integer, other: Integer) error{MathOverflow}!Integer {
        const result = std.math.sub(i64, self.value, other.value) catch
            return error.MathOverflow;
        return .from(result);
    }

    pub fn bytes(self: *const Integer) []const u8 {
        return std.mem.asBytes(&self.value);
    }
};

pub const Decimal = extern struct {
    value: f64,

    pub fn fromOwnedSlice(data: []const u8) error{InvalidFormat}!Decimal {
        if (data.len != @sizeOf(f64)) return error.InvalidFormat;
        return .{ .value = std.mem.bytesToValue(f64, data) };
    }

    pub fn from(value: f64) Decimal {
        return .{ .value = value };
    }

    pub fn add(self: Decimal, other: Decimal) error{MathOverflow}!Decimal {
        const result = self.value + other.value;
        if (!std.math.isFinite(result)) return error.MathOverflow;
        return .from(result);
    }

    pub fn sub(self: Decimal, other: Decimal) error{MathOverflow}!Decimal {
        const result = self.value - other.value;
        if (!std.math.isFinite(result)) return error.MathOverflow;
        return .from(result);
    }

    pub fn bytes(self: *const Decimal) []const u8 {
        return std.mem.asBytes(&self.value);
    }
};

pub const String = struct {
    value: []const u8,

    pub fn fromOwnedSlice(data: []const u8) String {
        return .{ .value = data };
    }

    pub fn from(value: []const u8) String {
        return .{ .value = value };
    }

    pub fn appendToWriter(
        self: String,
        writer: *std.Io.Writer,
        content: String,
    ) std.Io.Writer.Error!void {
        var vec: [2][]const u8 = .{ self.value, content.value };
        try writer.writeVecAll(&vec);
    }

    pub fn insertToWriter(
        self: String,
        writer: *std.Io.Writer,
        content: String,
        index: u64,
    ) (std.Io.Writer.Error || error{RangeOverflow})!void {
        if (index > self.len()) return error.RangeOverflow;
        var vec: [3][]const u8 = .{ self.value[0..index], content.value, self.value[index..] };
        try writer.writeVecAll(&vec);
    }

    pub fn replaceToWriter(
        self: String,
        writer: *std.Io.Writer,
        content: String,
        index: u64,
    ) (std.Io.Writer.Error || error{RangeOverflow})!void {
        if (index > self.len() or content.len() > self.len() - index) return error.RangeOverflow;
        var vec: [3][]const u8 = .{ self.value[0..index], content.value, self.value[index + content.len() ..] };
        try writer.writeVecAll(&vec);
    }

    pub fn len(self: String) u64 {
        return self.value.len;
    }

    pub fn bytes(self: String) []const u8 {
        return self.value;
    }
};

pub const Point = struct {
    value: PointValue,

    const PointValue = extern struct {
        x: Decimal,
        y: Decimal,
        z: Decimal,
    };

    pub fn fromOwnedSlice(data: []const u8) error{InvalidFormat}!Point {
        if (data.len != @sizeOf(PointValue)) return error.InvalidFormat;
        return .{ .value = std.mem.bytesToValue(PointValue, data) };
    }

    pub fn from(x: Decimal, y: Decimal, z: Decimal) Point {
        return .{ .value = .{ .x = x, .y = y, .z = z } };
    }

    pub fn bytes(self: *const Point) []const u8 {
        return std.mem.asBytes(&self.value);
    }
};

pub const List = struct {
    pub const Header = u32;

    value: []const u8,

    pub const empty: List = .{ .value = &.{} };

    pub fn fromOwnedSlice(data: []const u8) List {
        return .{ .value = data };
    }

    pub fn get(self: List, index: u64) (Union.DeserializeError || error{RangeOverflow})!Union {
        const range = self.getRange(index, 1);
        var items: frames.IteratorType(Header) = .init(range.value);
        const serialized = items.next() orelse return error.RangeOverflow;
        return .deserialize(serialized);
    }

    pub fn getRange(self: List, from: u64, length: u64) List {
        var items: frames.IteratorType(Header) = .init(self.value);
        for (0..from) |_| _ = items.next() orelse break;
        const start = items.seek;
        for (0..length) |_| _ = items.next() orelse break;
        return .fromOwnedSlice(self.value[start..items.seek]);
    }

    pub fn count(self: List) u64 {
        var items: frames.IteratorType(Header) = .init(self.value);
        return items.len();
    }

    pub fn appendToWriter(
        self: List,
        writer: *std.Io.Writer,
        item: Union,
    ) (std.Io.Writer.Error || error{ RangeOverflow, MismatchType })!void {
        return self.spliceToWriter(writer, item, self.value.len, self.value.len);
    }

    pub fn insertToWriter(
        self: List,
        writer: *std.Io.Writer,
        item: Union,
        index: u64,
    ) (std.Io.Writer.Error || error{ RangeOverflow, MismatchType })!void {
        var items: frames.IteratorType(Header) = .init(self.value);
        for (0..index) |_| _ = items.next() orelse return error.RangeOverflow;
        return self.spliceToWriter(writer, item, items.seek, items.seek);
    }

    pub fn replaceToWriter(
        self: List,
        writer: *std.Io.Writer,
        item: Union,
        index: u64,
    ) (std.Io.Writer.Error || error{ RangeOverflow, MismatchType })!void {
        var items: frames.IteratorType(Header) = .init(self.value);
        for (0..index) |_| _ = items.next() orelse return error.RangeOverflow;
        const start = items.seek;
        _ = items.next() orelse return error.RangeOverflow;
        return self.spliceToWriter(writer, item, start, items.seek);
    }

    pub fn removeRangeToWriter(
        self: List,
        writer: *std.Io.Writer,
        from: u64,
        length: u64,
    ) std.Io.Writer.Error!void {
        const range = self.getRange(from, length);
        const start = @intFromPtr(range.value.ptr) - @intFromPtr(self.value.ptr);
        var vec: [2][]const u8 = .{ self.value[0..start], self.value[start + range.value.len ..] };
        try writer.writeVecAll(&vec);
    }

    fn spliceToWriter(
        self: List,
        writer: *std.Io.Writer,
        item: Union,
        start: u64,
        end: u64,
    ) (std.Io.Writer.Error || error{ RangeOverflow, MismatchType })!void {
        if (item.type() == .list) return error.MismatchType;
        const item_len = @sizeOf(u8) + item.bytes().len;
        if (item_len > std.math.maxInt(Header)) return error.RangeOverflow;
        try writer.writeAll(self.value[0..start]);
        try writer.writeInt(Header, @intCast(item_len), .little);
        try item.serializeToWriter(writer);
        try writer.writeAll(self.value[end..]);
    }

    /// Builds a serialized list on a buffered writer.
    /// It writes type and then items with `beginItem()`.
    pub const Serializer = struct {
        writer: *std.Io.Writer,

        pub fn begin(writer: *std.Io.Writer) std.Io.Writer.Error!Serializer {
            const val: Union = .{ .list = .empty };
            try val.serializeToWriter(writer);
            return .{ .writer = writer };
        }

        pub fn beginItem(self: Serializer) std.mem.Allocator.Error!frames.BuilderType(Header) {
            return .begin(self.writer);
        }
    };

    pub const Iterator = struct {
        wrapped_iterator: frames.IteratorType(Header),

        pub fn next(self: *Iterator) Union.DeserializeError!?Union {
            const serialized = self.wrapped_iterator.next() orelse return null;
            return try .deserialize(serialized);
        }
    };

    pub fn iterator(self: List) Iterator {
        return .{ .wrapped_iterator = .init(self.value) };
    }

    pub fn bytes(self: List) []const u8 {
        return self.value;
    }
};

pub const Type = std.meta.FieldEnum(Union);

pub const Union = union(enum(u4)) {
    pub const Error = error{InvalidFormat};

    void,
    integer: Integer,
    decimal: Decimal,
    string: String,
    point: Point,
    list: List,

    pub fn fromOwnedSlice(value_type: Type, data: []const u8) Error!Union {
        return switch (value_type) {
            .void => .void,
            inline .string, .list => |t| @unionInit(
                Union,
                @tagName(t),
                .fromOwnedSlice(data),
            ),
            inline else => |t| @unionInit(
                Union,
                @tagName(t),
                try .fromOwnedSlice(data),
            ),
        };
    }

    pub const DeserializeError = error{ InvalidFormat, UnknownType };

    pub fn deserialize(serialized: []const u8) DeserializeError!Union {
        const value_type: Type = std.enums.fromInt(Type, serialized[0]) orelse
            return error.UnknownType;
        const content = serialized[1..];
        return .fromOwnedSlice(value_type, content);
    }

    pub fn serializeToWriter(self: Union, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const t: u8 = @backingInt(self.type());
        var vec: [2][]const u8 = .{ &.{t}, self.bytes() };
        return writer.writeVecAll(&vec);
    }

    pub fn @"type"(self: Union) Type {
        return std.meta.activeTag(self);
    }

    pub fn bytes(self: *const Union) []const u8 {
        return switch (self.*) {
            .void => &.{},
            inline else => |_, tag| @field(self, @tagName(tag)).bytes(),
        };
    }
};
