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

/// Custom integer parsing with
/// default i64 type and MismatchType error.
pub inline fn parseIntType(value: []const u8) error{MismatchType}!i64 {
    return std.fmt.parseInt(i64, value, 10) catch return error.MismatchType;
}

/// Custom integer parsing with
/// default u64 type and MismatchType error.
pub inline fn parseUintType(value: []const u8) error{MismatchType}!u64 {
    return std.fmt.parseInt(u64, value, 10) catch return error.MismatchType;
}

/// Custom decimal parsing with
/// default f64 type and MismatchType error.
pub inline fn parseDecimalType(value: []const u8) error{MismatchType}!f64 {
    return std.fmt.parseFloat(f64, value) catch return error.MismatchType;
}

/// Custom string parsing with MismatchType
/// error. Removes incapsulation of "" and returns it slice.
pub inline fn parseStringType(value: []const u8) []const u8 {
    return value[1 .. value.len - 1];
}

/// Appends item to std.ArrayList with growing of 1.
pub inline fn appendNoGrowing(
    comptime T: type,
    allocator: std.mem.Allocator,
    array: *std.ArrayList(T),
    item: T,
) error{OutOfMemory}!void {
    try array.ensureTotalCapacityPrecise(allocator, array.items.len + 1);
    array.appendAssumeCapacity(item);
}

/// Parses enum value type from string.
pub fn valueTypeFromSerialized(noalias value: []const u8) error{TypeOverflow}!FieldType {
    // check if value is string if
    // it is encapsulated with ""
    if (std.mem.startsWith(u8, value, "\"") and std.mem.endsWith(u8, value, "\"")) {
        if (value.len > std.math.maxInt(u32)) {
            @branchHint(.unlikely);
            return error.TypeOverflow;
        }

        return .string;
    }
    // check if value is decimal if
    // contains a dot
    else if (std.mem.indexOfScalar(u8, value, '.') != null)
        return .decimal;
    // probably a integer
    return .integer;
}

/// Default hash algorithm with xxHash3.
inline fn hash(noalias value: []const u8) u64 {
    return std.hash.XxHash3.hash(0, value);
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
    else if (hash(a) != hash(b)) {
        @branchHint(.likely);
        return false;
    }

    // if hashes are equals, compare
    else return std.mem.eql(u8, a, b);
}

/// Split a text with space separator.
pub inline fn kvFormat(args: []const u8) error{MissingTokens}!struct { []const u8, []const u8 } {
    const sep = std.mem.indexOfScalar(u8, args, ' ') orelse return error.MissingTokens;
    return .{ args[0..sep], args[sep + 1 ..] };
}

/// Alias of std.Thread.spawn. Just abbreviated and adapted to Rapto.
pub const spawn = struct {
    fn inner(comptime func: anytype, args: anytype) error{ThreadError}!std.Thread {
        return std.Thread.spawn(.{}, func, args) catch return error.ThreadError;
    }
}.inner;

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
