//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of client's reply.

const std = @import("std");
const frames = @import("../frames.zig");
const value = @import("value.zig");
const assert = std.debug.assert;

const Pipeline = @import("../Pipeline.zig");

pub const List = struct {
    const Header = u32;

    pub const AccessError = Value.DeserializeError;
    pub const AccessAsError = AccessError || error{UnexpectedType};

    wrapped_iterator: frames.IteratorType(List.Header),
    len: u64,

    pub fn init(content: []const u8) error{InvalidFormat}!List {
        const iterator: frames.IteratorType(List.Header) = .init(content);
        return .{ .wrapped_iterator = iterator, .len = iterator.len() };
    }

    pub fn count(self: List) u64 {
        return self.len;
    }

    pub fn take(self: *List) AccessError!?Value {
        const serialized = self.wrapped_iterator.next() orelse return null;
        return try .deserialize(serialized);
    }

    pub fn takeAs(
        self: *List,
        comptime value_type: value.Type,
    ) AccessAsError!?Value.FieldType(value_type) {
        const next_value = try self.take() orelse return null;
        if (next_value.type() != value_type) return error.UnexpectedType;
        return @field(next_value, @tagName(value_type));
    }

    /// Retrieve scalar from index, assuming it is in bounds.
    pub fn peekAt(self: List, index: u32) AccessError!Value {
        const serialized = self.wrapped_iterator.at(index);
        return .deserialize(serialized);
    }

    /// Retrieve typed scalar from index, assuming it is in bounds.
    pub fn peekAtAs(
        self: List,
        index: u32,
        comptime value_type: value.Type,
    ) AccessAsError!Value.FieldType(value_type) {
        const value_at = try self.peekAt(index);
        if (value_at.type() != value_type) return error.UnexpectedType;
        return @field(value_at, @tagName(value_type));
    }

    pub fn skip(self: *List, n: u32) void {
        self.wrapped_iterator.skip(n);
    }

    pub fn format(self: List, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var iterator = self;
        try writer.print("list:{d}->[", .{iterator.len});
        var i: u64 = 0;
        while (iterator.take() catch return error.WriteFailed) |s| : (i += 1) {
            if (i != 0) try writer.writeByte(' ');
            try writer.print("{f}", .{s});
        }
        try writer.writeByte(']');
    }
};

pub const ErrorCode = enum(u8) {
    key_not_found = 0,
    invalid_key,
    invalid_format,
    missing_tokens,
    mismatch_type,
    unknown_type,
    math_overflow,
    range_overflow,
    unknown_command,
    locked,
    key_already_exists,

    unknown,

    pub fn fromInt(int: u8) ErrorCode {
        return std.enums.fromInt(ErrorCode, int) orelse .unknown;
    }

    pub fn serializeToWriter(self: ErrorCode, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeByte(@backingInt(self));
    }
};

pub const Value = union(enum) {
    pub const DeserializeError = error{ InvalidFormat, UnknownType };

    void,
    integer: value.Integer,
    decimal: value.Decimal,
    string: value.String,
    point: value.Point,
    @"error": ErrorCode,
    list: List,

    pub fn FieldType(comptime from_type: value.Type) type {
        return switch (from_type) {
            .void => void,
            .integer => value.Integer,
            .decimal => value.Decimal,
            .string => value.String,
            .point => value.Point,
            .@"error" => ErrorCode,
            .list => List,
        };
    }

    pub fn deserialize(serialized: []const u8) DeserializeError!Value {
        const value_type, const content = splitSerialized(serialized) catch
            return .void;
        const tag = value.Type.fromInt(value_type) orelse return error.UnknownType;

        var reader: std.Io.Reader = .fixed(content);

        switch (tag) {
            .void => return .void,
            .integer => {
                const integer = reader.takeInt(i64, .little) catch return error.InvalidFormat;
                return .{ .integer = integer };
            },
            .decimal => {
                const bytes = reader.takeArray(@sizeOf(f64)) catch return error.InvalidFormat;
                return .{ .decimal = std.mem.bytesToValue(f64, bytes) };
            },
            .string => return .{ .string = content },
            .point => {
                if (content.len != @sizeOf(f64) * 3) return error.InvalidFormat;
                return .{ .point = std.mem.bytesToValue(value.Point, content) };
            },
            .@"error" => {
                const tag_int = reader.takeByte() catch return error.InvalidFormat;
                return .{ .@"error" = .fromInt(tag_int) };
            },
            .list => return .{ .list = try .init(content) },
        }
    }

    pub fn @"type"(self: Value) ?value.Type {
        return .fromTypeName(@tagName(std.meta.activeTag(self)));
    }

    pub fn maybeError(self: Value, err: ErrorCode) bool {
        return self == .@"error" and self.@"error" == err;
    }

    pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self == .list) return self.list.format(writer);

        try writer.print("{t}", .{self});
        switch (self) {
            .void => {},
            inline else => {
                try writer.writeByte('(');
                switch (self) {
                    inline .integer, .decimal => |v| try writer.print("{d}", .{v}),
                    .string => |s| try writer.writeAll(s),
                    .point => |p| try writer.print("x={d} y={d} z={d}", .{ p.x, p.y, p.z }),
                    .@"error" => |e| try writer.writeAll(@tagName(e)),
                    // Handled earlier.
                    .list, .void => unreachable,
                }
                try writer.writeAll(")");
            },
            // Handled earlier.
            .list => unreachable,
        }
    }
};

test "scalar serialize and deserialize" {
    const cases = [_]value.Scalar{
        .void,
        .{ .integer = 100 },
        .{ .decimal = 3.14 },
        .{ .string = "hello" },
        .{ .point = .{ .x = 1, .y = 2, .z = 3 } },
    };

    for (cases) |scalar| {
        var buf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try scalar.serializeToWriter(&w);

        const deserialized: Value = try .deserialize(w.buffered());
        switch (scalar) {
            .void => try std.testing.expect(deserialized == .void),
            .integer => |v| try std.testing.expectEqual(v, deserialized.integer),
            .decimal => |v| try std.testing.expectEqual(v, deserialized.decimal),
            .string => |v| try std.testing.expectEqualStrings(v, deserialized.string),
            .point => |v| {
                try std.testing.expectEqual(v.x, deserialized.point.x);
                try std.testing.expectEqual(v.y, deserialized.point.y);
                try std.testing.expectEqual(v.z, deserialized.point.z);
            },
        }
    }
}

pub const Iterator = struct {
    pub const AccessError = Value.DeserializeError;
    pub const AccessAsError = AccessError || error{UnexpectedType};

    wrapped_iterator: frames.IteratorType(Pipeline.FrameHeader),
    /// Likely to be accessed directly.
    len: u32,

    pub fn init(pipeline: []const u8) Iterator {
        const iterator: frames.IteratorType(Pipeline.FrameHeader) = .init(pipeline);
        return .{ .wrapped_iterator = iterator, .len = iterator.len() };
    }

    pub fn buffered(self: Iterator) []const u8 {
        return self.wrapped_iterator.frames;
    }

    pub fn take(self: *Iterator) AccessError!?Value {
        const serialized = self.wrapped_iterator.next() orelse return null;
        return try .deserialize(serialized);
    }

    pub fn takeAs(
        self: *Iterator,
        comptime value_type: value.Type,
    ) AccessAsError!?Value.FieldType(value_type) {
        const next_value = try self.take() orelse return null;
        if (next_value.type() != value_type) return error.UnexpectedType;
        return @field(next_value, @tagName(value_type));
    }

    /// Retrieve scalar from index, assuming it is in bounds.
    pub fn peekAt(self: Iterator, index: u32) AccessError!Value {
        const serialized = self.wrapped_iterator.at(index);
        return .deserialize(serialized);
    }

    /// Retrieve typed scalar from index, assuming it is in bounds.
    pub fn peekAtAs(
        self: Iterator,
        index: u32,
        comptime value_type: value.Type,
    ) AccessAsError!Value.FieldType(value_type) {
        const value_at = try self.peekAt(index);
        if (value_at.type() != value_type) return error.UnexpectedType;
        return @field(value_at, @tagName(value_type));
    }
};

fn splitSerialized(serialized: []const u8) error{InvalidFormat}!struct { u8, []const u8 } {
    if (serialized.len < @sizeOf(u8)) return error.InvalidFormat;
    const value_type: u8 = serialized[0];
    const content = if (serialized.len > 1) serialized[1..] else &.{};
    return .{ value_type, content };
}
