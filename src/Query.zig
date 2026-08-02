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

pub const Command = enum(u8) {
    ping = 0,

    // ordered by insertion, do not reorder
    // or change fields to maintain
    // compatibility across versions
    set,
    append,
    insert,
    put,
    get,
    cget,
    len,
    count,
    ccount,
    del,
    cdel,
    pop,
    cpop,
    copy,
    rename,
    type,
    ctype,
    keys,
    down = std.math.maxInt(u8),

    pub fn deserialize(int: u8) error{UnknownCommand}!Command {
        return std.enums.fromInt(Command, int) orelse error.UnknownCommand;
    }

    pub fn parse(human_readable_cmd: []const u8) error{UnknownCommand}!Command {
        return std.meta.stringToEnum(Command, human_readable_cmd) orelse error.UnknownCommand;
    }

    pub fn kind(self: Command) enum { read, write, control } {
        return switch (self) {
            .set, .append, .insert, .put, .del, .cdel, .pop, .cpop, .copy, .rename => .write,
            // Commands that does not modify memory.
            .ping, .get, .cget, .len, .count, .ccount, .type, .ctype, .keys => .read,
            .down => .control,
        };
    }

    pub fn serializeToWriter(self: Command, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeByte(@intFromEnum(self));
    }
};

pub const Args = struct {
    content: []const u8,

    pub fn serializeToWriter(self: Args, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeAll(self.content);
    }

    pub fn iterator(self: Args) frames.Iterator {
        return .init(self.content);
    }
};

pub const Serializer = struct {
    /// Assuming writer is derived from std.Io.Writer.Allocating.
    pub fn serialize(
        writer: *std.Io.Writer,
        command: Command,
        flags: Flags,
    ) std.mem.Allocator.Error!void {
        command.serializeToWriter(writer) catch |err| return switch (err) {
            error.WriteFailed => error.OutOfMemory,
        };
        flags.serializeToWriter(writer) catch |err| return switch (err) {
            error.WriteFailed => error.OutOfMemory,
        };
    }

    /// Assuming writer is derived from std.Io.Writer.Allocating.
    pub fn append(writer: *std.Io.Writer, arg: []const []const u8) std.mem.Allocator.Error!void {
        var builder: frames.Builder = try .begin(writer);
        defer builder.end();
        _ = writer.writeVec(arg) catch |err| return switch (err) {
            error.WriteFailed => error.OutOfMemory,
        };
    }
};

pub const DeserializeError = error{ UnknownCommand, InvalidFormat };
pub const ParseError = std.mem.Allocator.Error || error{ UnknownCommand, InvalidFormat };

command: Command,
flags: Flags,
args: Args,

/// Deserializes a Query from a serialized input.
/// The input must follow this layout:
///
/// COMMAND
///   [cmd]
///   A fixed-size command identifier (u8).
///
/// FLAGS
///   [has-default-flags:bool][flags]
///   Each flag is encoded as:
///     [tag bitmask][value][value]...
///   where:
///     - tag bitmask : bitmask of all enabled flags (u64)
///     - value       : value for each flag
///
/// ARGS
///   Each arg is encoded as frame:
///     [len(arg):u32][arg]...
///
///   Multiple arguments are concatenated sequentially:
///     [arg][arg]...
///
/// FULL QUERY LAYOUT
///   [COMMAND][FLAGS][ARGS]
///
/// All length-prefixed field are encoded through Frames.
pub fn deserialize(serialized: []const u8) DeserializeError!Query {
    var reader: std.Io.Reader = .fixed(serialized);

    const command: Command = try .deserialize(reader.takeByte() catch return error.InvalidFormat);
    const flags: Flags = try .deserializeFromReader(&reader);
    const args: Args = .{ .content = serialized[reader.seek..] };

    assert(reader.seek <= serialized.len);

    return .{ .command = command, .flags = flags, .args = args };
}

pub fn isEqualTo(self: *const Query, query: *const Query) bool {
    if (self.command != query.command) return false;
    if (!self.flags.isEqualTo(query.flags)) return false;
    return std.mem.eql(u8, self.args.content, query.args.content);
}

pub fn serializeToWriter(self: *const Query, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try self.command.serializeToWriter(writer);
    try self.flags.serializeToWriter(writer);
    try self.args.serializeToWriter(writer);
}

pub fn testIsEqualTo(actual: []const u8, expected: []const []const u8) bool {
    var i: u64 = 0;
    var actual_iter: frames.Iterator = .init(actual);
    while (true) : (i += 1) {
        const actual_part = actual_iter.next();
        const expected_part = if (i >= expected.len) null else expected[i];

        if (actual_part == null and expected_part == null) return true;
        if (actual_part != null and expected_part != null) {
            if (std.mem.eql(u8, actual_part.?, expected_part.?)) continue;
        }

        return false;
    }
}

test "Query" {
    const TestQueryLayout = struct {
        command: Query.Command,
        flags: Query.Flags,
        args: []const []const u8,
    };

    const cases = [_]TestQueryLayout{
        .{
            .command = .ping,
            .flags = .{},
            .args = &.{},
        },
        .{
            .command = .get,
            .flags = .{},
            .args = &.{"key"},
        },
        .{
            .command = .cget,
            .flags = .{},
            .args = &.{ "collection", "key" },
        },
        .{
            .command = .insert,
            .flags = .{},
            .args = &.{ "key", "value" },
        },
        .{
            .command = .insert,
            .flags = .{},
            .args = &.{""},
        },
        .{
            .command = .insert,
            .flags = .{},
            .args = &.{ "", "" },
        },
        .{
            .command = .keys,
            .flags = .{},
            .args = &.{},
        },
        .{
            .command = .keys,
            .flags = .{
                .limit = .init(1000),
            },
            .args = &.{},
        },
        .{
            .command = .rename,
            .flags = .{},
            .args = &.{ "old", "new" },
        },
        .{
            .command = .del,
            .flags = .{},
            .args = &.{},
        },
        .{
            .command = .count,
            .flags = .{},
            .args = &.{"sessions"},
        },
        .{
            .command = .copy,
            .flags = .{},
            .args = &.{ "a", "b", "c", "d", "e", "f", "g" },
        },
        .{
            .command = .insert,
            .flags = .{},
            .args = &.{
                "hello\nworld",
                "value\t123",
            },
        },
        .{
            .command = .insert,
            .flags = .{},
            .args = &.{ "ciao", "你好", "🚀" },
        },
        .{
            .command = .set,
            .flags = .{},
            .args = &.{
                &@as([128]u8, @splat('a')),
            },
        },
        .{
            .command = .down,
            .flags = .{},
            .args = &.{},
        },
    };

    for (cases) |expected| {
        var buffer: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        try expected.command.serializeToWriter(&writer);
        try expected.flags.serializeToWriter(&writer);
        for (expected.args) |arg| {
            var builder: frames.Builder = try .begin(&writer);
            defer builder.end();
            try writer.writeAll(arg);
        }

        const deserialized: Query = try .deserialize(writer.buffered());

        try std.testing.expect(deserialized.command == expected.command);
        try std.testing.expect(deserialized.flags.isEqualTo(expected.flags));
        try std.testing.expect(testIsEqualTo(deserialized.args.content, expected.args));
    }
}
