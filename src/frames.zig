//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of frames reader and writer.
//!
//! Frames are represented as chain of [length-prefix][content].
//! This is a global format to read and deserialize messages from client, or
//! serialize and write message to client. It also used by values of Memory.

const std = @import("std");
const assert = std.debug.assert;

pub const Iterator = IteratorType(u32);
pub const ExtendedIterator = IteratorType(u64);

pub const Builder = BuilderType(u32);
pub const ExtendedBuilder = BuilderType(u64);

pub fn IteratorType(comptime HeaderType: type) type {
    return struct {
        const Self = @This();

        pub const Header = HeaderType;

        frames: []const u8,
        seek: u64,

        pub fn init(frames: []const u8) Self {
            return .{ .frames = frames, .seek = 0 };
        }

        pub fn next(self: *Self) ?[]const u8 {
            const header_size = @sizeOf(Header);

            if (self.remaining() < header_size) return null;
            const len = std.mem.readInt(
                Header,
                self.frames[self.seek .. self.seek + header_size][0..header_size],
                .little,
            );
            self.seek += header_size;

            if (self.remaining() < len) return null;
            const content = self.frames[self.seek .. self.seek + len];
            self.seek += len;

            return content;
        }

        pub fn skip(self: *Self, n_frames: u64) void {
            for (0..n_frames) |_| _ = self.next() orelse return;
        }

        fn remaining(self: Self) u64 {
            assert(self.seek <= self.frames.len);
            return self.frames.len - self.seek;
        }
    };
}

pub fn BuilderType(comptime HeaderType: type) type {
    return struct {
        const Self = @This();

        pub const Header = HeaderType;

        writer: *std.Io.Writer,
        begin_offset: u64,

        /// Assumes writer is derived from `std.Io.Writer.Allocating`.
        pub fn begin(writer: *std.Io.Writer) std.mem.Allocator.Error!Self {
            const header_offset = writer.end;
            append(writer, Header, &.{}) catch |err| return switch (err) {
                // Assuming writer is derived from std.Io.Writer.Allocating,
                // write fails are caused by OOM.
                error.WriteFailed => error.OutOfMemory,
            };
            return .{ .writer = writer, .begin_offset = header_offset };
        }

        pub fn end(self: Self) void {
            const header_size = @sizeOf(Header);

            assert(self.writer.buffer.len >= header_size);
            assert(self.writer.buffer.len >= self.begin_offset + header_size);
            assert(self.writer.end >= self.begin_offset);

            const size_from_begin = self.writer.end - self.begin_offset - header_size;

            assert(size_from_begin <= std.math.maxInt(Header));

            const ptr_buf =
                self.writer.buffer[self.begin_offset .. self.begin_offset + header_size].ptr;

            std.mem.writeInt(
                Header,
                ptr_buf[0..header_size],
                @intCast(size_from_begin),
                .little,
            );
        }
    };
}

/// Same behavior of `Builder.begin` -> `Builder.end` cycle.
/// This don't require `std.Io.Writer.Allocating` as default
/// writer. Often used to avoid builder cycle when buf is known.
pub fn append(
    writer: *std.Io.Writer,
    comptime Header: type,
    buf: []const u8,
) std.Io.Writer.Error!void {
    var header: [@sizeOf(Header)]u8 = undefined;
    std.mem.writeInt(Header, &header, @intCast(buf.len), .little);
    // Builds buffer with length-prefix.
    var vec: [2][]const u8 = .{ &header, buf };
    return writer.writeVecAll(&vec);
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
