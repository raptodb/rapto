//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! It contains the implementation of tagged pointer.

const std = @import("std");

pub fn TaggedPtr(comptime T: type) type {
    std.debug.assert(@typeInfo(T) == .pointer);

    const tag_bits: u64 = std.math.log2(@alignOf(T));
    const Tag: type = std.meta.Int(.unsigned, tag_bits);

    return struct {
        const Self = @This();

        const tag_mask: u64 = (1 << tag_bits) - 1;
        const ptr_mask: u64 = ~tag_mask;

        ptr: u64,

        pub fn init(ptr: anytype, tag: Tag) Self {
            return .{ .ptr = @intFromPtr(ptr) | tag };
        }

        pub fn initPointer(ptr: anytype) Self {
            return .{ .ptr = @intFromPtr(ptr) };
        }

        pub fn getPointer(self: Self) T {
            return @ptrFromInt(self.ptr & ptr_mask);
        }

        pub fn getTag(self: Self) Tag {
            return @truncate(self.ptr & tag_mask);
        }

        pub fn setPointer(self: *Self, ptr: T) void {
            self.ptr = @intFromPtr(ptr) | (self.ptr & tag_mask);
        }

        pub fn setTag(self: *Self, tag: Tag) void {
            self.ptr = (self.ptr & ptr_mask) | @as(u64, tag);
        }
    };
}
