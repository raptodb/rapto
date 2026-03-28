//! BSD 3-Clause License
//!
//! Copyright (c) Raptodb
//! Copyright (c) Andrea Vaccaro
//! All rights reserved.
//!
//! Redistribution and use in source and binary forms, with or without
//! modification, are permitted provided that the following conditions are met:
//!
//! 1. Redistributions of source code must retain the above copyright notice, this
//!    list of conditions and the following disclaimer.
//!
//! 2. Redistributions in binary form must reproduce the above copyright notice,
//!    this list of conditions and the following disclaimer in the documentation
//!    and/or other materials provided with the distribution.
//!
//! 3. Neither the name of the copyright holder nor the names of its
//!    contributors may be used to endorse or promote products derived from
//!    this software without specific prior written permission.
//!
//! THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//! AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//! IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//! DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
//! FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//! DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//! SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//! CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//! OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//! OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//!
//! This file is part of "Rapto".
//! It contains the implementation of scalar fields.

const std = @import("std");

const Types = @import("types.zig").Types;

pub const Void = @import("scalar/void.zig").Void;
pub const Integer = @import("scalar/integer.zig").Integer;
pub const Decimal = @import("scalar/decimal.zig").Decimal;
pub const Flag = @import("scalar/flag.zig").Flag;
pub const String = @import("scalar/string.zig").String;
pub const Point = @import("scalar/point.zig").Point;

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
    ) error{ OutOfMemory, MismatchType, InvalidFormat }!ScalarItem {
        return switch (field_type) {
            .void => .{ .void = .init() },
            .integer => .{ .integer = try .init(content) },
            .decimal => .{ .decimal = try .init(content) },
            .flag => .{ .flag = try .init(content) },
            .string => .{ .string = try .init(allocator, content) },
            .point => .{ .point = try .init(allocator, content) },

            // when field type is not a scalar
            else => {
                @branchHint(.unlikely);
                return error.MismatchType;
            },
        };
    }

    pub fn serializeToWriter(
        self: ScalarItem,
        writer: *std.Io.Writer,
    ) error{WriteFailed}!void {
        try self.type().serializeTypeToWriter(writer);
        try self.serializeContentToWriter(writer);
    }

    pub fn serializeContentToWriter(
        self: ScalarItem,
        writer: *std.Io.Writer,
    ) error{WriteFailed}!void {
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
