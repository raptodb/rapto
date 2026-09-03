//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of client's query/reply values.

const std = @import("std");
const frames = @import("../frames.zig");
const assert = std.debug.assert;

const Pipeline = @import("../Pipeline.zig");

pub const ErrorCode = enum(u8) {
    key_not_found = 0,
    invalid_key,
    invalid_format,
    missing_tokens,
    mismatch_type,
    unknown_type,
    math_overflow,
    range_overflow,
    map_key_not_found,
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

pub const Flag = enum(u64) {
    false = 0,
    true = 1,

    null,
    @"error",
    pending,

    unknown,

    pub fn fromInt(int: u64) Flag {
        return std.enums.fromInt(Flag, int) orelse .unknown;
    }
};

pub const ListIterator = struct {
    pub const Header = u32;

    wrapped_iterator: frames.IteratorType(ListIterator.Header),
    len: u64,

    pub fn init(content: []const u8) error{InvalidFormat}!ListIterator {
        var reader: std.Io.Reader = .fixed(content);
        const len = reader.takeInt(u64, .little) catch return error.InvalidFormat;
        return .{ .wrapped_iterator = .init(reader.buffered()), .len = len };
    }

    pub fn count(self: ListIterator) u64 {
        return self.len;
    }

    pub fn next(
        self: *ListIterator,
    ) error{ MismatchType, InvalidFormat, UnknownType }!?ReturnValue {
        const serialized = self.wrapped_iterator.next() orelse return null;
        return try .deserialize(serialized);
    }

    pub fn format(self: ListIterator, writer: *std.Io.Writer) std.Io.Writer.Error!void {
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

pub const MapIterator = struct {
    pub const Header = u32;

    wrapped_iterator: frames.IteratorType(Header),
    len: u64,

    pub const Entry = struct {
        key: []const u8,
        value: ReturnValue,
    };

    pub fn init(content: []const u8) error{InvalidFormat}!MapIterator {
        var reader: std.Io.Reader = .fixed(content);
        const len = reader.takeInt(u64, .little) catch return error.InvalidFormat;
        return .{ .wrapped_iterator = .init(reader.buffered()), .len = len };
    }

    pub fn count(self: MapIterator) u64 {
        return self.len;
    }

    pub fn next(self: *MapIterator) error{ MismatchType, InvalidFormat, UnknownType }!?Entry {
        const key = self.wrapped_iterator.next() orelse return null;
        const serialized = self.wrapped_iterator.next() orelse return error.InvalidFormat;
        return .{ .key = key, .value = try .deserialize(serialized) };
    }

    pub fn format(self: MapIterator, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var iterator = self;
        try writer.print("map:{d}->{{", .{iterator.len});
        var i: u64 = 0;
        while (iterator.next() catch return error.WriteFailed) |e| : (i += 1) {
            if (i != 0) try writer.writeByte(' ');
            try writer.print("{s}={f}", .{ e.key, e.value });
        }
        try writer.writeByte('}');
    }
};

pub const Tag = enum(u8) {
    void = 0,
    integer,
    decimal,
    flag,
    string,
    point,
    list,
    map,

    @"error" = std.math.maxInt(u8),

    pub fn fromInt(int: u8) error{UnknownType}!Tag {
        return std.enums.fromInt(Tag, int) orelse error.UnknownType;
    }

    pub fn fromTagName(name: []const u8) error{UnknownType}!Tag {
        return std.meta.stringToEnum(Tag, name) orelse error.UnknownType;
    }

    pub fn group(self: Tag) enum { scalar, collection } {
        return switch (self) {
            .void, .integer, .decimal, .flag, .string, .point, .@"error" => .scalar,
            .list, .map => .collection,
        };
    }

    pub fn serializeToWriter(self: Tag, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeByte(@intFromEnum(self));
    }
};

pub const Scalar = union(enum) {
    void,
    integer: i64,
    decimal: f64,
    flag: Flag,
    string: []const u8,
    point: struct { x: f64, y: f64, z: f64 },

    @"error": ErrorCode,
    none,

    pub fn deserialize(
        serialized: []const u8,
    ) error{ MismatchType, InvalidFormat, UnknownType }!Scalar {
        const value_type, const content = splitSerialized(serialized) catch return .none;

        const tag: Tag = try .fromInt(value_type);
        if (tag.group() != .scalar) return error.MismatchType;

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
            // Handled earlier.
            else => unreachable,
        }
    }

    pub fn serializeToWriter(
        self: Scalar,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (self == .none) return;

        const value_type = Tag.fromTagName(@tagName(self)) catch unreachable;
        try value_type.serializeToWriter(writer);
        switch (self) {
            .void => {},
            .integer => |int| try writer.writeInt(i64, int, .little),
            .decimal => |d| try writer.writeInt(u64, @bitCast(d), .little),
            .flag => |f| try writer.writeInt(u64, @intFromEnum(f), .little),
            .string => |s| try writer.writeAll(s),
            .point => |p| {
                try writer.writeInt(u64, @bitCast(p.x), .little);
                try writer.writeInt(u64, @bitCast(p.y), .little);
                try writer.writeInt(u64, @bitCast(p.z), .little);
            },
            .@"error" => |e| try e.serializeToWriter(writer),
            // Handled earlier.
            .none => unreachable,
        }
    }

    pub fn format(self: Scalar, writer: *std.Io.Writer) std.Io.Writer.Error!void {
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
                    .void, .none => unreachable,
                }
                try writer.writeAll(")");
            },
        }
    }
};

pub const ReturnValue = union(enum) {
    pub const DeserializeError = error{ MismatchType, InvalidFormat, UnknownType };

    scalar: Scalar,
    list: ListIterator,
    map: MapIterator,

    pub fn deserialize(serialized: []const u8) DeserializeError!ReturnValue {
        const value_type, const content = splitSerialized(serialized) catch
            return .{ .scalar = .none };
        const tag: Tag = try .fromInt(value_type);

        return switch (tag.group()) {
            .scalar => .{ .scalar = try .deserialize(serialized) },
            .collection => switch (tag) {
                .list => .{ .list = try .init(content) },
                .map => .{ .map = try .init(content) },
                // Handled earlier by scalar label.
                else => unreachable,
            },
        };
    }

    pub fn @"type"(self: ReturnValue) Tag {
        return switch (self) {
            .list => .list,
            .map => .map,
            .scalar => |scalar| return switch (scalar) {
                inline else => |_, s| Tag.fromTagName(@tagName(s)) catch unreachable,
            },
        };
    }

    pub fn maybeError(self: ReturnValue, err: ErrorCode) bool {
        return self.hasError() and self.scalar.@"error" == err;
    }

    pub fn hasError(self: ReturnValue) bool {
        return self == .scalar and self.scalar == .@"error";
    }

    pub fn format(self: ReturnValue, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .scalar => |s| try s.format(writer),
            .list => |list| try list.format(writer),
            .map => |map| try map.format(writer),
        }
    }
};

pub const ReturnValues = struct {
    pub const DeserializeError = ReturnValue.DeserializeError;

    wrapped_iterator: frames.IteratorType(Pipeline.FrameHeader),
    /// Likely to be accessed directly.
    len: u32,

    pub fn init(pipeline: []const u8) ReturnValues {
        const iterator: frames.IteratorType(Pipeline.FrameHeader) = .init(pipeline);
        return .{ .wrapped_iterator = iterator, .len = iterator.len() };
    }

    pub fn buffered(self: ReturnValues) []const u8 {
        return self.wrapped_iterator.frames;
    }

    pub fn next(self: *ReturnValues) DeserializeError!?ReturnValue {
        const serialized = self.wrapped_iterator.next() orelse return null;
        return try .deserialize(serialized);
    }

    /// Retrieve ReturnValue from index, assuming it is in bounds.
    pub fn at(self: ReturnValues, index: u32) DeserializeError!ReturnValue {
        assert(index < self.len);
        var iterator = self.wrapped_iterator;
        iterator.skip(index -| 1);
        const serialized = iterator.next() orelse unreachable;
        return .deserialize(serialized);
    }
};

fn splitSerialized(serialized: []const u8) error{InvalidFormat}!struct { u8, []const u8 } {
    if (serialized.len < @sizeOf(u8)) return error.InvalidFormat;
    const value_type: u8 = serialized[0];
    const content = if (serialized.len > 1) serialized[1..] else &.{};
    return .{ value_type, content };
}
