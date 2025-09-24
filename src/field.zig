//! BSD 3-Clause License
//!
//! Copyright (c) raptodb
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
//! It contains the implementation of fields.

const std = @import("std");

/// Enum of field type identifier.
pub const Type = enum(u8) {
    integer,
    decimal,
    string,

    /// Returns type from argument of query.
    pub fn fromStringQuery(string: []const u8) Type {
        // check if is string if
        // it is encapsulated with ""
        return if (string[0] == '"' and string[string.len - 1] == '"')
            // is string if it is encapsulated with ""
            .string
        else if (std.mem.lastIndexOfScalar(u8, string, '.') != null)
            // is decimal if contains a dot
            .decimal
        else
            // probably a integer
            .integer;
    }

    /// Evaluates type from integer. If integer has not
    /// correspondences with enum, returns error.UnsupportedType.
    pub inline fn fromInt(int: u8) error{UnsupportedType}!Type {
        return std.enums.fromInt(Type, int) orelse error.UnsupportedType;
    }
};

/// Field of signed 64-bit integer.
pub const Integer = i64;

/// Field of Double-precision floating-point.
pub const Decimal = f64;

/// Field of byte-array rappresentation.
pub const String = struct {
    const Self = @This();

    /// The pointer to byte array.
    /// Limit size: 2^64-1.
    ptr: [*:0]u8,

    /// Initializes string field with string.
    /// String must have a length less than 2^64-1.
    pub inline fn init(string: []u8) error{TypeOverflow}!Self {
        return if (string.len < std.math.maxInt(u64)) .{ .ptr = @ptrCast(string) } else error.TypeOverflow;
    }

    /// Serialization method for field.String. Writes from IO writer.
    pub fn serialize(self: Self, writer: *std.Io.Writer) error{WriteFailed}!void {
        const ptr_len = self.len();
        try writer.writeInt(u64, ptr_len, comptime .little);
        try writer.writeAll(self.ptr[0..ptr_len]);
    }

    /// Deserialization method for field.String. Reads from IO reader.
    pub fn deserialize(reader: *std.Io.Reader, allocator: std.mem.Allocator) error{ OutOfMemory, TypeOverflow, EndOfStream, ReadFailed }!Self {
        const fieldlen = try reader.takeInt(u64, comptime .little);

        const str = try allocator.allocSentinel(u8, fieldlen, 0);
        errdefer allocator.free(str);

        try reader.readSliceAll(str);
        return .init(str);
    }

    /// Copies string to current field string.
    /// If length is different to old field string make a realloc.
    /// String must have a length less than 2^64-1.
    pub fn set(self: *Self, allocator: std.mem.Allocator, string: []const u8) error{ OutOfMemory, TypeOverflow }!void {
        const ptr_len = self.len();
        if (ptr_len != string.len) if (string.len < std.math.maxInt(u64)) {
            const slice = try allocator.realloc(self.ptr[0 .. ptr_len + 1], string.len + 1);
            self.ptr = @ptrCast(slice.ptr);
            self.ptr[string.len] = 0;
        }
        // string overflows for length
        else return error.TypeOverflow;

        @memcpy(self.ptr[0..string.len], string);
    }

    /// Returns string field as mutable array.
    pub inline fn get(self: Self) []u8 {
        return self.ptr[0..self.len()];
    }

    /// Returns length of string field.
    pub inline fn len(self: Self) u64 {
        return std.mem.len(self.ptr);
    }

    /// Deallocates string.
    pub inline fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.ptr[0 .. self.len() + 1]);
    }
};

// module tested in `object.zig`

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}
