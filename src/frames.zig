//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of frames reader and writer.

/// Frames are represented as chain of [length-prefix][content].
/// This is a global format to read messages from client, as
/// pipeline (with zero-copy `Iterator`) or write message to
/// send (with `Builder`). It also used by fields.

const std = @import("std");
const assert = std.debug.assert;

pub const framePrefixType = u32;

pub const Iterator = struct {
    reader: std.Io.Reader,

    pub fn init(frames: []const u8) Iterator {
        return .{ .reader = .fixed(frames) };
    }

    pub fn next(self: *Iterator) ?[]const u8 {
        const len = self.reader.takeInt(framePrefixType, .little) catch return null;
        return self.reader.take(len) catch return null;
    }
};

pub const Builder = struct {
    writer: *std.Io.Writer,
    begin_offset: u64,

    pub fn begin(writer: *std.Io.Writer) error{WriteFailed}!Builder {
        const header_offset = writer.end;
        try writer.writeInt(framePrefixType, 0, .little);
        return .{ .writer = writer, .begin_offset = header_offset };
    }

    pub fn end(self: *Builder) void {
        assert(self.writer.buffer.len >= @sizeOf(framePrefixType));
        assert(self.writer.buffer.len >= self.begin_offset + @sizeOf(framePrefixType));
        assert(self.writer.end >= self.begin_offset);

        const prefix_size = @sizeOf(framePrefixType);
        const size_from_begin = self.writer.end - self.begin_offset - prefix_size;

        assert(size_from_begin <= std.math.maxInt(framePrefixType));

        const ptr_buf =
            self.writer.buffer[self.begin_offset .. self.begin_offset + prefix_size].ptr;

        std.mem.writeInt(
            framePrefixType,
            ptr_buf[0..prefix_size],
            @intCast(size_from_begin),
            .little,
        );
    }
};

test "frames" {
    const allocator = std.testing.allocator;

    const contents: []const []const u8 = &.{
        "first",        "",     "0",
        "third string", "4444", "example",
    };

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();
    var writer = &allocating.writer;

    for (contents) |p| {
        var b: Builder = try .begin(writer);
        try writer.writeAll(p);
        b.end();
    }

    var it: Iterator = .init(allocating.written());
    for (contents) |expected| {
        const next = it.next();
        try std.testing.expect(next != null);
        try std.testing.expectEqualSlices(u8, expected, next.?);
    }

    try std.testing.expect(it.next() == null);
}
