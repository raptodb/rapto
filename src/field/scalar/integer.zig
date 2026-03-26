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
//! It contains the implementation of integer field.

const std = @import("std");

/// Integer field type represents signed integer of 64 bits.
/// This implementation is more efficient for integer calculations.
/// Useful for counters, timestamps and identifiers.
pub const Integer = struct {
    raw: [8]u8 = undefined,

    pub fn init(content: []const u8) error{MismatchType}!Integer {
        if (content.len != 8) return error.MismatchType;
        return .{ .raw = content[0..8].* };
    }

    pub fn set(self: *Integer, content: []const u8) error{MismatchType}!void {
        if (content.len != 8) return error.MismatchType;
        self.raw = content[0..8].*;
    }

    pub fn get(self: Integer) i64 {
        return std.mem.readInt(i64, self.raw[0..], .little);
    }

    pub fn len(_: Integer) u64 {
        return @sizeOf(i64);
    }

    pub fn add(self: *Integer, value: i64) error{Overflow}!void {
        const updated_value = try std.math.add(i64, self.get(), value);
        std.mem.writeInt(i64, self.raw[0..], updated_value, .little);
    }

    pub fn serializeContentToWriter(self: Integer, writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.writeAll(self.raw[0..]);
    }
};

test "Integer" {
    const allocator = std.testing.allocator;

    var buf: [8]u8 = undefined;
    var test_writer: std.Io.Writer = .fixed(&buf);

    try test_writer.writeInt(i64, 100, .little);
    var s: Integer = try .init(&buf);

    try std.testing.expect(s.get() == 100);
    try std.testing.expect(s.len() == 8);

    _ = test_writer.consumeAll();
    try test_writer.writeInt(i64, 120, .little);
    try s.set(test_writer.buffered());

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(test_writer.buffered(), allocating.written());

    try s.add(120);

    _ = test_writer.consumeAll();
    try test_writer.writeInt(i64, 240, .little);

    allocating.clearRetainingCapacity();
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(test_writer.buffered(), allocating.written());

    try s.add(-10);

    _ = test_writer.consumeAll();
    try test_writer.writeInt(i64, 230, .little);

    allocating.clearRetainingCapacity();
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(test_writer.buffered(), allocating.written());

    try s.add(-240);

    _ = test_writer.consumeAll();
    try test_writer.writeInt(i64, -10, .little);

    allocating.clearRetainingCapacity();
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(test_writer.buffered(), allocating.written());

    try s.add(-90);

    _ = test_writer.consumeAll();
    try test_writer.writeInt(i64, -100, .little);

    allocating.clearRetainingCapacity();
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(test_writer.buffered(), allocating.written());
}
