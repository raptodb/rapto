//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of Key.

const Key = @This();

const std = @import("std");
const value = @import("value.zig");
const assert = std.debug.assert;

const TaggedPointer = @import("tagged_pointer.zig").TaggedPointer;

/// Pointer alignment of current architecture.
/// Defined for clarity and conventional purposes.
const pointer_alignment: std.mem.Alignment = .of(usize);
/// Number of LSB bits used for length encoding. LSB bits are calculated
/// from log2 of pointer alignment, for example, in 64-bit architectures,
/// alignment of pointer is 8 bytes, so 3 LSB bits are used.
/// This instruction is only for clarity and conventional purposes.
const Lsb: type = std.meta.Int(.unsigned, @intFromEnum(pointer_alignment));

/// Tagged pointer to key. Tag encodes value type.
/// The maximum length is 2^8-1, for performance purposes.
ptr: TaggedPointer([*]align(pointer_alignment.toByteUnits()) u8) = undefined,

/// Initializes key by duplicating it.
/// Checks if length of key is within 2^8-1.
pub fn init(
    allocator: std.mem.Allocator,
    key: []const u8,
    value_type: value.Type,
) (std.mem.Allocator.Error || error{InvalidKey})!Key {
    if (key.len > std.math.maxInt(u8) or
        key.len == 0) return error.InvalidKey;

    const buf = try allocator.alignedAlloc(u8, pointer_alignment, 1 + key.len);
    errdefer allocator.free(buf);

    buf[0] = @truncate(key.len);
    @memcpy(buf[1..], key);

    return .{ .ptr = .init(buf.ptr, @intFromEnum(value_type)) };
}

/// Sets a new key. Reallocates if length is different.
/// Checks if length of key is within 2^8-1.
pub fn set(
    self: *Key,
    allocator: std.mem.Allocator,
    key: []const u8,
) (std.mem.Allocator.Error || error{InvalidKey})!void {
    if (key.len > std.math.maxInt(u8) or
        key.len == 0) return error.InvalidKey;

    const key_length: u8 = @truncate(key.len);
    const length = self.len();

    var ptr = self.ptr.getPointer();

    if (length != key_length) {
        const slice = try allocator.realloc(
            ptr[0 .. 1 + length],
            1 + key_length,
        );

        ptr = @ptrCast(slice);
        self.ptr.setPointer(ptr);

        ptr[0] = key_length;
    }

    @memcpy(ptr[1 .. 1 + key_length], key);
}

pub fn get(self: Key) []const u8 {
    const key_ptr = self.ptr.getPointer()[1..];
    return key_ptr[0..self.len()];
}

pub fn len(self: Key) u8 {
    const ptr = self.ptr.getPointer();
    // Length is stored in the first byte.
    return ptr[0];
}

pub fn getValueType(self: Key) value.Type {
    const tag = self.ptr.getTag();
    return value.Type.fromInt(tag) catch unreachable;
}

pub fn setValueType(self: *Key, value_type: value.Type) void {
    self.ptr.setTag(@intFromEnum(value_type));
}

/// Deallocates key string with included sentinel.
pub fn deinit(self: Key, allocator: std.mem.Allocator) void {
    const ptr = self.ptr.getPointer();
    allocator.free(ptr[0 .. 1 + self.len()]);
}
