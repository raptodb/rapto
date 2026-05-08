//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of object.

const std = @import("std");
const field = @import("field.zig");
const assert = std.debug.assert;

const TaggedPointer = @import("../tagged_pointer.zig").TaggedPointer;

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
        assert(@sizeOf(Key) == @sizeOf(usize));
        assert(@sizeOf(Field) == @sizeOf(usize));
    }

    // for this implementation
    assert(@sizeOf(u64) == @sizeOf(usize));
}

pub const Key = struct {
    /// Tagged pointer to key sentinel-terminated string.
    /// Tag encodes field type.
    ptr: TaggedPointer([*:0]align(pointer_alignment.toByteUnits()) u8) = undefined,

    /// Initializes key by duplicating it. Assumes key is
    /// sentinel-terminated with 0. The validity of key is checked.
    pub fn init(
        allocator: std.mem.Allocator,
        key: []const u8,
        field_type: field.Type,
    ) (std.mem.Allocator.Error || error{InvalidKey})!Key {
        assert(key.len > 0);

        // The key must not contatins the sentinel byte.
        // Sentinel byte is appended in this function.
        if (std.mem.indexOfScalar(u8, key, 0) != null) return error.InvalidKey;

        const buf = try allocator.alignedAlloc(u8, pointer_alignment, key.len + 1);
        errdefer allocator.free(buf);
        @memcpy(buf[0..key.len], key);
        buf[key.len] = 0;

        return fromSlice(buf[0..key.len :0], field_type);
    }

    /// Initializes key with externally-managed memory. This function
    /// is used mostly under tests. Assumes key is sentinel-terminated with 0.
    fn fromSlice(
        key: [:0]align(pointer_alignment.toByteUnits()) const u8,
        field_type: field.Type,
    ) error{InvalidKey}!Key {
        assert(key.len > 0);

        return .{ .ptr = .init(key.ptr, @intFromEnum(field_type)) };
    }

    /// Sets a new key. Reallocates if length is different.
    /// The validity of key is checked.
    pub fn set(
        self: *Key,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) (std.mem.Allocator.Error || error{InvalidKey})!void {
        assert(key.len > 0);
        // The key must not contatins the sentinel byte.
        // Sentinel byte is appended in this function.
        if (std.mem.indexOfScalar(u8, key, 0) != null) return error.InvalidKey;

        var ptr = self.ptr.getPointer();
        const length = self.len();

        if (key.len != length) {
            // Reallocate key with sentinel
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

    pub fn getFieldType(self: Key) field.Type {
        const tag = self.ptr.getTag();
        return field.Type.fromInt(tag) catch unreachable;
    }

    pub fn setFieldType(self: *Key, field_type: field.Type) void {
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
        pub fn ReturnType(comptime field_type: field.Type) type {
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
        pub fn UnionType(comptime field_type: field.Type) type {
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
        field_type: field.Type,
        content: []const u8,
    ) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType })!Field {
        return .{
            .value = switch (field_type) {
                .void => .{ .void = .fromContent() },
                .integer => .{ .integer = try .fromContent(content) },
                .decimal => .{ .decimal = try .fromContent(content) },
                .flag => .{ .flag = try .fromContent(content) },
                .string => .{ .string = try .initFromContent(allocator, content) },
                .point => .{ .point = try .initFromContent(allocator, content) },
                .list => .{ .list = try .initFromContent(allocator, content) },
                .map => .{ .map = try .initFromContent(allocator, content) },
            },
        };
    }

    pub fn setAsSameType(
        self: *Field,
        allocator: std.mem.Allocator,
        field_type: field.Type,
        content: []const u8,
    ) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType })!void {
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
        old_field_type: field.Type,
        new_field_type: field.Type,
        content: []const u8,
    ) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType })!void {
        // deallocate previous field first
        self.deinit(allocator, old_field_type);

        const new_field: Field = try .init(allocator, new_field_type, content);
        self.value = new_field.value;
    }

    /// Limits: get must not allocate memory.
    pub fn get(self: Field, comptime field_type: field.Type) Value.ReturnType(field_type) {
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

    pub inline fn ptr(self: *Field, field_type: field.Type) *Value.UnionType(field_type) {
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
        field_type: field.Type,
    ) std.Io.Writer.Error!void {
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

    pub fn deinit(self: Field, allocator: std.mem.Allocator, field_type: field.Type) void {
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

    /// Wraps pointers from Key and Field into Ref. Does not take ownership.
    pub fn wrap(key_ptr: *Key, value_ptr: *Field) Ref {
        return .{ .key_ptr = key_ptr, .value_ptr = value_ptr };
    }

    pub fn key(self: Ref) []const u8 {
        return self.key_ptr.get();
    }

    pub fn value(
        self: Ref,
        comptime field_type: field.Type,
    ) Field.Value.ReturnType(field_type) {
        assert(self.type() == field_type);
        return self.value_ptr.get(field_type);
    }

    /// Returns pointer to the field value. Used
    /// to access directly in the field without
    /// copying and for in-place and SPECIFIC operations.
    pub inline fn valuePtr(
        self: *const Ref,
        comptime field_type: field.Type,
    ) *Field.Value.UnionType(field_type) {
        return self.value_ptr.ptr(field_type);
    }

    pub fn setKey(
        self: *const Ref,
        allocator: std.mem.Allocator,
        new_key: []const u8,
    ) (std.mem.Allocator.Error || error{InvalidKey})!void {
        try self.key_ptr.set(allocator, new_key);
    }

    /// Sets field with a new value.
    /// If field type is different, deallocates previous field
    /// and allocates new field. Otherwise, updates in-place.
    pub fn setValue(
        self: *const Ref,
        allocator: std.mem.Allocator,
        field_type: field.Type,
        content: []const u8,
    ) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType })!void {
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

    pub fn serializeToWriter(
        self: Ref,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const field_type = self.type();
        try field_type.serializeToWriter(writer);
        try self.value_ptr.serializeContentToWriter(writer, field_type);
    }

    /// Serialized content of field to writer.
    /// NOTE: content does not contains [field_type] according to Rapto's serialized (SR).
    pub fn serializeContentToWriter(
        self: Ref,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const field_type = self.type();
        try self.value_ptr.serializeContentToWriter(writer, field_type);
    }

    /// Returns type of field exploiting tag of pointer to key.
    pub fn @"type"(self: Ref) field.Type {
        return self.key_ptr.getFieldType();
    }
};

test "Ref" {
    const allocator = std.testing.allocator;

    const integer_content: [8]u8 = @bitCast(@as(i64, 42));

    {
        var key: Key = try .init(allocator, "my_key", .integer);
        var f: Field = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer {
            ref.key_ptr.deinit(allocator);
            ref.value_ptr.deinit(allocator, ref.key_ptr.getFieldType());
        }

        try std.testing.expectEqualStrings("my_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var key: Key = try .init(allocator, "aaa", .integer);
        var f: Field = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer {
            ref.key_ptr.deinit(allocator);
            ref.value_ptr.deinit(allocator, ref.key_ptr.getFieldType());
        }

        try ref.setKey(allocator, "bbb");

        try std.testing.expectEqualStrings("bbb", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var key: Key = try .init(allocator, "short", .integer);
        var f: Field = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer {
            ref.key_ptr.deinit(allocator);
            ref.value_ptr.deinit(allocator, ref.key_ptr.getFieldType());
        }

        try ref.setKey(allocator, "a_much_longer_key");

        try std.testing.expectEqualStrings("a_much_longer_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var key: Key = try .init(allocator, "valid", .integer);
        var f: Field = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer {
            ref.key_ptr.deinit(allocator);
            ref.value_ptr.deinit(allocator, ref.key_ptr.getFieldType());
        }

        try std.testing.expectError(error.InvalidKey, ref.setKey(allocator, "in\x00valid"));
        try std.testing.expectEqualStrings("valid", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        const integer_20_content: [8]u8 = @bitCast(@as(i64, 20));

        var key: Key = try .init(allocator, "my_key", .integer);
        var f: Field = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer {
            ref.key_ptr.deinit(allocator);
            ref.value_ptr.deinit(allocator, ref.key_ptr.getFieldType());
        }

        try ref.setValue(allocator, .integer, &integer_20_content);

        try std.testing.expectEqualStrings("my_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var key: Key = try .init(allocator, "my_key", .integer);
        var f: Field = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer {
            ref.key_ptr.deinit(allocator);
            ref.value_ptr.deinit(allocator, ref.key_ptr.getFieldType());
        }

        try ref.setValue(allocator, .string, "hello");

        try std.testing.expectEqualStrings("my_key", ref.key());
        try std.testing.expectEqual(.string, ref.type());
    }

    {
        var key: Key = try .init(allocator, "evolving", .integer);
        var f: Field = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer {
            ref.key_ptr.deinit(allocator);
            ref.value_ptr.deinit(allocator, ref.key_ptr.getFieldType());
        }

        try ref.setValue(allocator, .string, "step one");
        try std.testing.expectEqualStrings("evolving", ref.key());
        try std.testing.expectEqual(.string, ref.type());

        const decimal_content: [8]u8 = @bitCast(@as(f64, 9.81));
        try ref.setValue(allocator, .decimal, &decimal_content);
        try std.testing.expectEqualStrings("evolving", ref.key());
        try std.testing.expectEqual(.decimal, ref.type());

        const flag_content: [8]u8 = @bitCast(@as(u64, 1));
        try ref.setValue(allocator, .flag, &flag_content);
        try std.testing.expectEqualStrings("evolving", ref.key());
        try std.testing.expectEqual(.flag, ref.type());
    }

    {
        var key: Key = try .init(allocator, "old_key", .integer);
        var f: Field = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer {
            ref.key_ptr.deinit(allocator);
            ref.value_ptr.deinit(allocator, ref.key_ptr.getFieldType());
        }

        try ref.setKey(allocator, "new_key");
        try std.testing.expectEqualStrings("new_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());

        try ref.setValue(allocator, .string, "hello");
        try std.testing.expectEqualStrings("new_key", ref.key());
        try std.testing.expectEqual(.string, ref.type());
    }
}
