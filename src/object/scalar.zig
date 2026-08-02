//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of scalars.

const std = @import("std");
const assert = std.debug.assert;

const Value = @import("../object.zig").Value;

pub const Void = @import("scalar/Void.zig");
pub const Integer = @import("scalar/Integer.zig");
pub const Decimal = @import("scalar/Decimal.zig");
pub const Flag = @import("scalar/Flag.zig");
pub const String = @import("scalar/String.zig");
pub const Point = @import("scalar/Point.zig");

/// Scalar value types used by List or Map as item.
/// Item contains information about the value type,
/// allowing the serializeToWriter method.
pub const Scalar = union(enum) {
    void: Void,
    integer: Integer,
    decimal: Decimal,
    flag: Flag,
    string: String,
    point: Point,

    pub fn initFromContent(
        allocator: std.mem.Allocator,
        value_type: Value.Type,
        content: []const u8,
    ) (std.mem.Allocator.Error || error{ MismatchType, InvalidFormat })!Scalar {
        if (value_type.group() == .collection) return error.MismatchType;

        return switch (value_type) {
            inline .void => |vt| @unionInit(
                Scalar,
                @tagName(vt),
                .fromContent(),
            ),
            inline .integer, .decimal, .flag => |vt| @unionInit(
                Scalar,
                @tagName(vt),
                try .fromContent(content),
            ),
            inline .string, .point => |vt| @unionInit(
                Scalar,
                @tagName(vt),
                try .initFromContent(allocator, content),
            ),
            // Handled earlier.
            .list, .map => unreachable,
        };
    }

    /// Deallocates value. Assuming value is initialized.
    pub fn deinit(self: Scalar, allocator: std.mem.Allocator) void {
        switch (self) {
            .void, .integer, .decimal, .flag => {},
            .string => self.string.deinit(allocator),
            .point => self.point.deinit(allocator),
        }
    }

    pub fn dupe(self: Scalar, allocator: std.mem.Allocator) std.mem.Allocator.Error!Scalar {
        return switch (self) {
            inline .string, .point => |_, t| @unionInit(
                Scalar,
                @tagName(t),
                try @field(self, @tagName(t)).dupe(allocator),
            ),
            inline else => |_, t| @unionInit(
                Scalar,
                @tagName(t),
                @field(self, @tagName(t)).dupe(),
            ),
        };
    }

    pub fn compare(self: Scalar, item: Scalar) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(item)) return false;

        return switch (self) {
            .void => true,
            .integer => |v| v.get() == item.integer.get(),
            .decimal => |v| v.isApproxEqualTo(item.decimal.get()),
            .flag => |v| v.get() == item.flag.get(),
            .string => |v| std.mem.eql(u8, v.get(), item.string.get()),
            .point => |v| v.isApproxEqualTo(item.point.get()),
        };
    }

    pub fn serializeToWriter(
        self: Scalar,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try self.type().serializeToWriter(writer);
        try self.serializeContentToWriter(writer);
    }

    pub fn serializeContentToWriter(
        self: Scalar,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        return switch (self) {
            inline else => |_, tag| {
                try @field(self, @tagName(tag)).serializeContentToWriter(writer);
            },
        };
    }

    pub fn print(self: Scalar, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return switch (self) {
            inline else => |_, tag| {
                try @field(self, @tagName(tag)).print(writer);
            },
        };
    }

    pub fn @"type"(self: Scalar) Value.Type {
        const self_int_enum: u3 = @intFromEnum(std.meta.activeTag(self));
        // This enum is always a subset with less quantity of Type,
        // so the conversion is always possible.
        return Value.Type.fromInt(self_int_enum) catch unreachable;
    }
};
