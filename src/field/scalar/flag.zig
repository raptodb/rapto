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
//! It contains the implementation of flag field.

const std = @import("std");

/// Flag field type represented indicator that signals errors, conditions
/// or common states as boolean (true or false).
pub const Flag = struct {
    value: Status,

    pub const Status = enum(u64) {
        false = 0,
        true = 1,

        null,
        @"error",
        pending,

        unknown,

        pub fn fromContent(content: [8]u8) Status {
            const integer: u64 = std.mem.readInt(u64, &content, .little);
            return std.enums.fromInt(Status, integer) orelse .unknown;
        }
    };

    pub fn init(content: []const u8) error{MismatchType}!Flag {
        if (content.len != 8) return error.MismatchType;
        return .{ .value = .fromContent(content[0..8].*) };
    }

    pub fn set(self: *Flag, content: []const u8) error{MismatchType}!void {
        if (content.len != 8) return error.MismatchType;
        self.value = .fromContent(content[0..8].*);
    }

    pub fn get(self: Flag) Status {
        return self.value;
    }

    pub fn len(_: Flag) u64 {
        return @sizeOf(u64);
    }

    pub fn serializeContentToWriter(self: Flag, writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u64, @intFromEnum(self.value), .little);
    }
};

test "Flag" {
    const allocator = std.testing.allocator;

    var buf: [8]u8 = undefined;
    var test_writer: std.Io.Writer = .fixed(&buf);

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    try test_writer.writeInt(u64, 0, .little);
    var s: Flag = try .init(test_writer.buffered());
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(test_writer.buffered(), allocating.written());
    try std.testing.expect(s.get() == .false);

    _ = test_writer.consumeAll();
    try test_writer.writeInt(u64, 1, .little);
    try s.set(test_writer.buffered());
    allocating.clearRetainingCapacity();
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(test_writer.buffered(), allocating.written());
    try std.testing.expect(s.get() == .true);

    _ = test_writer.consumeAll();
    try test_writer.writeInt(u64, 2, .little);
    try s.set(test_writer.buffered());
    try std.testing.expect(s.get() == .null);

    _ = test_writer.consumeAll();
    try test_writer.writeInt(u64, 3, .little);
    try s.set(test_writer.buffered());
    allocating.clearRetainingCapacity();
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(test_writer.buffered(), allocating.written());
    try std.testing.expect(s.get() == .@"error");

    _ = test_writer.consumeAll();
    try test_writer.writeInt(u64, 4, .little);
    try s.set(test_writer.buffered());
    allocating.clearRetainingCapacity();
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(test_writer.buffered(), allocating.written());
    try std.testing.expect(s.get() == .pending);

    _ = test_writer.consumeAll();
    try test_writer.writeInt(u64, 5, .little);
    try s.set(test_writer.buffered());
    allocating.clearRetainingCapacity();
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(test_writer.buffered(), allocating.written());
    try std.testing.expect(s.get() == .unknown);

    _ = test_writer.consumeAll();
    try test_writer.writeInt(u64, std.math.maxInt(u64), .little);
    try s.set(test_writer.buffered());
    allocating.clearRetainingCapacity();
    try s.serializeContentToWriter(&allocating.writer);
    _ = test_writer.consumeAll();
    try test_writer.writeInt(u64, 5, .little);
    try std.testing.expectEqualStrings(test_writer.buffered(), allocating.written());
    try std.testing.expect(s.get() == .unknown);
    try std.testing.expect(s.len() == 8);
}
