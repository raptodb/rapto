//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of query.

const std = @import("std");

pub const Flags = @import("Query/Flags.zig");
const Query = @This();

// Each field can be accessed directly when
// the query is successfully parsed.
command: Command,
flags: Flags,
args: Args,

/// Parses a Query from a serialized input.
/// The input must follow this layout:
///
/// COMMAND
///   [cmd]
///   A fixed-size command identifier (u8).
///
/// FLAGS
///   Each flag is encoded as:
///     [key][len:u32][value]
///   where:
///     - key   : fixed-size flag identifier (u8)
///     - len   : length of the associated value (u32)
///     - value : raw bytes
///
///   Multiple flags are concatenated sequentially:
///     [flag][flag]...
///
/// ARGS
///   [arg]
///
///   Multiple arguments are concatenated sequentially:
///     [arg][arg]...
///
/// FULL QUERY LAYOUT
///   [COMMAND][len:u32][FLAGS][ARGS]
///
/// All length fields are encoded using the predefined header type.
pub fn parse(
    serialized: []const u8,
) error{ UnknownCommand, MismatchType, UnknownFlag, InvalidFormat }!Query {
    // serialized is always non-empty
    std.debug.assert(serialized.len != 0);
    var reader: std.Io.Reader = .fixed(serialized);

    const raw_command = reader.takeByte() catch return error.InvalidFormat;
    const command: Command = try .fromInt(raw_command);

    const flags_length = reader.takeInt(u32, .little) catch return error.InvalidFormat;
    const raw_flags = reader.take(flags_length) catch return error.InvalidFormat;
    const flags: Flags = if (flags_length == 0) .{} else try .parse(raw_flags);

    return .{
        .command = command,
        .flags = flags,
        .args = .init(serialized[reader.seek..]),
    };
}

pub const Command = enum(u8) {
    PING = 0,

    // CRUD operations
    SET = 1,
    GET = 2,
    UPDATE = 3,
    DEL = 4,

    // ordered by insertion, do not
    // reorder or change values to
    // maintain compatibility across versions
    COPY,
    RENAME,
    COUNT,
    TYPE,
    LIST,
    EXIST,
    ERASE,
    DOWN = std.math.maxInt(u8),

    fn fromInt(int: u8) error{UnknownCommand}!Command {
        return std.enums.fromInt(Command, int) orelse error.UnknownCommand;
    }

    fn serializeToWriter(self: Command, writer: *std.Io.Writer) error{WriteFailed}!void {
        return writer.writeByte(@intFromEnum(self));
    }
};

pub const Args = struct {
    reader: std.Io.Reader,

    fn init(args: []const u8) Args {
        return .{ .reader = .fixed(args) };
    }

    /// Iterates the next argument in the arguments.
    /// This method, reads firstly the length header, next
    /// reads the argument. The format of reading is:
    /// [length header][argument]
    pub fn next(self: *Args) ?[]const u8 {
        const length = self.reader.takeInt(u32, .little) catch return null;
        return self.reader.take(length) catch null;
    }
};

pub fn serializeToWriter(
    writer: *std.Io.Writer,
    command: Query.Command,
    flags: Query.Flags,
    args: []const []const u8,
) error{WriteFailed}!void {
    try command.serializeToWriter(writer);

    // reserve header, writer is derived from std.Io.Writer.Allocating
    const start_header = writer.end;
    // advancing to reserve length-prefix header for flags
    try writer.writeInt(u32, 0, .little);
    const start_flags = writer.end;
    try flags.serializeToWriter(writer);
    const flags_length = writer.end - start_flags;
    // write the actual length of flags in the reserved header
    std.mem.writeInt(
        u32,
        writer.buffer[start_header .. start_header + @sizeOf(u32)][0..@sizeOf(u32)],
        @truncate(flags_length),
        .little,
    );

    for (args) |arg| {
        try writer.writeInt(u32, @truncate(arg.len), .little);
        try writer.writeAll(arg);
    }
}
            std.meta.activeTag(case.flags.by),
            std.meta.activeTag(q.flags.by),
        );

        switch (case.flags.by) {
            .any => {},
            .index => |v| try std.testing.expectEqual(v, q.flags.by.index),
            .range => |v| {
                try std.testing.expectEqual(v.from, q.flags.by.range.from);
                try std.testing.expectEqual(v.to, q.flags.by.range.to);
            },
            .key => |v| try std.testing.expectEqualSlices(u8, v, q.flags.by.key),
        }

        var args = q.args;
        for (case.args) |expected| {
            const got = args.next() orelse return error.TestFailure;
            try std.testing.expectEqualSlices(u8, expected, got);
        }
        try std.testing.expectEqual(null, args.next());
    }

    {
        var buffer: [16]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        try writer.writeByte(200);
        try writer.writeInt(u32, 0, .little);

        try std.testing.expectError(
            error.UnknownCommand,
            Query.parse(writer.buffered()),
        );
    }

    {
        var buffer: [16]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        try writer.writeByte(@intFromEnum(Query.Command.GET));
        try writer.writeInt(u32, 1, .little);
        try writer.writeByte(255);

        try std.testing.expectError(
            error.UnknownFlag,
            Query.parse(writer.buffered()),
        );
    }

    {
        var buffer: [16]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        try writer.writeByte(@intFromEnum(Query.Command.GET));
        try writer.writeInt(u32, 100, .little);

        try std.testing.expectError(
            error.InvalidFormat,
            Query.parse(writer.buffered()),
        );
    }

    {
        var buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        try writer.writeByte(@intFromEnum(Query.Command.GET));
        try writer.writeInt(u32, 0, .little);

        try writer.writeInt(u32, 4, .little);
        try writer.writeAll(&[_]u8{ 0, 1, 2, 255 });

        const q = try Query.parse(writer.buffered());
        var args = q.args;

        const v = args.next().?;
        try std.testing.expectEqual(@as(usize, 4), v.len);
        try std.testing.expectEqual(@as(u8, 255), v[3]);
    }
}
