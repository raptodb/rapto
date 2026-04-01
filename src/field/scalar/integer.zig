//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of integer field.

const std = @import("std");

/// Integer field type represents signed integer of 64 bits.
/// This implementation is more efficient for integer calculations.
/// Useful for counters, timestamps and identifiers.
const Integer = @This();

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

pub fn add(self: *Integer, value: i64) error{MathOverflow}!void {
    const updated_value = std.math.add(i64, self.get(), value) catch return error.MathOverflow;
    std.mem.writeInt(i64, self.raw[0..], updated_value, .little);
}

pub fn serializeContentToWriter(self: Integer, writer: *std.Io.Writer) error{WriteFailed}!void {
    try writer.writeAll(self.raw[0..]);
}

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
