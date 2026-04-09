//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of decimal field.

const std = @import("std");

/// Decimal field type represents double-precision floating-point (FP64).
/// This implementation is more efficient for decimal calculations.
const Decimal = @This();

raw: [8]u8 = undefined,

pub fn initFromContent(content: []const u8) error{MismatchType}!Decimal {
    if (content.len != 8) return error.MismatchType;
    return .{ .raw = content[0..8].* };
}

pub fn initFromValue(value: f64) Decimal {
    return .{ .raw = @bitCast(value) };
}

pub fn set(self: *Decimal, content: []const u8) error{MismatchType}!void {
    if (content.len != 8) return error.MismatchType;
    self.raw = content[0..8].*;
}

pub fn getContent(self: Decimal) []const u8 {
    return self.raw[0..];
}

pub fn get(self: Decimal) f64 {
    return @bitCast(self.raw);
}

pub fn len(_: Decimal) u64 {
    return @sizeOf(f64);
}

pub fn add(self: *Decimal, value: f64) error{MathOverflow}!void {
    const updated_value = self.get() + value;
    if (!std.math.isFinite(updated_value))
        return error.MathOverflow;

    self.raw = @bitCast(updated_value);
}

pub fn isApproxEqualTo(self: Decimal, value: f64) bool {
    return std.math.approxEqAbs(f64, self.get(), value, 1e-12);
}

pub fn serializeContentToWriter(self: Decimal, writer: *std.Io.Writer) error{WriteFailed}!void {
    try writer.writeAll(self.raw[0..]);
}

test "Decimal" {
    const allocator = std.testing.allocator;

    var buf: [8]u8 = undefined;
    var test_writer: std.Io.Writer = .fixed(&buf);

    try test_writer.writeAll(@as([8]u8, @bitCast(@as(f64, 3.14)))[0..]);
    var s: Decimal = try .initFromContent(test_writer.buffered());

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
