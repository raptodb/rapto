//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of flag field.

/// Flag field type represented indicator that signals errors, conditions
/// or common states as boolean (true or false).
const Flag = @This();

const std = @import("std");

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

value: Status,

pub fn fromContent(content: []const u8) error{MismatchType}!Flag {
    if (content.len != 8) return error.MismatchType;
    return .{ .value = .fromContent(content[0..8].*) };
}

pub fn fromValue(value: Status) Flag {
    return .{ .value = value };
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

pub fn serializeContentToWriter(self: Flag, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeInt(u64, @intFromEnum(self.value), .little);
}

test "Flag" {
    const allocator = std.testing.allocator;

    var buf: [8]u8 = undefined;
    var test_writer: std.Io.Writer = .fixed(&buf);

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    try test_writer.writeInt(u64, 0, .little);
    var s: Flag = try .fromContent(test_writer.buffered());
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
