//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of values API and types.

const std = @import("std");
const assert = std.debug.assert;

pub const ScalarItem = @import("value/scalar.zig").ScalarItem;

pub const Void = @import("value/scalar.zig").Void;
pub const Integer = @import("value/scalar.zig").Integer;
pub const Decimal = @import("value/scalar.zig").Decimal;
pub const Flag = @import("value/scalar.zig").Flag;
pub const String = @import("value/scalar.zig").String;
pub const Point = @import("value/scalar.zig").Point;

pub const List = @import("value/collection.zig").List;
pub const Map = @import("value/collection.zig").Map;

// A Rapto's [serialized] (RS) is representation of [value_type][content].
// Content is the raw bytes of the value. Value is the representation of
// content with the return type of get().
//
// Consequently, serializeContentToWriter must write ONLY [content]
// and any function that accepts Content must also accept the corresponding [value_type].
//
// RS is also used to represent a value to send to the client.

/// Splits serialized into [value_type:u8][content].
/// Instead, see `Type.serializeToWriter` to build [serialized].
pub fn splitSerialized(
    serialized: []const u8,
) error{ InvalidFormat, UnknownType }!struct { Type, []const u8 } {
    assert(serialized.len != 0);

    if (serialized.len < @sizeOf(u8)) return error.InvalidFormat;
    const value_type: Type = try .fromInt(serialized[0]);
    const content = if (serialized.len > 1) serialized[1..] else &.{};

    return .{ value_type, content };
}

/// Serializes value type and content to writer as [serialized].
pub fn serializeToWriter(
    writer: *std.Io.Writer,
    value_type: Type,
    content: []const u8,
) std.Io.Writer.Error!void {
    try value_type.serializeToWriter(writer);
    try writer.writeAll(content);
}

/// Enumeration of all value types. The quantity of value types
/// must be equal or under 8: the value type is saved on 3 LSB
/// bits of tagged pointer.
pub const Type = enum(u3) {
    // Scalar types
    void = 0,
    integer,
    decimal,
    flag,
    string,
    point,

    // Collection types
    list,
    map,

    pub fn fromInt(int: anytype) error{UnknownType}!Type {
        return std.enums.fromInt(Type, int) orelse error.UnknownType;
    }

    pub fn serializeToWriter(self: Type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeByte(@intFromEnum(self));
    }
};

pub const Value = union {
    // Scalar types
    void: Void,
    integer: Integer,
    decimal: Decimal,
    flag: Flag,
    string: String,
    point: Point,

    // Collection types
    list: List,
    map: Map,

    /// Returns type of the generic get function.
    /// These types are "complex" to exploit zero-copy returns.
    pub fn ReturnType(comptime value_type: Type) type {
        return switch (value_type) {
            .void => void,
            .integer => i64,
            .decimal => f64,
            .string => []const u8,
            .flag => Flag.Status,
            .point => Point.Axis,
            .list => []ScalarItem,
            .map => Map.HashMap.Iterator,
        };
    }

    /// Returns the complex type of the
    pub fn UnionType(comptime value_type: Type) type {
        return switch (value_type) {
            .void => Void,
            .integer => Integer,
            .decimal => Decimal,
            .flag => Flag,
            .string => String,
            .point => Point,
            .list => List,
            .map => Map,
        };
    }

    pub fn init(
        allocator: std.mem.Allocator,
        value_type: Type,
        content: []const u8,
    ) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType })!Value {
        return switch (value_type) {
            .void => .{ .void = .fromContent() },
            .integer => .{ .integer = try .fromContent(content) },
            .decimal => .{ .decimal = try .fromContent(content) },
            .flag => .{ .flag = try .fromContent(content) },
            .string => .{ .string = try .initFromContent(allocator, content) },
            .point => .{ .point = try .initFromContent(allocator, content) },
            .list => .{ .list = try .initFromContent(allocator, content) },
            .map => .{ .map = try .initFromContent(allocator, content) },
        };
    }

    pub fn set(
        self: *Value,
        allocator: std.mem.Allocator,
        value_type: Type,
        content: []const u8,
    ) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType })!void {
        switch (value_type) {
            .void => self.void.set(),
            inline .integer, .decimal, .flag, .point => |ft| {
                try @field(self, @tagName(ft)).set(content);
            },
            inline .string, .list, .map => |ft| {
                try @field(self, @tagName(ft)).set(allocator, content);
            },
        }
    }

    pub fn get(self: Value, comptime value_type: Type) ReturnType(value_type) {
        return switch (value_type) {
            inline else => |ft| @field(self, @tagName(ft)).get(),
        };
    }

    pub inline fn ptr(self: *Value, value_type: Type) *UnionType(value_type) {
        return switch (value_type) {
            inline else => |ft| &@field(self, @tagName(ft)),
        };
    }

    pub fn serializeContentToWriter(
        self: Value,
        writer: *std.Io.Writer,
        value_type: Type,
    ) std.Io.Writer.Error!void {
        switch (value_type) {
            .void => self.void.serializeContentToWriter(writer),
            inline else => |ft| {
                try @field(self, @tagName(ft)).serializeContentToWriter(writer);
            },
        }
    }

    pub fn deinit(self: Value, allocator: std.mem.Allocator, value_type: Type) void {
        switch (value_type) {
            .void, .integer, .decimal, .flag => {},
            inline else => |ft| @field(self, @tagName(ft)).deinit(allocator),
        }
    }
};

test "Type" {
    const allocator = std.testing.allocator;

    try std.testing.expect(try Type.fromInt(0) == .void);
    try std.testing.expect(try Type.fromInt(1) == .integer);
    try std.testing.expect(try Type.fromInt(2) == .decimal);
    try std.testing.expect(try Type.fromInt(3) == .flag);
    try std.testing.expect(try Type.fromInt(4) == .string);
    try std.testing.expect(try Type.fromInt(5) == .point);
    try std.testing.expect(try Type.fromInt(6) == .list);
    try std.testing.expect(try Type.fromInt(7) == .map);

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    try Type.serializeToWriter(.void, &allocating.writer);
    try std.testing.expect(0 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Type.serializeToWriter(.integer, &allocating.writer);
    try std.testing.expect(1 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Type.serializeToWriter(.decimal, &allocating.writer);
    try std.testing.expect(2 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Type.serializeToWriter(.flag, &allocating.writer);
    try std.testing.expect(3 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Type.serializeToWriter(.string, &allocating.writer);
    try std.testing.expect(4 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Type.serializeToWriter(.point, &allocating.writer);
    try std.testing.expect(5 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Type.serializeToWriter(.list, &allocating.writer);
    try std.testing.expect(6 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Type.serializeToWriter(.map, &allocating.writer);
    try std.testing.expect(7 == allocating.written()[0]);
    allocating.clearRetainingCapacity();
}
