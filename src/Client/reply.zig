//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of client's reply.

const std = @import("std");
const frames = @import("../frames.zig");
const value = @import("value.zig");

const Pipeline = @import("../Pipeline.zig");

pub const List = struct {
    const Header = u32;

    wrapped_iterator: frames.IteratorType(List.Header),
    len: u64,

    pub fn init(content: []const u8) error{InvalidFormat}!List {
        var reader: std.Io.Reader = .fixed(content);
        const len = reader.takeInt(u64, .little) catch return error.InvalidFormat;
        return .{ .wrapped_iterator = .init(reader.buffered()), .len = len };
    }

    pub fn count(self: List) u64 {
        return self.len;
    }

    pub fn next(self: *List) Value.DeserializeError!?Value {
        const serialized = self.wrapped_iterator.next() orelse return null;
        return try .deserialize(serialized);
    }

    /// Retrieve scalar from index, assuming it is in bounds.
    pub fn at(self: List, index: u32) Value.DeserializeError!Value {
        const serialized = self.wrapped_iterator.at(index);
        return .deserialize(serialized);
    }

    pub fn skip(self: *List, n: u64) void {
        self.wrapped_iterator.skip(n);
    }

    pub fn format(self: List, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var iterator = self;
        try writer.print("list:{d}->[", .{iterator.len});
        var i: u64 = 0;
        while (iterator.next() catch return error.WriteFailed) |s| : (i += 1) {
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

    unknown,

    pub fn fromInt(int: u8) ErrorCode {
        return std.enums.fromInt(ErrorCode, int) orelse .unknown;
    }

    pub fn serializeToWriter(self: ErrorCode, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeByte(@intFromEnum(self));
    }
};

pub const Value = union(enum) {
    pub const DeserializeError = error{ MismatchType, InvalidFormat, UnknownType };

    void,
    integer: value.Integer,
    decimal: value.Decimal,
    flag: value.Flag,
    string: value.String,
    point: value.Point,
    @"error": ErrorCode,
    list: value.List,
    none,

    pub fn deserialize(serialized: []const u8) DeserializeError!Value {
        const value_type, const content = splitSerialized(serialized) catch
            return .none;
        const tag: value.Type = try .fromInt(value_type);

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
            .flag => {
                const tag_int = reader.takeInt(u64, .little) catch return error.InvalidFormat;
                return .{ .flag = .fromInt(tag_int) };
            },
            .string => return .{ .string = content },
            .point => {
                if (content.len != @sizeOf(f64) * 3) return error.InvalidFormat;
                const x_bytes = reader.takeArray(@sizeOf(f64)) catch return error.InvalidFormat;
                const y_bytes = reader.takeArray(@sizeOf(f64)) catch return error.InvalidFormat;
                const z_bytes = reader.takeArray(@sizeOf(f64)) catch return error.InvalidFormat;
                return .{ .point = .{
                    .x = std.mem.bytesToValue(f64, x_bytes),
                    .y = std.mem.bytesToValue(f64, y_bytes),
                    .z = std.mem.bytesToValue(f64, z_bytes),
                } };
            },
            .@"error" => {
                const tag_int = reader.takeByte() catch return error.InvalidFormat;
                return .{ .@"error" = .fromInt(tag_int) };
            },
            .list => return .{ .list = try .init(content) },
            // Handled earlier.
            else => unreachable,
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
            .void, .none => {},
            inline else => {
                try writer.writeByte('(');
                switch (self) {
                    inline .integer, .decimal => |v| try writer.print("{d}", .{v}),
                    .flag => |f| try writer.print("{t}", .{f}),
                    .string => |s| try writer.writeAll(s),
                    .point => |p| try writer.print("x={d} y={d} z={d}", .{ p.x, p.y, p.z }),
                    .@"error" => |e| try writer.writeAll(@tagName(e)),
                    // Handled earlier.
                    .list, .void, .none => unreachable,
                }
                try writer.writeAll(")");
            },
            // Handled earlier.
            .list => unreachable,
        }
    }
};

pub const Iterator = struct {
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

    pub fn next(self: *Iterator) Value.DeserializeError!?Value {
        const serialized = self.wrapped_iterator.next() orelse return null;
        return try .deserialize(serialized);
    }

    /// Retrieve value from index, assuming it is in bounds.
    pub fn at(self: Iterator, index: u32) Value.DeserializeError!Value {
        const serialized = self.wrapped_iterator.at(index);
        return .deserialize(serialized);
    }
};

fn splitSerialized(serialized: []const u8) error{InvalidFormat}!struct { u8, []const u8 } {
    if (serialized.len < @sizeOf(u8)) return error.InvalidFormat;
    const value_type: u8 = serialized[0];
    const content = if (serialized.len > 1) serialized[1..] else &.{};
    return .{ value_type, content };
}
