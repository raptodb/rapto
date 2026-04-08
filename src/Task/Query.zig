//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of query.

const Query = @This();

const std = @import("std");
const assert = std.debug.assert;

pub const Flags = @import("Query/Flags.zig");
pub const ParseError = error{ UnknownCommand, MismatchType, UnknownFlag, InvalidFormat };

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
///   Each arg is encoded as:
///     [len:u32][arg]...
///
///   Multiple arguments are concatenated sequentially:
///     [arg][arg]...
///
/// FULL QUERY LAYOUT
///   [COMMAND][len:u32][FLAGS][ARGS]
///
/// All length fields are encoded using the predefined header type.
pub fn parse(serialized: []const u8) ParseError!Query {
    var reader: std.Io.Reader = .fixed(serialized);
    const reader_ptr = &reader;

    const command: Command = try .parseFromReader(reader_ptr);

    const length = reader.takeInt(u32, .little) catch
        return error.InvalidFormat;
    const flags: Flags = try .parseFromReader(reader_ptr, length);

    assert(reader.seek <= serialized.len);

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

    fn parseFromReader(reader: *std.Io.Reader) error{ InvalidFormat, UnknownCommand }!Command {
        const int = reader.takeByte() catch return error.InvalidFormat;
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

// This function is used for tests.
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
