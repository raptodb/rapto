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
//! It contains the implementation of decimal field.

const std = @import("std");

/// Decimal field type represents double-precision floating-point (FP64).
/// This implementation is more efficient for decimal calculations.
pub const Decimal = struct {
    raw: [8]u8 = undefined,

    pub fn init(content: []const u8) error{MismatchType}!Decimal {
        if (content.len != 8) return error.MismatchType;
        return .{ .raw = content[0..8].* };
    }

    pub fn set(self: *Decimal, content: []const u8) error{MismatchType}!void {
        if (content.len != 8) return error.MismatchType;
        self.raw = content[0..8].*;
    }

    pub fn get(self: Decimal) f64 {
        return @bitCast(self.raw);
    }

    pub fn len(_: Decimal) u64 {
        return @sizeOf(f64);
    }

    pub fn add(self: *Decimal, value: f64) error{Overflow}!void {
        const updated_value = self.get() + value;
        if (!std.math.isFinite(updated_value))
            return error.Overflow;

        self.raw = @bitCast(updated_value);
    }

    pub fn isApproxEqualTo(self: Decimal, value: f64) bool {
        return std.math.approxEqAbs(f64, self.get(), value, 1e-12);
    }

    pub fn serializeContentToWriter(self: Decimal, writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.writeAll(self.raw[0..]);
    }
};

test "Decimal" {
    const allocator = std.testing.allocator;

    var buf: [8]u8 = undefined;
    var test_writer: std.Io.Writer = .fixed(&buf);

    try test_writer.writeAll(@as([8]u8, @bitCast(@as(f64, 3.14)))[0..]);
    var s: Decimal = try .init(test_writer.buffered());

    try std.testing.expect(s.len() == 8);
    try std.testing.expect(s.get() == 3.14);

    _ = test_writer.consumeAll();
    try test_writer.writeAll(@as([8]u8, @bitCast(@as(f64, 3.333336)))[0..]);
    try s.set(test_writer.buffered());

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(test_writer.buffered(), allocating.written());
    try std.testing.expect(s.isApproxEqualTo(3.333336));

    try s.add(0.766664);

    _ = test_writer.consumeAll();
    try test_writer.writeAll(@as([8]u8, @bitCast(@as(f64, 4.1)))[0..]);

    allocating.clearRetainingCapacity();
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(test_writer.buffered(), allocating.written());
    try std.testing.expect(s.isApproxEqualTo(4.1));

    try s.add(-0.15);

    _ = test_writer.consumeAll();
    try test_writer.writeAll(@as([8]u8, @bitCast(@as(f64, 3.9499999999999997)))[0..]);

    allocating.clearRetainingCapacity();
    try s.serializeContentToWriter(&allocating.writer);
    // rounding is done client-side
    try std.testing.expectEqualStrings(test_writer.buffered(), allocating.written());
    try std.testing.expect(s.isApproxEqualTo(3.95));
}
