//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of point field.

/// Point field type represented as spatial
/// coordinates with x, y and z decimal axes.
const Point = @This();

const std = @import("std");

const Decimal = @import("../scalar.zig").Decimal;

pub const Axis = struct {
    x: Decimal,
    y: Decimal,
    z: Decimal,

    pub fn parse(content: []const u8) error{ InvalidFormat, MismatchType }!Axis {
        if (content.len != (Decimal{}).len() * 3) return error.InvalidFormat;

        return .{
            .x = try .initFromContent(content[0..8]),
            .y = try .initFromContent(content[8..16]),
            .z = try .initFromContent(content[16..24]),
        };
    }
};

value: *Axis,

pub fn initFromContent(
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

pub fn translate(self: Point, delta: Axis) error{MathOverflow}!void {
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

test "Point" {
    const allocator = std.testing.allocator;

    var buf: [24]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try writer.writeInt(u64, @bitCast(@as(f64, -10)), .little);
    try writer.writeInt(u64, @bitCast(@as(f64, 2.333)), .little);
    try writer.writeInt(u64, @bitCast(@as(f64, 3000000.2)), .little);

    var p: Point = try .initFromContent(allocator, writer.buffered());
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

    var delta: Point = try .initFromContent(allocator, delta_writer.buffered());
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
        error.MathOverflow,
        p.translate(delta.get()),
    );
}
