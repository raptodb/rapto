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
const field = @import("field.zig");

/// Represents database object with key, value and metadata.
/// Optimized for L1/L2 cache hit. Static size of 32 byte to
/// help CPU for cache line storing.
pub const Object = struct {
    const Self = @This();

    /// The length of key.
    len: u32 = 0,
    /// Pointer to key.
    /// Limit of size of 2^32.
    key: [*]u8 = undefined,

    /// Type identifier of field. Available types
    /// are integer, decimal and string.
    type: field.Type = undefined,
    /// Field of object storing the actual data.
    /// String is used as byte array for serialization
    /// of more complex contents.
    /// Decimal and integer fields are used for
    /// fast math operations.
    field: union {
        /// Integer value: conventional i64.
        integer: field.Integer,

        /// Decimal value: conventional f64.
        decimal: field.Decimal,

        /// String is byte array data.
        /// No limit size, field.String is null-terminated.
        string: field.String,
    } = undefined,

    /// Stores metadata information associated with a key.
    /// This includes usage metrics.
    metadata: *Metadata = undefined,
    pub const Metadata = struct {
        /// Count of read, write operations.
        /// Also called FREQ.
        access_times: u64 = 0,

        /// Last access in timestamp (us).
        /// Useful for storage prefetching with LRU-policy.
        /// Also called LAST.
        last_access: i64 = undefined,

        /// Updates the metadata when the object is accessed.
        /// This increments the access counter and refreshes the last access timestamp.
        pub inline fn update(self: *@This()) void {
            // The saturation addition prevents counter overflow
            // and improves performance.
            self.access_times +|= 1;
            self.last_access = @intCast(std.time.microTimestamp());
        }
    };

    /// Retrieves key with length.
    pub inline fn getKey(self: *const Self) []const u8 {
        return self.key[0..self.len];
    }

    /// Sets key with cache L1/L2 prefetching on pointer.
    /// Key length must be lower than 2^32.
    pub fn setKey(self: *Self, noalias key: []u8) error{TypeOverflow}!void {
        if (key.len > std.math.maxInt(u32)) {
            @branchHint(.unlikely);
            return error.TypeOverflow;
        }

        self.key = key.ptr;
        self.len = @intCast(key.len);

        // prefeching with cache locality on L1/L2
        @prefetch(self.key, .{ .locality = 2 });
    }

    /// Initizializes object with key-value and metadata.
    /// If object is already set, insert self parameter.
    pub fn set(
        allocator: std.mem.Allocator,
        comptime field_type: field.Type,
        noalias key: []const u8,
        noalias value: anytype,
    ) error{ OutOfMemory, TypeOverflow }!Self {
        var obj: Object = .{};

        const duped_key = try allocator.dupe(u8, key);
        errdefer allocator.free(duped_key);

        try obj.setKey(duped_key);

        obj.metadata = try allocator.create(Metadata);
        obj.metadata.update();

        obj.type = field_type;
        obj.field = switch (field_type) {
            .integer => .{ .integer = value },
            .decimal => .{ .decimal = value },
            .string => .{ .string = .init(try allocator.dupeZ(u8, value)) },
        };

        return obj;
    }

    /// Return struct from serialized data.
    pub noinline fn deserialize(allocator: std.mem.Allocator, noalias data: []const u8) error{
        TypeOverflow,
        EndOfStream,
        UnsupportedType,
        OutOfMemory,
        ReadFailed,
    }!Self {
        var deserialized: std.Io.Reader = .fixed(data);

        var obj: Object = .{};

        const keylen = try deserialized.takeInt(u32, comptime .little);
        const key = try deserialized.readAlloc(allocator, keylen);
        errdefer allocator.free(key);

        try obj.setKey(key);

        // set metadata
        obj.metadata = try allocator.create(Metadata);
        obj.metadata.* = .{
            .access_times = try deserialized.takeInt(u64, comptime .little),
            .last_access = try deserialized.takeInt(i64, comptime .little),
        };

        // fill field from selected field type
        obj.type = try .fromInt(try deserialized.takeByte());
        obj.field = switch (obj.type) {
            .integer => .{ .integer = try deserialized.takeInt(i64, comptime .little) },
            .decimal => blk: {
                const arr = try deserialized.takeArray(8);
                break :blk .{ .decimal = @bitCast(arr.*) };
            },
            .string => .{ .string = try .deserialize(&deserialized, allocator) },
        };

        return obj;
    }

    /// Returns serialized object to byte array.
    pub noinline fn serialize(self: *const Self, allocator: std.mem.Allocator) error{ WriteFailed, OutOfMemory }![]u8 {
        // get len of serialized object
        const size = self.getSizeFromSerialized();

        // init preallocated buffer
        const buf: []u8 = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);

        var serialized: std.Io.Writer = .fixed(buf);

        // write the fields
        try serialized.writeInt(u32, @intCast(self.len), comptime .little);
        try serialized.writeAll(self.getKey());
        try serialized.writeInt(u64, self.metadata.access_times, comptime .little);
        try serialized.writeInt(i64, self.metadata.last_access, comptime .little);
        try serialized.writeInt(u8, @intFromEnum(self.type), comptime .little);

        // write value of object.
        // if value is string, add size
        switch (self.type) {
            .integer => try serialized.writeInt(i64, self.field.integer, comptime .little),
            .decimal => try serialized.writeAll(@ptrCast(&self.field.decimal)),
            .string => try self.field.string.serialize(&serialized),
        }

        return serialized.buffered();
    }

    /// Returns size of serialized object
    pub inline fn getSizeFromSerialized(self: *const Self) u64 {
        // field size is present if field type is string
        const fieldsize: u64 = switch (self.type) {
            .integer, .decimal => 8,
            .string => 8 + self.field.string.len(),
        };

        // size is composed of key size (4 bytes)
        // + key length + field type (1 byte) +
        // + field size + metadata (16 bytes)
        const size: u64 = 4 + self.len + 1 + fieldsize + 16;
        return size;
    }

    /// Returns size of object stored in RAM
    pub inline fn getSize(self: *const Self) u64 {
        var size: u64 = 24; // size of object
        size += 16; // metadata
        size += self.len; // length of key
        size += 8 + switch (self.type) { // field
            .string => self.field.string.len(),
            else => 0,
        };
        return size;
    }

    /// Frees all allocated memory associated with this object
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        // if field is string, deallocates it
        if (self.type == .string)
            self.field.string.deinit(allocator);

        // deallocated key
        allocator.free(self.getKey());
        allocator.destroy(self.metadata);

        self.* = undefined;
    }
};

test "integer/decimal set" {
    const ikey = "integerkey";
    const ivalue: i64 = 42;
    const dkey = "decimalkey";
    const dvalue: f64 = 3.14;

    var iobj = try Object.set(std.testing.allocator, .integer, ikey, ivalue);
    defer iobj.deinit(std.testing.allocator);

    var dobj = try Object.set(std.testing.allocator, .decimal, dkey, dvalue);
    defer dobj.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(ikey, iobj.getKey());
    try std.testing.expect(ivalue == iobj.field.integer);
    try std.testing.expectEqualStrings(dkey, dobj.getKey());
    try std.testing.expect(dvalue == dobj.field.decimal);
}

test "string set" {
    const key = "stringkey";
    const value: []const u8 = "text in key";

    var obj = try Object.set(std.testing.allocator, .string, key, value);
    defer obj.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(key, obj.getKey());
    try std.testing.expectEqualStrings(value, obj.field.string.get());

    const value2: []const u8 = "new text for this test";
    try obj.field.string.set(std.testing.allocator, value2);

    try std.testing.expectEqualStrings(value2, obj.field.string.get());
    try std.testing.expect(value2.len == obj.field.string.len());
}

test "serialize and deserialize" {
    const key = "keyname";
    const value: []const u8 = "serialized string";

    var obj = try Object.set(std.testing.allocator, .string, key, value);
    defer obj.deinit(std.testing.allocator);

    const serialized = try obj.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);

    var deserialized = try Object.deserialize(std.testing.allocator, serialized);
    defer deserialized.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(obj.getKey(), deserialized.getKey());
    try std.testing.expectEqualStrings(obj.field.string.get(), deserialized.field.string.get());
    try std.testing.expectEqual(obj.metadata.access_times, deserialized.metadata.access_times);
    try std.testing.expectEqual(obj.metadata.last_access, deserialized.metadata.last_access);
}

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}
