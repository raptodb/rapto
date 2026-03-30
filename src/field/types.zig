//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of type tags.

const std = @import("std");

// A Rapto's [serialized] (RS) is representation of [field_type][content].
// Content is the raw bytes of field, instead, the value
// is the representation of content with the return type of get().
//
// Consequently, serializeContentToWriter must write ONLY [content]
// and any function that accepts Content, must be accept also [field_type].
//
// RS is also used to represent a value to send to the client.

/// Splits serialized into [field_type:u8][content].
/// Instead, see `Types.serializeToWriter` to build [serialized].
pub fn splitSerialized(
    serialized: []const u8,
) error{ InvalidFormat, UnknownType }!struct { Types, []const u8 } {
    if (serialized.len == 0) return error.InvalidFormat;
    const field_type: Types = try .fromInt(serialized[0]);
    const content = if (serialized.len > 1) serialized[1..] else &.{};
    return .{ field_type, content };
}

/// Enumeration of all field types. The quantity of field types
/// must be equal or under 8: the field type is saved on 3 LSB
/// bits of tagged pointer.
pub const Types = enum(u3) {
    // scalar types
    void = 0,
    integer,
    decimal,
    flag,
    string,
    point,

    // collection types
    list,
    map,

    pub fn fromInt(int: anytype) error{UnknownType}!Types {
        return std.enums.fromInt(Types, int) orelse error.UnknownType;
    }

    /// Serializes field type and content to writer as [field_type][content].
    pub fn serializeToWriter(
        self: Types,
        writer: *std.Io.Writer,
        content: []const u8,
    ) error{WriteFailed}!void {
        try self.serializeTypeToWriter(writer);
        try writer.writeAll(content);
    }

    pub fn serializeTypeToWriter(self: Types, writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.writeByte(@intFromEnum(self));
    }
};

test "Types" {
    const allocator = std.testing.allocator;

    try std.testing.expect(try Types.fromInt(0) == .void);
    try std.testing.expect(try Types.fromInt(1) == .integer);
    try std.testing.expect(try Types.fromInt(2) == .decimal);
    try std.testing.expect(try Types.fromInt(3) == .flag);
    try std.testing.expect(try Types.fromInt(4) == .string);
    try std.testing.expect(try Types.fromInt(5) == .point);
    try std.testing.expect(try Types.fromInt(6) == .list);
    try std.testing.expect(try Types.fromInt(7) == .map);

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    try Types.serializeTypeToWriter(.void, &allocating.writer);
    try std.testing.expect(0 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Types.serializeTypeToWriter(.integer, &allocating.writer);
    try std.testing.expect(1 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Types.serializeTypeToWriter(.decimal, &allocating.writer);
    try std.testing.expect(2 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Types.serializeTypeToWriter(.flag, &allocating.writer);
    try std.testing.expect(3 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Types.serializeTypeToWriter(.string, &allocating.writer);
    try std.testing.expect(4 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Types.serializeTypeToWriter(.point, &allocating.writer);
    try std.testing.expect(5 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Types.serializeTypeToWriter(.list, &allocating.writer);
    try std.testing.expect(6 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Types.serializeTypeToWriter(.map, &allocating.writer);
    try std.testing.expect(7 == allocating.written()[0]);
    allocating.clearRetainingCapacity();
}
