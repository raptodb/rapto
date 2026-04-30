//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of frames reader and writer.
//!
//! Frames are represented as chain of [length-prefix][content].
//! This is a global format to read messages from client, as
//! pipeline (with zero-copy `Iterator`) or write message to
//! send (with `Builder`). It also used by fields.

const std = @import("std");
const assert = std.debug.assert;

pub const Iterator = IteratorType(u32);
pub const ExtendedIterator = IteratorType(u64);

pub const Builder = BuilderType(u32);
pub const ExtendedBuilder = BuilderType(u64);

pub fn IteratorType(comptime PrefixType: type) type {
    return struct {
        const Self = @This();

        reader: std.Io.Reader,

        pub fn init(frames: []const u8) Self {
            return .{ .reader = .fixed(frames) };
        }

        pub fn next(self: *Self) ?[]const u8 {
            const len = self.reader.takeInt(PrefixType, .little) catch return null;
            return self.reader.take(len) catch return null;
        }
    };
}

pub fn BuilderType(comptime PrefixType: type) type {
    return struct {
        const Self = @This();

        writer: *std.Io.Writer,
        begin_offset: u64,

        pub fn begin(writer: *std.Io.Writer) std.Io.Writer.Error!Self {
            const header_offset = writer.end;
            try writer.writeInt(PrefixType, 0, .little);
            return .{ .writer = writer, .begin_offset = header_offset };
        }

        pub fn end(self: *Self) void {
            assert(self.writer.buffer.len >= @sizeOf(PrefixType));
            assert(self.writer.buffer.len >= self.begin_offset + @sizeOf(PrefixType));
            assert(self.writer.end >= self.begin_offset);

            const prefix_size = @sizeOf(PrefixType);
            const size_from_begin = self.writer.end - self.begin_offset - prefix_size;

            assert(size_from_begin <= std.math.maxInt(PrefixType));

            const ptr_buf =
                self.writer.buffer[self.begin_offset .. self.begin_offset + prefix_size].ptr;

            std.mem.writeInt(
                PrefixType,
                ptr_buf[0..prefix_size],
                @intCast(size_from_begin),
                .little,
            );
        }
    };
}

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
        var builder: Builder = try .begin(writer);
        defer builder.end();
        try writer.writeAll(p);
    }

    var it: Iterator = .init(allocating.written());
    for (contents) |expected| {
        const next = it.next();
        try std.testing.expect(next != null);
        try std.testing.expectEqualSlices(u8, expected, next.?);
    }

    try std.testing.expect(it.next() == null);
}
