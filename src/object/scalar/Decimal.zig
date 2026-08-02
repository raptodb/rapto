//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of decimal value.

/// Decimal value type represents double-precision floating-point (FP64).
/// This implementation is more efficient for decimal calculations.
const Decimal = @This();

const std = @import("std");

content: [8]u8 = undefined,

pub fn fromContent(content: []const u8) error{MismatchType}!Decimal {
    if (content.len != 8) return error.MismatchType;
    return .{ .content = content[0..8].* };
}

pub fn fromValue(value: f64) Decimal {
    return .{ .content = @bitCast(value) };
}

pub fn set(self: *Decimal, content: []const u8) error{MismatchType}!void {
    if (content.len != 8) return error.MismatchType;
    self.content = content[0..8].*;
}

pub fn dupe(self: Decimal) Decimal {
    return self;
}

pub fn get(self: Decimal) f64 {
    return @bitCast(self.content);
}

pub fn len(_: Decimal) u64 {
    return @sizeOf(f64);
}

pub fn add(self: *Decimal, value: f64) error{MathOverflow}!void {
    const updated_value = self.get() + value;
    if (!std.math.isFinite(updated_value))
        return error.MathOverflow;

    self.content = @bitCast(updated_value);
}

pub fn isApproxEqualTo(self: Decimal, value: f64) bool {
    return std.math.approxEqAbs(f64, self.get(), value, 1e-12);
}

pub fn serializeContentToWriter(self: Decimal, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(self.content[0..]);
}

test "Decimal" {
    const allocator = std.testing.allocator;

    var buf: [8]u8 = undefined;
    var test_writer: std.Io.Writer = .fixed(&buf);

    try test_writer.writeAll(@as([8]u8, @bitCast(@as(f64, 3.14)))[0..]);
    var s: Decimal = try .fromContent(test_writer.buffered());

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
