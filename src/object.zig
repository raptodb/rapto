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
//! It contains the implementation of object.

const std = @import("std");

const signal = @import("signal.zig");

pub const FieldType = enum(u8) {
    integer,
    decimal,
    string,
};

/// Represents database object with key, value and metadata.
pub const Object = struct {
    const Self = @This();

    /// The key used to identify the object.
    /// Limit size: 2^8 (because len is u8)
    key: []u8 = undefined,

    /// Field of object storing the actual data.
    /// String is used as byte array for serialization
    /// of more complex contents.
    /// Decimal and integer fields are used for
    /// fast math operations.
    ///
    field: union(FieldType) {
        /// Integer value
        integer: i64,

        /// Decimal value
        decimal: f64,

        /// String is byte array data.
        /// Limit size: 2^32 = 4GiB
        string: []u8,
    } = undefined,

    /// Stores metadata information associated with a key.
    /// This includes usage metrics.
    metadata: struct {
        /// Count of read, write operations.
        /// Also called FREQ.
        access_times: i64 = 1,

        /// Last access in timestamp (us).
        /// Useful for storage prefetching with LRU-policy.
        /// Also called LAST.
        last_access: i64,

        /// Updates the metadata when the object is accessed.
        /// This increments the access counter and refreshes the last access timestamp.
        pub inline fn update(self: *@This()) void {
            // The saturation addition prevents counter overflow
            // and improves performance.
            self.access_times +|= 1;
            self.last_access = std.time.microTimestamp();
        }
    } = undefined,

    /// Initizializes object with key-value and metadata.
    /// If object is already set, insert self parameter.
    pub const SetError = error{TypeOverflow} || signal.SignalError;
    pub fn set(allocator: std.mem.Allocator, comptime field_type: FieldType, noalias key: []const u8, noalias value: anytype) SetError!Self {
        // check key length for a limit of 2^8
        if (key.len > std.math.maxInt(u8)) {
            @branchHint(.unlikely);
            return error.TypeOverflow;
        }

        var obj = Object{};

        obj.key = try allocator.dupe(u8, key);
        errdefer allocator.free(obj.key);

        obj.metadata.update();
        obj.field = switch (field_type) {
            .integer => .{ .integer = value },
            .decimal => .{ .decimal = value },
            .string => .{ .string = try allocator.dupe(u8, value) },
        };

        return obj;
    }

    /// Return struct from serialized data.
    pub const DeserializeError = error{ EndOfStream, UnsupportedType } || signal.SignalError;
    pub noinline fn deserialize(allocator: std.mem.Allocator, noalias data: []const u8) DeserializeError!Self {
        // init io reader
        var deserialized = std.io.fixedBufferStream(data);
        const reader = deserialized.reader();

        var obj = Object{};

        const keylen = try reader.readInt(u8, comptime .little);
        obj.key = try allocator.alloc(u8, keylen);
        errdefer allocator.free(obj.key);

        _ = try reader.readAll(obj.key);

        obj.metadata = .{
            .access_times = try reader.readInt(i64, comptime .little),
            .last_access = try reader.readInt(i64, comptime .little),
        };

        // select from field type
        obj.field = switch (try reader.readByte()) {
            0 => .{ .integer = try reader.readInt(i64, comptime .little) },
            1 => blk: {
                // convert 8 bytes to 64bit floating-point type
                var buf: [8]u8 = undefined;
                _ = try reader.readAll(&buf);

                break :blk .{ .decimal = @bitCast(buf) };
            },
            2 => blk: {
                const fieldlen = try reader.readInt(u64, comptime .little);

                // for string: get length, then read string
                const str = try allocator.alloc(u8, fieldlen);
                errdefer allocator.free(str);

                _ = try reader.readAll(str);

                break :blk .{ .string = str };
            },
            else => {
                @branchHint(.unlikely);
                return error.UnsupportedType;
            },
        };

        return obj;
    }

    /// Returns serialized object to byte array.
    pub noinline fn serialize(self: *Self, allocator: std.mem.Allocator) signal.SignalError![]u8 {
        // get len of serialized object
        const size = self.getSize();

        // init preallocated buffer
        const buf: []u8 = try allocator.alloc(u8, size);
        // after alloc, it never fails

        // init io writer
        var serialized = std.io.fixedBufferStream(buf);
        const writer = serialized.writer();

        // write the fields
        writer.writeInt(u8, @intCast(self.key.len), comptime .little) catch unreachable;
        writer.writeAll(self.key) catch unreachable;
        writer.writeInt(i64, self.metadata.access_times, comptime .little) catch unreachable;
        writer.writeInt(i64, self.metadata.last_access, comptime .little) catch unreachable;
        writer.writeInt(u8, @intFromEnum(self.field), comptime .little) catch unreachable;

        // write value of object.
        // if value is string, add size
        switch (self.field) {
            .integer => |value| writer.writeInt(i64, value, comptime .little) catch unreachable,
            .decimal => |value| writer.writeAll(std.mem.asBytes(&value)) catch unreachable,
            .string => |value| {
                writer.writeInt(u64, value.len, comptime .little) catch unreachable;
                writer.writeAll(value) catch unreachable;
            },
        }

        return serialized.getWritten();
    }

    /// Returns size of serialized object
    pub fn getSize(self: *Self) u64 {
        // field size is present if field type is string
        const fieldsize: u64 = if (self.field == .string) 8 else 0;
        const fieldlen = switch (self.field) {
            .integer, .decimal => 8,
            .string => |v| v.len,
        };

        // size is composed of key size (1 byte)
        // + key length + metadata (16 bytes) + field type (1 byte) +
        // field size (8 bytes if is string, else 0) + field length
        const size: u64 = 1 + self.key.len + 16 + 1 + fieldsize + fieldlen;

        return size;
    }

    /// Frees all allocated memory associated with this object
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        // if field is string, deallocates it
        if (self.field == .string)
            allocator.free(self.field.string);
        // deallocated key
        allocator.free(self.key);

        self.* = undefined;
    }
};
