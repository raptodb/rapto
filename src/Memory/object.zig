//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of object.

const std = @import("std");
pub const value = @import("value.zig");
const assert = std.debug.assert;

pub const Key = @import("Key.zig");
pub const Value = value.Value;

comptime {
    // Ensures fixed size of {key, value} pair have
    // a size of 2 pointers on ReleaseFast mode.
    const mode = @import("builtin").mode;
    if (mode == .ReleaseFast or mode == .ReleaseSafe) {
        assert(@sizeOf(Key) == @sizeOf(usize));
        assert(@sizeOf(Value) == @sizeOf(usize));
    }

    // for this implementation
    assert(@sizeOf(u64) == @sizeOf(usize));
}

/// Safe reference adapter to key-value.
/// This allows safe operations on key or
/// value while keeping the values separate.
pub const Ref = struct {
    key_ptr: *Key,
    value_ptr: *Value,

    /// Wraps pointers from Key and Value into Ref. Does not take ownership.
    pub fn wrap(key_ptr: *Key, value_ptr: *Value) Ref {
        return .{ .key_ptr = key_ptr, .value_ptr = value_ptr };
    }

    pub fn key(self: Ref) []const u8 {
        return self.key_ptr.get();
    }

    pub fn getValue(
        self: Ref,
        comptime value_type: value.Type,
    ) Value.ReturnType(value_type) {
        assert(self.type() == value_type);
        return self.value_ptr.get(value_type);
    }

    /// Returns pointer to the value value. Used
    /// to access directly in the value without
    /// copying and for in-place and SPECIFIC operations.
    pub inline fn valuePtr(
        self: Ref,
        comptime value_type: value.Type,
    ) *Value.UnionType(value_type) {
        return self.value_ptr.ptr(value_type);
    }

    pub fn setKey(
        self: Ref,
        allocator: std.mem.Allocator,
        new_key: []const u8,
    ) (std.mem.Allocator.Error || error{ InvalidKey, KeyTooLong })!void {
        try self.key_ptr.set(allocator, new_key);
    }

    /// Sets value with a new value.
    /// If value type is different, deallocates previous value
    /// and allocates new value. Otherwise, updates in-place.
    pub fn setValue(
        self: Ref,
        allocator: std.mem.Allocator,
        value_type: value.Type,
        content: []const u8,
    ) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType })!void {
        const current_value_type = self.type();

        if (value_type != current_value_type) {
            @branchHint(.unlikely);

            // deallocate previous value first
            self.value_ptr.deinit(allocator, current_value_type);
            self.value_ptr.* = try .init(allocator, value_type, content);

            // update tag to new value type
            return self.key_ptr.setValueType(value_type);
        }

        return self.value_ptr.set(allocator, value_type, content);
    }

    pub fn serializeToWriter(
        self: Ref,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const value_type = self.type();
        try value_type.serializeToWriter(writer);
        try self.value_ptr.serializeContentToWriter(writer, value_type);
    }

    /// Serialized content of value to writer.
    pub fn serializeContentToWriter(
        self: Ref,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const value_type = self.type();
        try self.value_ptr.serializeContentToWriter(writer, value_type);
    }

    /// Returns type of value exploiting tag of pointer to key.
    pub fn @"type"(self: Ref) value.Type {
        return self.key_ptr.getValueType();
    }
};

test "Ref" {
    const allocator = std.testing.allocator;

    const integer_content: [8]u8 = @bitCast(@as(i64, 42));

    {
        var key: Key = try .init(allocator, "my_key", .integer);
        var f: Value = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer {
            ref.key_ptr.deinit(allocator);
            ref.value_ptr.deinit(allocator, ref.key_ptr.getValueType());
        }

        try std.testing.expectEqualStrings("my_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var key: Key = try .init(allocator, "aaa", .integer);
        var f: Value = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer {
            ref.key_ptr.deinit(allocator);
            ref.value_ptr.deinit(allocator, ref.key_ptr.getValueType());
        }

        try ref.setKey(allocator, "bbb");

        try std.testing.expectEqualStrings("bbb", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var key: Key = try .init(allocator, "short", .integer);
        var f: Value = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer {
            ref.key_ptr.deinit(allocator);
            ref.value_ptr.deinit(allocator, ref.key_ptr.getValueType());
        }

        try ref.setKey(allocator, "a_much_longer_key");

        try std.testing.expectEqualStrings("a_much_longer_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var raw_key: [260]u8 = @splat(0);
        try std.testing.expectError(
            error.KeyTooLong,
            Key.init(allocator, &raw_key, .integer),
        );
    }

    {
        const integer_20_content: [8]u8 = @bitCast(@as(i64, 20));

        var key: Key = try .init(allocator, "my_key", .integer);
        var f: Value = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer {
            ref.key_ptr.deinit(allocator);
            ref.value_ptr.deinit(allocator, ref.key_ptr.getValueType());
        }

        try ref.setValue(allocator, .integer, &integer_20_content);

        try std.testing.expectEqualStrings("my_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var key: Key = try .init(allocator, "my_key", .integer);
        var f: Value = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer {
            ref.key_ptr.deinit(allocator);
            ref.value_ptr.deinit(allocator, ref.key_ptr.getValueType());
        }

        try ref.setValue(allocator, .string, "hello");

        try std.testing.expectEqualStrings("my_key", ref.key());
        try std.testing.expectEqual(.string, ref.type());
    }

    {
        var key: Key = try .init(allocator, "evolving", .integer);
        var f: Value = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer {
            ref.key_ptr.deinit(allocator);
            ref.value_ptr.deinit(allocator, ref.key_ptr.getValueType());
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
        var f: Value = try .init(allocator, .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer {
            ref.key_ptr.deinit(allocator);
            ref.value_ptr.deinit(allocator, ref.key_ptr.getValueType());
        }

        try ref.setKey(allocator, "new_key");
        try std.testing.expectEqualStrings("new_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());

        try ref.setValue(allocator, .string, "hello");
        try std.testing.expectEqualStrings("new_key", ref.key());
        try std.testing.expectEqual(.string, ref.type());
    }
}
