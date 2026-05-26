//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of query.

const Query = @This();

const std = @import("std");
const frames = @import("frames.zig");
const assert = std.debug.assert;

pub const Flags = @import("Query/Flags.zig");
pub const Error = error{ UnknownCommand, UnknownFlag, InvalidFormat };

command: Command,
flags: Flags,
/// Best accessed via `.argsIterator()`
args: []const u8,

pub const Command = enum(u8) {
    ping = 0,

    // CRUD operations
    set = 1,
    get = 2,
    update = 3,
    del = 4,

    // ordered by insertion, do not
    // reorder or change values to
    // maintain compatibility across versions
    copy,
    rename,
    count,
    type,
    list,
    exist,
    erase,
    down = std.math.maxInt(u8),

    fn parse(int: u8) error{UnknownCommand}!Command {
        return std.enums.fromInt(Command, int) orelse error.UnknownCommand;
    }

    pub fn kind(self: Command) enum { read, write, control } {
        return switch (self) {
            .set, .update, .del, .copy, .rename, .erase => .write,
            .ping, .get, .count, .type, .list, .exist => .read,
            .down => .control,
        };
    }

    fn serializeToWriter(self: Command, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeByte(@intFromEnum(self));
    }
};

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

    const command: Command = try .parse(reader.takeByte() catch return error.InvalidFormat);

    const length = reader.takeInt(u32, .little) catch
        return error.InvalidFormat;
    if (length > serialized.len - reader.seek)
        return error.InvalidFormat;

    const flags: Flags = try .parseFromReader(&reader, length);

    assert(reader.seek <= serialized.len);

    return .{
        .command = command,
        .flags = flags,
        .args = serialized[reader.seek..],
    };
}

pub fn argsIterator(self: *const Query) frames.Iterator {
    return .init(self.args);
}

pub fn isEqualTo(self: *const Query, query: *const Query) bool {
    if (self.command != query.command) return false;

    if (!self.flags.isEqualTo(query.flags)) return false;

    var self_args = self.argsIterator();
    var args = query.argsIterator();
    while (true) {
        const self_arg = self_args.next();
        const arg = args.next();
        if (self_arg == null and arg == null) return true;

        if (self_arg != null and arg != null) {
            if (!std.mem.eql(u8, self_arg.?, arg.?)) return false;
        } else return false;

    }

    return true;
}

/// This function is used for tests.
pub fn serializeToWriter(
    writer: *std.Io.Writer,
    command: Query.Command,
    flags: Query.Flags,
    args: []const []const u8,
) std.Io.Writer.Error!void {
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
