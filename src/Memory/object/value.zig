//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of values API and types.

const std = @import("std");
const frames = @import("../../frames.zig");
const assert = std.debug.assert;

pub const ScalarValue = @import("value/scalar.zig").ScalarValue;

pub const Void = @import("value/scalar.zig").Void;
pub const Integer = @import("value/scalar.zig").Integer;
pub const Decimal = @import("value/scalar.zig").Decimal;
pub const Flag = @import("value/scalar.zig").Flag;
pub const String = @import("value/scalar.zig").String;
pub const Point = @import("value/scalar.zig").Point;

pub const List = @import("value/collection.zig").List;
pub const Map = @import("value/collection.zig").Map;

// A Rapto's [serialized] (RS) is representation of [len][value_type][content].
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

/// Serializes value to writer as [serialized].
/// Only scalars can be serialized.
pub fn serializeToWriter(
    writer: *std.Io.Writer,
    value: anytype,
) std.Io.Writer.Error!void {
    const value_type: Type = .of(value);
    assert(value_type != .list and value_type != .map);
    try value_type.serializeToWriter(writer);
    return value.serializeContentToWriter(writer);
}

/// Hardcoded method to serialize error as serializing
/// with `serializeToWriter`. `err` MUST have a method
/// called `writeError`.
pub fn errorToWriter(writer: *std.Io.Writer, err: anytype) std.Io.Writer.Error!void {
    try writer.writeInt(u8, std.math.maxInt(u8), .little);
    try err.writeError(writer);
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

    pub fn of(value: anytype) Type {
        const ValueType = @TypeOf(value);
        inline for (std.meta.fields(Value)) |field| {
            if (field.type == ValueType) {
                return std.meta.stringToEnum(Type, field.name) orelse unreachable;
            }
        }
        unreachable;
    }

    pub fn group(self: Type) enum { scalar, collection } {
        return switch (self) {
            .list, .map => .collection,
            else => .scalar,
        };
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
        const get_fn = UnionType(value_type).get;
        return @typeInfo(@TypeOf(get_fn)).@"fn".return_type orelse unreachable;
    }

    test ReturnType {
        assert(ReturnType(.void) == void);
        assert(ReturnType(.decimal) == f64);
        assert(ReturnType(.string) == []const u8);
        assert(ReturnType(.list) == []const ScalarValue);
    }

    pub fn UnionType(comptime value_type: Type) type {
        @setEvalBranchQuota(2000);
        const tag = comptime std.meta.stringToEnum(std.meta.FieldEnum(Value), @tagName(value_type));
        return std.meta.fieldInfo(Value, tag orelse unreachable).type;
    }

    pub fn init(
        allocator: std.mem.Allocator,
        value_type: Type,
        content: []const u8,
    ) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType, InvalidKey })!Value {
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

    pub fn dupe(
        self: Value,
        allocator: std.mem.Allocator,
        comptime value_type: Type,
    ) std.mem.Allocator.Error!UnionType(value_type) {
        return switch (value_type) {
            inline .point, .string, .list, .map => |t| @field(self, @tagName(t)).dupe(allocator),
            inline else => |t| @field(self, @tagName(t)).dupe(),
        };
    }

    pub fn set(
        self: *Value,
        allocator: std.mem.Allocator,
        value_type: Type,
        content: []const u8,
    ) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType, InvalidKey })!void {
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

    pub fn serializeContentToWriterAssertsScalar(
        self: Value,
        writer: *std.Io.Writer,
        value_type: Type,
    ) std.Io.Writer.Error!void {
        assert(value_type.group() != .collection);

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
}
