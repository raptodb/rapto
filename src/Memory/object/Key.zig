//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of Key.

const Key = @This();

const std = @import("std");
const value = @import("value.zig");
const glob = @import("../../glob.zig");
const assert = std.debug.assert;

const TaggedPtr = @import("tagged_ptr.zig").TaggedPtr;
pub const Error = std.mem.Allocator.Error || error{InvalidKey};

/// Pointer alignment of current architecture.
/// Defined for clarity and conventional purposes.
const ptr_alignment: std.mem.Alignment = .of(usize);

/// Tagged pointer to a length-prefixed key. The length is stored in the
/// first byte, limiting keys to 255 bytes. Like Memcached, this limit
/// works for most use cases and provides better performance.
/// The tag stores the value type in the 3 least significant bits.
ptr: TaggedPtr([*]align(ptr_alignment.toByteUnits()) u8) = undefined,

/// Initializes key by duplicating it
pub fn init(allocator: std.mem.Allocator, key: []const u8, value_type: value.Type) Error!Key {
    if (!isValidKey(key)) return error.InvalidKey;

    const slice = try allocator.alignedAlloc(u8, ptr_alignment, 1 + key.len);
    // Truncation is allowed by checking key firstly.
    slice[0] = @truncate(key.len);

    @memcpy(slice[1..], key);

    return .{ .ptr = .init(slice.ptr, @intFromEnum(value_type)) };
}

/// Deallocates key string with included length.
pub fn deinit(self: Key, allocator: std.mem.Allocator) void {
    allocator.free(self.content());
}

/// Efficiently replaces current key with a new key. Reallocates if necessary.
pub fn set(self: *Key, allocator: std.mem.Allocator, new_key: []const u8) Error!void {
    if (!isValidKey(new_key)) return error.InvalidKey;

    const length_new_key: u8 = @truncate(new_key.len);
    const length_old_key = self.len();

    var ptr = self.ptr.getPointer();

    if (length_old_key != length_new_key) {
        const slice = try allocator.realloc(
            ptr[0 .. 1 + length_old_key],
            1 + length_new_key,
        );

        ptr = slice.ptr;
        self.ptr.setPointer(ptr);
        // Update string length.
        ptr[0] = length_new_key;
    }

    @memcpy(ptr[1 .. 1 + length_new_key], new_key);
}

pub fn get(self: Key) []const u8 {
    return self.content()[1..];
}

/// Returns entire buffer with length and key.
fn content(self: Key) []align(ptr_alignment.toByteUnits()) const u8 {
    const ptr = self.ptr.getPointer();
    return ptr[0 .. 1 + self.len()];
}

/// Length of key retrieved by first byte.
pub fn len(self: Key) u8 {
    const ptr = self.ptr.getPointer();
    // Length is stored in the first byte.
    const key_len = ptr[0];
    assert(key_len != 0);
    return key_len;
}

pub fn getValueType(self: Key) value.Type {
    const tag = self.ptr.getTag();
    return value.Type.fromInt(tag) catch unreachable;
}

pub fn setValueType(self: *Key, value_type: value.Type) void {
    self.ptr.setTag(@intFromEnum(value_type));
}

pub fn isValidKey(key: []const u8) bool {
    return hasValidLength(key) and glob.classify(key) == .literal;
}

pub fn hasValidLength(key: []const u8) bool {
    return key.len != 0 and key.len <= std.math.maxInt(u8);
}
