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
//! It contains the GENERIC implementation of tagged pointer.

const std = @import("std");

pub fn TaggedPointer(comptime T: type) type {
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
            self.value = @intFromPtr(ptr) | (self.ptr & tag_mask);
        }

        pub fn setTag(self: *Self, tag: Tag) void {
            self.ptr = (self.ptr & ptr_mask) | @as(u64, tag);
        }
    };
}
