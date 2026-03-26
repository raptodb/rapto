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
//! It contains the implementation of point field.

const std = @import("std");

const Decimal = @import("../scalar.zig").Decimal;

/// Point field type represented as spatial coordinates with
/// x, y and z decimal axes.
pub const Point = struct {
    value: *Axis,

    pub const Axis = struct {
        x: Decimal,
        y: Decimal,
        z: Decimal,

        pub fn parse(serialized: []const u8) error{ InvalidFormat, MismatchType }!Axis {
            if (serialized.len != (Decimal{}).len() * 3) return error.InvalidFormat;

            return .{
                .x = try .init(serialized[0..8]),
                .y = try .init(serialized[8..16]),
                .z = try .init(serialized[16..24]),
            };
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        content: []const u8,
    ) error{ OutOfMemory, InvalidFormat, MismatchType }!Point {
        const axis_ptr = try allocator.create(Axis);
        errdefer allocator.destroy(axis_ptr);

        axis_ptr.* = try .parse(content);
        return .{ .value = axis_ptr };
    }

    pub fn set(self: Point, content: []const u8) error{ InvalidFormat, MismatchType }!void {
        self.value.* = try .parse(content);
    }

    pub fn get(self: Point) Axis {
        return self.value.*;
    }

    pub fn len(_: Point) u64 {
        return @sizeOf(Axis);
    }

    pub fn deinit(self: Point, allocator: std.mem.Allocator) void {
        allocator.destroy(self.value);
    }

    pub fn translate(self: Point, delta: Axis) error{Overflow}!void {
        const dx = delta.x.get();
        const dy = delta.y.get();
        const dz = delta.z.get();

        try self.value.x.add(dx);
        try self.value.y.add(dy);
        try self.value.z.add(dz);
    }

    pub fn serializeContentToWriter(self: Point, writer: *std.Io.Writer) error{WriteFailed}!void {
        try self.value.x.serializeContentToWriter(writer);
        try self.value.y.serializeContentToWriter(writer);
        try self.value.z.serializeContentToWriter(writer);
    }
};

test "Point" {
    const allocator = std.testing.allocator;

    var buf: [24]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try writer.writeInt(u64, @bitCast(@as(f64, -10)), .little);
    try writer.writeInt(u64, @bitCast(@as(f64, 2.333)), .little);
    try writer.writeInt(u64, @bitCast(@as(f64, 3000000.2)), .little);

    var p: Point = try .init(allocator, writer.buffered());
    defer p.deinit(allocator);

    try std.testing.expect(p.len() == 24);

    var axis = p.get();
    try std.testing.expect(axis.x.get() == -10);
    try std.testing.expect(axis.y.get() == 2.333);
    try std.testing.expect(axis.z.get() == 3000000.2);

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    try p.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(writer.buffered(), allocating.written());

    _ = writer.consumeAll();
    try writer.writeInt(u64, @bitCast(@as(f64, 10)), .little);
    try writer.writeInt(u64, @bitCast(@as(f64, 20)), .little);
    try writer.writeInt(u64, @bitCast(@as(f64, 30)), .little);

    try p.set(writer.buffered());

    axis = p.get();
    try std.testing.expect(axis.x.get() == 10);
    try std.testing.expect(axis.y.get() == 20);
    try std.testing.expect(axis.z.get() == 30);

    var delta_buf: [24]u8 = undefined;
    var delta_writer: std.Io.Writer = .fixed(&delta_buf);

    try delta_writer.writeInt(u64, @bitCast(@as(f64, 5)), .little);
    try delta_writer.writeInt(u64, @bitCast(@as(f64, 6)), .little);
    try delta_writer.writeInt(u64, @bitCast(@as(f64, 7)), .little);

    var delta: Point = try .init(allocator, delta_writer.buffered());
    defer delta.deinit(allocator);

    try p.translate(delta.get());

    axis = p.get();
    try std.testing.expect(axis.x.get() == 15);
    try std.testing.expect(axis.y.get() == 26);
    try std.testing.expect(axis.z.get() == 37);

    _ = delta_writer.consumeAll();
    try delta_writer.writeInt(u64, @bitCast(@as(f64, -5)), .little);
    try delta_writer.writeInt(u64, @bitCast(@as(f64, -6)), .little);
    try delta_writer.writeInt(u64, @bitCast(@as(f64, -7)), .little);

    try delta.set(delta_writer.buffered());
    try p.translate(delta.get());

    axis = p.get();
    try std.testing.expect(axis.x.get() == 10);
    try std.testing.expect(axis.y.get() == 20);
    try std.testing.expect(axis.z.get() == 30);

    _ = delta_writer.consumeAll();
    try delta_writer.writeInt(u64, @bitCast(@as(f64, 100)), .little);
    try delta_writer.writeInt(u64, @bitCast(@as(f64, -50)), .little);
    try delta_writer.writeInt(u64, @bitCast(@as(f64, 0)), .little);

    try delta.set(delta_writer.buffered());
    try p.translate(delta.get());

    axis = p.get();
    try std.testing.expect(axis.x.get() == 110);
    try std.testing.expect(axis.y.get() == -30);
    try std.testing.expect(axis.z.get() == 30);

    _ = writer.consumeAll();
    try writer.writeInt(u64, @bitCast(@as(f64, std.math.inf(f64))), .little);
    try writer.writeInt(u64, @bitCast(@as(f64, 0)), .little);
    try writer.writeInt(u64, @bitCast(@as(f64, 0)), .little);
    try p.set(writer.buffered());

    _ = delta_writer.consumeAll();
    try delta_writer.writeInt(u64, @bitCast(@as(f64, 1)), .little);
    try delta_writer.writeInt(u64, @bitCast(@as(f64, 0)), .little);
    try delta_writer.writeInt(u64, @bitCast(@as(f64, 0)), .little);
    try delta.set(delta_writer.buffered());

    try std.testing.expectError(
        error.Overflow,
        p.translate(delta.get()),
    );
}
