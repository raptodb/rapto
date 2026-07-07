//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of scalars.

const std = @import("std");
const value = @import("../value.zig");

pub const Void = @import("scalar/Void.zig");
pub const Integer = @import("scalar/Integer.zig");
pub const Decimal = @import("scalar/Decimal.zig");
pub const Flag = @import("scalar/Flag.zig");
pub const String = @import("scalar/String.zig");
pub const Point = @import("scalar/Point.zig");

/// Scalar value types used by List or Map as item.
/// Item contains information about the value type,
/// allowing the serializeToWriter method.
pub const ScalarValue = union(enum) {
    void: Void,
    integer: Integer,
    decimal: Decimal,
    flag: Flag,
    string: String,
    point: Point,

    pub fn from(value_type: value.Type, v: anytype) ScalarValue {
        switch (value_type) {
            inline else => |tag| @unionInit(
                ScalarValue,
                @tagName(tag),
                v,
            ),
        }
    }

    pub fn initFromContent(
        allocator: std.mem.Allocator,
        value_type: value.Type,
        content: []const u8,
    ) (std.mem.Allocator.Error || error{ MismatchType, InvalidFormat })!ScalarValue {
        return switch (value_type) {
            .void => .{ .void = .fromContent() },
            .integer => .{ .integer = try .fromContent(content) },
            .decimal => .{ .decimal = try .fromContent(content) },
            .flag => .{ .flag = try .fromContent(content) },
            .string => .{ .string = try .initFromContent(allocator, content) },
            .point => .{ .point = try .initFromContent(allocator, content) },

            // Collection type is not supported.
            else => {
                @branchHint(.unlikely);
                return error.MismatchType;
            },
        };
    }

    /// Deallocates value. Assuming value is initialized.
    pub fn deinit(self: ScalarValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .void, .integer, .decimal, .flag => {},
            .string => self.string.deinit(allocator),
            .point => self.point.deinit(allocator),
        }
    }

    pub fn dupe(self: ScalarValue, allocator: std.mem.Allocator) std.mem.Allocator.Error!ScalarValue {
        return switch (self) {
            inline .string, .point => |_, t| @unionInit(
                ScalarValue,
                @tagName(t),
                try @field(self, @tagName(t)).dupe(allocator),
            ),
            inline else => |_, t| @unionInit(
                ScalarValue,
                @tagName(t),
                @field(self, @tagName(t)).dupe(),
            ),
        };
    }

    pub fn compare(self: ScalarValue, item: ScalarValue) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(item)) return false;

        return switch (self) {
            .void => true,
            .integer => |v| v.get() == item.integer.get(),
            .decimal => |v| v.isApproxEqualTo(item.decimal.get()),
            .flag => |v| v.get() == item.flag.get(),
            .string => |v| std.mem.eql(u8, v.get(), item.string.get()),
            .point => |v| std.meta.eql(v.get(), item.point.get()),
        };
    }

    pub fn serializeToWriter(
        self: ScalarValue,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try self.type().serializeToWriter(writer);
        try self.serializeContentToWriter(writer);
    }

    pub fn serializeContentToWriter(
        self: ScalarValue,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        return switch (self) {
            .void => self.void.serializeContentToWriter(writer),
            inline else => |_, tag| {
                try @field(self, @tagName(tag)).serializeContentToWriter(writer);
            },
        };
    }

    pub fn @"type"(self: ScalarValue) value.Type {
        const self_int_enum: u3 = @intFromEnum(std.meta.activeTag(self));
        // This enum is always a subset with less quantity of Type,
        // so the conversion is always possible.
        return value.Type.fromInt(self_int_enum) catch unreachable;
    }
};
