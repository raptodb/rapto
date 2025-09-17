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
//! It contains the implementation of utils functions.

const std = @import("std");

const FieldType = @import("object.zig").Object.FieldType;

const hash = std.hash.XxHash3.hash;
/// Alias of std.Thread.spawn. Just abbreviated and adapted to Rapto.
pub const spawn = struct {
    fn inner(comptime func: anytype, args: anytype) error{ThreadError}!std.Thread {
        return std.Thread.spawn(comptime .{}, func, args) catch return error.ThreadError;
    }
}.inner;

/// Custom integer/decimal parsing with MismatchType error.
pub inline fn parseNumeric(comptime T: type, value: []const u8) error{MismatchType}!T {
    const parsed = switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, value, 10),
        .float => std.fmt.parseFloat(T, value),
        else => unreachable,
    };
    return parsed catch error.MismatchType;
}

/// Appends item to std.ArrayList with growing of 1.
pub inline fn appendNoGrowing(
    comptime T: type,
    allocator: std.mem.Allocator,
    array: *std.ArrayList(T),
    item: T,
) error{OutOfMemory}!void {
    try array.ensureTotalCapacityPrecise(allocator, array.items.len + 1);
    array.items.len += 1;
    array.items[array.items.len - 1] = item;
}

/// Advanced equal function with vectorization and hashing
/// checking. Faster if len <= 16.
pub inline fn advancedCompare(noalias a: []const u8, noalias b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len <= 16) {
        @branchHint(.likely);
        return std.mem.eql(u8, a, b);
    }

    // hash checking usually does not match
    else if (hash(0, a) != hash(0, b)) {
        @branchHint(.likely);
        return false;
    }

    // if hashes are equals, compare
    else return std.mem.eql(u8, a, b);
}

/// Split a text with space separator.
/// Useful to split key and arguments.
pub inline fn kvFormat(args: []const u8) error{MissingTokens}!struct { []const u8, []const u8 } {
    // starting from 1st index because key
    // has a minimum length of 1
    const sep: u64 = std.mem.indexOfScalarPos(u8, args, 1, ' ') orelse return error.MissingTokens;
    return .{ args[0..sep], args[sep + 1 ..] };
}

test "key value format" {
    const key1, const value1 = try kvFormat("key value");
    try std.testing.expectEqualStrings(key1, "key");
    try std.testing.expectEqualStrings(value1, "value");

    const key2, const value2 = try kvFormat("key11 Value");
    try std.testing.expectEqualStrings(key2, "key11");
    try std.testing.expectEqualStrings(value2, "Value");

    try std.testing.expect(kvFormat("key") == error.MissingTokens);
}

test "advanced compare" {
    try std.testing.expect(advancedCompare("abc", "abc"));
    try std.testing.expect(!advancedCompare("abc", "abC"));
    try std.testing.expect(!advancedCompare("abc", "abcd"));
    try std.testing.expect(advancedCompare("", ""));
    try std.testing.expect(advancedCompare(
        "this is a long string used for hashing compare",
        "this is a long string used for hashing compare",
    ));
    try std.testing.expect(!advancedCompare(
        "this is a long string used for hashing compare",
        "this is a long string used for hashing comparx",
    ));
}

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}
