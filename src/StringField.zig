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
//! It contains the implementation of string field.

const std = @import("std");

const Self = @This();

/// The pointer to byte array.
/// Limit size: 2^64-1.
ptr: [*:0]u8,

/// Initializes string field duping it with allocator.
/// String must have a length less than 2^64-1.
pub inline fn initAlloc(_: Self, allocator: std.mem.Allocator, string: []const u8) error{ OutOfMemory, TypeOverflow }!Self {
    return .init(undefined, try allocator.dupeZ(u8, @constCast(string)));
}

/// Initializes string field with string.
/// String must have a length less than 2^64-1.
pub inline fn init(_: Self, string: []u8) error{TypeOverflow}!Self {
    return if (string.len < std.math.maxInt(u64)) .{ .ptr = @ptrCast(string) } else error.TypeOverflow;
}

/// Copies string to current field string.
/// If length is different to old field string make a realloc.
/// String must have a length less than 2^64-1.
pub fn set(self: *Self, allocator: std.mem.Allocator, string: []const u8) error{ OutOfMemory, TypeOverflow }!void {
    if (self.len() != string.len) if (string.len < std.math.maxInt(u64)) {
        const slice = try allocator.realloc(self.ptr[0 .. self.len() + 1], string.len + 1);
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

// module tested in `object.zig`

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}