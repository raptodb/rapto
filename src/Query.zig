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
pub const Error = error{ UnknownCommand, UnknownFlag, InvalidFlagUnion, InvalidFormat };

command: Command,
flags: Flags,
/// Best accessed via `.argsIterator()`.
/// Format is equivalent to Frames.
args: []const u8,

pub const Command = enum(u8) {
    ping = 0,

    // CRUD operations
    set = 1,
    get = 2,
    update = 3,
    del = 4,

    // ordered by insertion, do not reorder
    // or change fields to maintain
    // compatibility across versions
    copy,
    rename,
    count,
    type,
    list,
    down = std.math.maxInt(u8),

    fn parse(int: u8) error{UnknownCommand}!Command {
        return std.enums.fromInt(Command, int) orelse error.UnknownCommand;
    }

    pub fn kind(self: Command) enum { read, write, control } {
        return switch (self) {
            .set, .update, .del, .copy, .rename => .write,
            .ping, .get, .count, .type, .list => .read,
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
///   [COMMAND][len(FLAGS):u32][FLAGS][ARGS]
///
/// All length-prefixed field are encoded through Frames.
pub fn parse(serialized: []const u8) Error!Query {
    var reader: std.Io.Reader = .fixed(serialized);

    const command: Command = try .parse(reader.takeByte() catch return error.InvalidFormat);

    const length = reader.takeInt(u32, .little) catch
        return error.InvalidFormat;
    if (length > serialized.len - reader.seek)
        return error.InvalidFormat;

    const flags: Flags = try .parseFromReader(&reader);

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
    return std.mem.eql(u8, self.args, query.args);
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

/// This function is used for tests.
pub fn testSerializeToWriter(
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
            .command = .set,
            .flags = .{},
            .args = &.{ "key", "value" },
        },
        .{
            .command = .set,
            .flags = .{},
            .args = &.{""},
        },
        .{
            .command = .set,
            .flags = .{},
            .args = &.{ "", "" },
        },
        .{
            .command = .get,
            .flags = .{
                .noreply = .init(true),
            },
            .args = &.{"user"},
        },
        .{
            .flags = .{
                .free = .init(true),
            },
            .args = &.{"some flags"},
            .command = .list,
        },
        .{
            .command = .list,
            .flags = .{
                .filter_by = .init(.index, Query.Flags.Unsigned.init(0)),
            },
            .args = &.{"user*"},
        },
        .{
            .command = .list,
            .flags = .{
                .filter_by = .init(.index, Query.Flags.Unsigned.init(64)),
            },
            .args = &.{"*user"},
        },
        .{
            .command = .list,
            .flags = .{
                .filter_by = .init(.index, Query.Flags.Unsigned.init(std.math.maxInt(u32))),
            },
            .args = &.{"*user"},
        },
        .{
            .command = .list,
            .flags = .{
                .filter_by = .init(
                    .range,
                    Query.Flags.Range.init(
                        .init(0),
                        .init(10),
                    ),
                ),
            },
            .args = &.{"users"},
        },
        .{
            .command = .list,
            .flags = .{
                .filter_by = .init(
                    .range,
                    Query.Flags.Range.init(
                        .init(1),
                        .init(std.math.maxInt(u32)),
                    ),
                ),
            },
            .args = &.{"users"},
        },
        .{
            .flags = .{
                .filter_by = .init(
                    .key,
                    Query.Flags.String.init("user:123"),
                ),
            },
            .args = &.{},
            .command = .list,
        },
        .{
            .flags = .{
                .filter_by = .init(
                    .key,
                    Query.Flags.String.init(""),
            .command = .list,
                ),
            },
            .args = &.{},
        },
        .{
            .command = .rename,
            .flags = .{
                .noreply = .init(true),
                .free = .init(true),
                .filter_by = .init(
                    .index,
                    Query.Flags.Unsigned.init(7),
                ),
            },
            .args = &.{ "old", "new" },
        },
        .{
            .command = .del,
            .flags = .{
                .noreply = .init(true),
                .free = .init(true),
                .filter_by = .init(
                    .range,
                    Query.Flags.Range.init(
                        .init(5),
                        .init(20),
                    ),
                ),
            },
            .args = &.{},
        },
        .{
            .command = .count,
            .flags = .{
                .noreply = .init(true),
                .filter_by = .init(
                    .key,
                    Query.Flags.String.init("active"),
                ),
            },
            .args = &.{"sessions"},
        },
        .{
            .command = .copy,
            .flags = .{},
            .args = &.{ "a", "b", "c", "d", "e", "f", "g" },
        },
        .{
            .command = .set,
            .flags = .{},
            .args = &.{
                "hello\nworld",
                "value\t123",
            },
        },
        .{
            .command = .set,
            .flags = .{},
            .args = &.{ "ciao", "你好", "🚀" },
        },
        .{
            .command = .update,
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

        try testSerializeToWriter(&writer, expected.command, expected.flags, expected.args);
        const parsed: Query = try .parse(writer.buffered());

        try std.testing.expect(parsed.command == expected.command);
        try std.testing.expect(parsed.flags.isEqualTo(expected.flags));
        try std.testing.expect(testIsEqualTo(parsed.args, expected.args));
    }
}
