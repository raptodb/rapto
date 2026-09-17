//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of client's values.

const std = @import("std");
const frames = @import("../frames.zig");
const assert = std.debug.assert;

const Pipeline = @import("../Pipeline.zig");

pub const Void = void;
pub const Integer = i64;
pub const Decimal = f64;
pub const String = []const u8;
pub const Point = struct { x: f64, y: f64, z: f64 };
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

pub const Type = enum(u8) {
    void = 0,
    integer,
    decimal,
    flag,
    string,
    point,
    list,

    @"error" = std.math.maxInt(u8),

    pub fn fromInt(int: u8) ?Type {
        return std.enums.fromInt(Type, int);
    }

    pub fn fromTypeName(name: []const u8) ?Type {
        return std.meta.stringToEnum(Type, name);
    }

    pub fn group(self: Type) enum { Value, collection } {
        return switch (self) {
            .void, .integer, .decimal, .flag, .string, .point, .@"error" => .Value,
            .list => .collection,
        };
    }

    pub fn serializeToWriter(self: Type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
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

    pub fn serializeToWriter(
        self: Scalar,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const value_type = Type.fromTypeName(@tagName(self)) orelse unreachable;
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
        }
    }
};
