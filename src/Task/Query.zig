//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of query.

const Query = @This();

const std = @import("std");
const frames = @import("../frames.zig");
const assert = std.debug.assert;

pub const Flags = @import("Query/Flags.zig");
pub const Error = error{ UnknownCommand, UnknownFlag, InvalidFormat };

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

command: Command,
flags: Flags,
args: frames.Iterator,

/// Parses a Query from a serialized input.
/// The input must follow this layout:
///
/// COMMAND
///   [cmd]
///   A fixed-size command identifier (u8).
///
/// FLAGS
///   Each flag is encoded as:
///     [tag][value]
///   where:
///     - key   : fixed-size flag identifier (u8)
///     - value : own format per flag
///
///   Multiple flags are concatenated sequentially:
///     [flag][flag]...
///
/// ARGS
///   Each arg is encoded as frame:
///     [len:u32][arg]...
///
///   Multiple arguments are concatenated sequentially:
///     [arg][arg]...
///
/// FULL QUERY LAYOUT
///   [COMMAND][len:u32][FLAGS][ARGS]
///
/// All length fields are encoded using the predefined header type.
pub fn parse(serialized: []const u8) Error!Query {
    var reader: std.Io.Reader = .fixed(serialized);
    const reader_ptr = &reader;

    const command: Command = try .parseFromReader(reader_ptr);

    const length = reader.takeInt(u32, .little) catch
        return error.InvalidFormat;
    if (length > serialized.len - reader.seek)
        return error.InvalidFormat;

    const flags: Flags = try .parseFromReader(reader_ptr, length);

    assert(reader.seek <= serialized.len);

    return .{
        .command = command,
        .flags = flags,
        .args = .init(serialized[reader.seek..]),
    };
}

pub fn isEqualTo(self: *const Query, query: *const Query) bool {
    if (self.command != query.command) return false;

    if (!self.flags.isEqualTo(query.flags)) return false;

    var self_args = self.args;
    var args = query.args;
    while (true) {
        const self_arg = self_args.next();
        const arg = args.next();
        if (self_arg == null and arg == null) return true;

        if (self_arg != null and arg != null) {
            if (!std.mem.eql(u8, self_arg.?, arg.?)) return false;
        }
    }

    return true;
}

/// This function is used for tests.
pub fn serializeToWriter(
    writer: *std.Io.Writer,
    command: Query.Command,
    flags: Query.Flags,
    args: []const []const u8,
) error{WriteFailed}!void {
    try command.serializeToWriter(writer);

    {
        var builder: frames.Builder = try .begin(writer);
        defer builder.end();
        try flags.serializeToWriter(writer);
    }

    for (args) |arg| {
        var builder: frames.Builder = try .begin(writer);
        defer builder.end();
        try writer.writeAll(arg);
    }
}
