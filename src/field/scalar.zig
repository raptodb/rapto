//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of scalar fields.

const std = @import("std");

const Types = @import("../field.zig").Types;

pub const Void = @import("scalar/Void.zig");
pub const Integer = @import("scalar/Integer.zig");
pub const Decimal = @import("scalar/Decimal.zig");
pub const Flag = @import("scalar/Flag.zig");
pub const String = @import("scalar/String.zig");
pub const Point = @import("scalar/Point.zig");

/// Scalar field types used by List or Map as item.
pub const ScalarItem = union(enum) {
    void: Void,
    integer: Integer,
    decimal: Decimal,
    flag: Flag,
    string: String,
    point: Point,

    pub fn fromContent(
        allocator: std.mem.Allocator,
        field_type: Types,
        content: []const u8,
    ) (std.mem.Allocator.Error || error{ MismatchType, InvalidFormat })!ScalarItem {
        return switch (field_type) {
            .void => .{ .void = .initFromContent() },
            .integer => .{ .integer = try .initFromContent(content) },
            .decimal => .{ .decimal = try .initFromContent(content) },
            .flag => .{ .flag = try .initFromContent(content) },
            .string => .{ .string = try .initFromContent(allocator, content) },
            .point => .{ .point = try .initFromContent(allocator, content) },

            // Collection type is not supported.
            else => {
                @branchHint(.unlikely);
                return error.MismatchType;
            },
        };
    }

    pub fn compare(self: ScalarItem, item: ScalarItem) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(item)) return false;

        return switch (self) {
            .void => true,
            .integer => |value| value.get() == item.integer.get(),
            .decimal => |value| value.isApproxEqualTo(item.decimal.get()),
            .flag => |value| value.get() == item.flag.get(),
            .string => |value| std.mem.eql(u8, value.get(), item.string.get()),
            .point => |value| std.meta.eql(value.get(), item.point.get()),
        };
    }

    pub fn serializeToWriter(
        self: ScalarItem,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try self.type().serializeToWriter(writer);
        try self.serializeContentToWriter(writer);
    }

    pub fn serializeContentToWriter(
        self: ScalarItem,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        return switch (self) {
            .void => self.void.serializeContentToWriter(writer),
            .integer => self.integer.serializeContentToWriter(writer),
            .decimal => self.decimal.serializeContentToWriter(writer),
            .flag => self.flag.serializeContentToWriter(writer),
            .string => self.string.serializeContentToWriter(writer),
            .point => self.point.serializeContentToWriter(writer),
        };
    }

    pub fn @"type"(self: ScalarItem) Types {
        const self_int_enum: u3 = @intFromEnum(std.meta.activeTag(self));
        // this enum is always a subset with less quantity of Types,
        // so the conversion is always possible
        return Types.fromInt(self_int_enum) catch unreachable;
    }

    /// Deallocated field. Assumes the field is initializated.
    pub fn deinit(self: ScalarItem, allocator: std.mem.Allocator) void {
        switch (self) {
            .void, .integer, .decimal, .flag => {},
            .string => self.string.deinit(allocator),
            .point => self.point.deinit(allocator),
        }
    }
};
