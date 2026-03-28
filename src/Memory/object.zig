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
//! It contains the implementation of object.

const std = @import("std");
const field = @import("../field.zig");

const TaggedPointer = @import("tagged_pointer.zig").TaggedPointer;

/// Pointer alignment of current architecture.
/// Defined for clarity and conventional purposes.
const pointer_alignment: std.mem.Alignment = .of(usize);
/// Number of LSB bits used for length encoding. LSB bits are calculated
/// from log2 of pointer alignment, for example, in 64-bit architectures,
/// alignment of pointer is 8 bytes, so 3 LSB bits are used.
/// This instruction is only for clarity and conventional purposes.
const Lsb: type = std.meta.Int(.unsigned, @intFromEnum(pointer_alignment));

comptime {
    // ensures fixed size of {key, value} pair have
    // a size of 2 pointers on ReleaseFast mode
    const mode = @import("builtin").mode;
    if (mode == .ReleaseFast or mode == .ReleaseSafe) {
        std.debug.assert(@sizeOf(Key) == @sizeOf(usize));
        std.debug.assert(@sizeOf(Field) == @sizeOf(usize));
    }

    // for this implementation
    std.debug.assert(@sizeOf(u64) == @sizeOf(usize));
}

/// Checks the key validity.
/// Key must not contain sentinel byte 0.
inline fn checkKey(key: []const u8) error{InvalidKey}!void {
    std.debug.assert(key.len > 0);
    // key must not contain sentinel byte
    if (std.mem.indexOfScalar(u8, key, 0) != null) return error.InvalidKey;
}

pub const Key = struct {
    /// Tagged pointer to key sentinel-terminated string.
    /// Tag encodes field type.
    ptr: TaggedPointer([*:0]align(pointer_alignment.toByteUnits()) u8) = undefined,

    /// Initializes key by duplicating it.
    pub fn init(
        allocator: std.mem.Allocator,
        key: []const u8,
        field_type: field.Types,
    ) error{ OutOfMemory, InvalidKey }!Key {
        const buf = try allocator.alignedAlloc(u8, pointer_alignment, key.len + 1);
        errdefer allocator.free(buf);
        @memcpy(buf[0..key.len], key);
        buf[key.len] = 0;

        return fromSlice(buf[0..key.len :0], field_type);
    }

    /// Initializes key with externally-managed memory.
    /// This function assumes key is sentinel-terminated with 0.
    /// The validity of key is checked.
    pub fn fromSlice(
        key: [:0]align(pointer_alignment.toByteUnits()) const u8,
        field_type: field.Types,
    ) error{InvalidKey}!Key {
        try checkKey(key);
        return .{ .ptr = .init(key.ptr, @intFromEnum(field_type)) };
    }

    /// Sets a new key. Reallocates if length is different.
    /// The validity of key is checked.
    pub fn set(
        self: *Key,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) error{ OutOfMemory, InvalidKey }!void {
        var ptr = self.ptr.getPointer();
        const length = self.len();

        if (key.len != length) {
            // if the lengths are equal, one has already been checked
            // and they are always valid, otherwise, the length check
            // is performed when the lengths are different
            try checkKey(key);

            // reallocate with sentinel
            const buf = try allocator.realloc(ptr[0 .. length + 1], key.len + 1);
            buf[key.len] = 0;

            ptr = @ptrCast(buf);
            self.ptr.setPointer(ptr);
        }

        @memcpy(ptr[0..key.len], key);
    }

    pub fn get(self: Key) []const u8 {
        const ptr = self.ptr.getPointer();
        return ptr[0..self.len()];
    }

    pub fn len(self: Key) u64 {
        const ptr = self.ptr.getPointer();
        return std.mem.indexOfSentinel(u8, 0, ptr);
    }

    pub fn isEqualTo(self: Key, key: []const u8) bool {
        const ptr = self.ptr.getPointer();

        var i: usize = 0;
        while (ptr[i] != 0 and i < key.len) : (i += 1) {
            if (key[i] != ptr[i]) {
                @branchHint(.unpredictable);
                return false;
            }
        }

        // if length does not match, keys are not equals
        return key.len == i;
    }

    pub fn getFieldType(self: Key) field.Types {
        const tag = self.ptr.getTag();
        return field.Types.fromInt(tag) catch unreachable;
    }

    pub fn setFieldType(self: *Key, field_type: field.Types) void {
        self.ptr.setTag(@intFromEnum(field_type));
    }

    /// Deallocates key string with included sentinel.
    pub fn deinit(self: Key, allocator: std.mem.Allocator) void {
        const ptr = self.ptr.getPointer();
        allocator.free(ptr[0 .. self.len() + 1]);
    }
};

pub const Field = struct {
    /// Content of Field.
    value: Value,

    /// Value is the union of all possible field types.
    /// Fields are divided in scalar types and collection types.
    /// The type is determined by LSB bits of pointer to Key.
    pub const Value = union {
        // scalar types
        void: field.Void,
        integer: field.Integer,
        decimal: field.Decimal,
        flag: field.Flag,
        string: field.String,
        point: field.Point,

        // collection types
        list: field.List,
        map: field.Map,

        /// Returns type of the generic get function.
        /// These types are "complex" to exploit zero-copy returns.
        pub fn ReturnType(comptime field_type: field.Types) type {
            return switch (field_type) {
                .void => void,
                .integer => i64,
                .decimal => f64,
                .string => []const u8,
                .flag => field.Flag.Status,
                .point => field.Point.Axis,
                .list => []field.ScalarItem,
                .map => field.Map.HashMap.Iterator,
            };
        }

        /// Returns the complex type of the field.
        pub fn UnionType(comptime field_type: field.Types) type {
            return switch (field_type) {
                .void => field.Void,
                .integer => field.Integer,
                .decimal => field.Decimal,
                .flag => field.Flag,
                .string => field.String,
                .point => field.Point,
                .list => field.List,
                .map => field.Map,
            };
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        field_type: field.Types,
        content: []const u8,
    ) error{ OutOfMemory, InvalidFormat, MismatchType, UnknownType }!Field {
        return .{
            .value = switch (field_type) {
                .void => .{ .void = .init() },
                .integer => .{ .integer = try .init(content) },
                .decimal => .{ .decimal = try .init(content) },
                .flag => .{ .flag = try .init(content) },
                .string => .{ .string = try .init(allocator, content) },
                .point => .{ .point = try .init(allocator, content) },
                .list => .{ .list = try .init(allocator, content) },
                .map => .{ .map = try .init(allocator, content) },
            },
        };
    }

    pub fn setAsSameType(
        self: *Field,
        allocator: std.mem.Allocator,
        field_type: field.Types,
        content: []const u8,
    ) error{ OutOfMemory, InvalidFormat, MismatchType, UnknownType }!void {
        return switch (field_type) {
            .void => self.value.void.set(),
            .integer => self.value.integer.set(content),
            .decimal => self.value.decimal.set(content),
            .flag => self.value.flag.set(content),
            .string => self.value.string.set(allocator, content),
            .point => self.value.point.set(content),
            .list => self.value.list.set(allocator, content),
            .map => self.value.map.set(allocator, content),
        };
    }

    pub fn setAsDifferentType(
        self: *Field,
        allocator: std.mem.Allocator,
        old_field_type: field.Types,
        new_field_type: field.Types,
        content: []const u8,
    ) error{ OutOfMemory, InvalidFormat, MismatchType, UnknownType }!void {
        // deallocate previous field first
        self.deinit(allocator, old_field_type);

        const new_field: Field = try .init(allocator, new_field_type, content);
        self.value = new_field.value;
    }

    /// Limits: get must not allocate memory.
    pub fn get(self: Field, comptime field_type: field.Types) Value.ReturnType(field_type) {
        return switch (field_type) {
            .void => self.value.void.get(),
            .integer => self.value.integer.get(),
            .decimal => self.value.decimal.get(),
            .flag => self.value.flag.get(),
            .string => self.value.string.get(),
            .point => self.value.point.get(),
            .list => self.value.list.get(),
            .map => self.value.map.get(),
        };
    }

    pub inline fn ptr(self: *Field, field_type: field.Types) *Value.UnionType(field_type) {
        return switch (field_type) {
            .void => &self.value.void,
            .integer => &self.value.integer,
            .decimal => &self.value.decimal,
            .flag => &self.value.flag,
            .string => &self.value.string,
            .point => &self.value.point,
            .list => &self.value.list,
            .map => &self.value.map,
        };
    }

    pub fn serializeContentToWriter(
        self: Field,
        writer: *std.Io.Writer,
        field_type: field.Types,
    ) error{WriteFailed}!void {
        return switch (field_type) {
            .void => self.value.void.serializeContentToWriter(writer),
            .integer => self.value.integer.serializeContentToWriter(writer),
            .decimal => self.value.decimal.serializeContentToWriter(writer),
            .flag => self.value.flag.serializeContentToWriter(writer),
            .string => self.value.string.serializeContentToWriter(writer),
            .point => self.value.point.serializeContentToWriter(writer),
            .list => self.value.list.serializeContentToWriter(writer),
            .map => self.value.map.serializeContentToWriter(writer),
        };
    }

    /// Deallocates content of field.
    pub fn deinit(self: Field, allocator: std.mem.Allocator, field_type: field.Types) void {
        switch (field_type) {
            .void, .integer, .decimal, .flag => {},
            .string => self.value.string.deinit(allocator),
            .point => self.value.point.deinit(allocator),
            .list => self.value.list.deinit(allocator),
            .map => self.value.map.deinit(allocator),
        }
    }
};

/// Safe reference adapter to a Key-Field representation as key-value.
/// This allows safe operations on key or field while keeping the fields separate.
pub const Ref = struct {
    key_ptr: *Key,
    value_ptr: *Field,

    pub fn init(key_ptr: *Key, value_ptr: *Field) Ref {
        return .{ .key_ptr = key_ptr, .value_ptr = value_ptr };
    }

    pub fn deinit(self: *const Ref, allocator: std.mem.Allocator) void {
        self.key_ptr.deinit(allocator);
        self.value_ptr.deinit(allocator, self.type());
    }

    pub fn key(self: *const Ref) []const u8 {
        return self.key_ptr.get();
    }

    pub fn value(
        self: *const Ref,
        comptime field_type: field.Types,
    ) Field.Value.ReturnType(field_type) {
        std.debug.assert(self.type() == field_type);
        return self.value_ptr.get(field_type);
    }

    /// Returns pointer to the field value. Used to access directly
    /// in the field without copying and for in-place and SPECIFIC operations.
    /// Use it with caution !!!
    pub inline fn valuePtr(
        self: *const Ref,
        comptime field_type: field.Types,
    ) *Field.Value.UnionType(field_type) {
        return self.value_ptr.ptr(field_type);
    }

    pub fn setKey(
        self: *const Ref,
        allocator: std.mem.Allocator,
        new_key: []const u8,
    ) error{ OutOfMemory, InvalidKey }!void {
        try self.key_ptr.set(allocator, new_key);
    }

    /// Sets field with a new value.
    /// If field type is different, deallocates previous field
    /// and allocates new field. Otherwise, updates in-place.
    pub fn setValue(
        self: *const Ref,
        allocator: std.mem.Allocator,
        field_type: field.Types,
        content: []const u8,
    ) error{ OutOfMemory, InvalidFormat, MismatchType, UnknownType }!void {
        const current_field_type = self.type();

        if (field_type != current_field_type) {
            @branchHint(.unlikely);

            try self.value_ptr.setAsDifferentType(
                allocator,
                current_field_type,
                field_type,
                content,
            );

            // update tag to new field type
            return self.key_ptr.setFieldType(field_type);
        }

        return self.value_ptr.setAsSameType(allocator, field_type, content);
    }

    /// Serialized content of field to writer.
    /// NOTE: content does not contains [field_type] according to Rapto's serialized (SR).
    pub fn serializeContentToWriter(
        self: *const Ref,
        writer: *std.Io.Writer,
    ) error{WriteFailed}!void {
        const field_type = self.type();
        try self.value_ptr.serializeContentToWriter(writer, field_type);
    }

    /// Returns type of field exploiting tag of pointer to key.
    pub fn @"type"(self: *const Ref) field.Types {
        return self.key_ptr.getFieldType();
    }
};

test "Ref" {
    const allocator = std.testing.allocator;

    const integer_content: [8]u8 = blk: {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &buf, 42, .little);
        break :blk buf;
    };

    {
        var key: Key = try .init(allocator, "my_key", .integer);
        defer key.deinit(allocator);
        var f: Field = try .init(allocator, .integer, &integer_content);
        defer f.deinit(allocator, .integer);

        const ref: Ref = .init(&key, &f);

        try std.testing.expectEqualStrings("my_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var key: Key = try .init(allocator, "aaa", .integer);
        defer key.deinit(allocator);
        var f: Field = try .init(allocator, .integer, &integer_content);
        defer f.deinit(allocator, .integer);

        const ref: Ref = .init(&key, &f);
        try ref.setKey(allocator, "bbb");

        try std.testing.expectEqualStrings("bbb", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var key: Key = try .init(allocator, "short", .integer);
        defer key.deinit(allocator);
        var f: Field = try .init(allocator, .integer, &integer_content);
        defer f.deinit(allocator, .integer);

        const ref: Ref = .init(&key, &f);
        try ref.setKey(allocator, "a_much_longer_key");

        try std.testing.expectEqualStrings("a_much_longer_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var key: Key = try .init(allocator, "valid", .integer);
        defer key.deinit(allocator);
        var f: Field = try .init(allocator, .integer, &integer_content);
        defer f.deinit(allocator, .integer);

        const ref: Ref = .init(&key, &f);
        try std.testing.expectError(error.InvalidKey, ref.setKey(allocator, "in\x00valid"));

        try std.testing.expectEqualStrings("valid", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        const integer_20_content: [8]u8 = blk: {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(i64, &buf, 20, .little);
            break :blk buf;
        };

        var key: Key = try .init(allocator, "my_key", .integer);
        defer key.deinit(allocator);
        var f: Field = try .init(allocator, .integer, &integer_content);
        defer f.deinit(allocator, .integer);

        const ref: Ref = .init(&key, &f);
        try ref.setValue(allocator, .integer, &integer_20_content);

        try std.testing.expectEqualStrings("my_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var key: Key = try .init(allocator, "my_key", .integer);
        var f: Field = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .init(&key, &f);
        try ref.setValue(allocator, .string, "hello");

        try std.testing.expectEqualStrings("my_key", ref.key());
        try std.testing.expectEqual(.string, ref.type());

        ref.deinit(allocator);
    }

    {
        var key: Key = try .init(allocator, "evolving", .integer);
        var f: Field = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .init(&key, &f);

        try ref.setValue(allocator, .string, "step one");
        try std.testing.expectEqualStrings("evolving", ref.key());
        try std.testing.expectEqual(.string, ref.type());

        const decimal_content: [8]u8 = @bitCast(@as(f64, 9.81));
        try ref.setValue(allocator, .decimal, &decimal_content);
        try std.testing.expectEqualStrings("evolving", ref.key());
        try std.testing.expectEqual(.decimal, ref.type());

        const flag_content: [8]u8 = blk: {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, 1, .little);
            break :blk buf;
        };
        try ref.setValue(allocator, .flag, &flag_content);
        try std.testing.expectEqualStrings("evolving", ref.key());
        try std.testing.expectEqual(.flag, ref.type());

        ref.deinit(allocator);
    }

    {
        var key: Key = try .init(allocator, "old_key", .integer);
        var f: Field = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .init(&key, &f);

        try ref.setKey(allocator, "new_key");
        try std.testing.expectEqualStrings("new_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());

        try ref.setValue(allocator, .string, "hello");
        try std.testing.expectEqualStrings("new_key", ref.key());
        try std.testing.expectEqual(.string, ref.type());

        ref.deinit(allocator);
    }
}
