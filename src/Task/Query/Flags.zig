//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of Flags field of Query.

const std = @import("std");

const Flags = @This();

/// If true, the command will not
/// send a reply to the client.
noreply: bool = false,
/// If true, ERASE operations
/// frees all objects.
free: bool = false,
/// Specifies which elements has
/// been selected for the operation.
by: union(enum) {
    any,

    index: u32,
    range: Range,
    key: []const u8,

    fn tag(self: @This()) Tag {
        return switch (self) {
            .any => .byany,
            .index => .byindex,
            .range => .byrange,
            .key => .bykey,
        };
    }

    fn serializePayloadToWriter(self: @This(), writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (self) {
            .any => {},
            .index => |value| try serializeUnsignedToWriter(writer, value),
            .range => |value| try serializeRangeToWriter(writer, value.from, value.to),
            .key => |value| try serializeStringToWriter(writer, value),
        }
    }
} = .any,

const Range = struct { from: u32, to: u32 };

/// Tag of all flags of this struct.
const Tag = enum(u8) {
    noreply,
    free,

    byindex,
    byrange,
    bykey,
    byany,

    fn fromInt(int: u8) error{UnknownFlag}!Tag {
        return std.enums.fromInt(Tag, int) orelse error.UnknownFlag;
    }

    fn serializeToWriter(self: Tag, writer: *std.Io.Writer) error{WriteFailed}!void {
        return writer.writeByte(@intFromEnum(self));
    }
};

pub fn parse(flags: []const u8) error{ UnknownFlag, InvalidFormat }!Flags {
    var self: Flags = .{};
    var reader: std.Io.Reader = .fixed(flags);

    while (reader.seek < flags.len) {
        const flag_byte = reader.takeByte() catch break;

        const flag_tag: Tag = try .fromInt(flag_byte);
        switch (flag_tag) {
            .noreply => self.noreply = try parseBool(&reader),
            .free => self.free = try parseBool(&reader),

            .byindex => self.by = .{ .index = try parseUnsigned(&reader) },
            .byrange => self.by = .{ .range = try parseRange(&reader) },
            .bykey => self.by = .{ .key = try parseString(&reader) },
            .byany => self.by = .any,
        }
    }

    return self;
}

pub fn serializeToWriter(self: Flags, writer: *std.Io.Writer) error{WriteFailed}!void {
    inline for (std.meta.fields(Flags)) |field| {
        const value = @field(self, field.name);

        switch (@typeInfo(field.type)) {
            .bool => if (value) {
                const tag = comptime std.meta.stringToEnum(Tag, field.name).?;
                try tag.serializeToWriter(writer);
                try serializeBoolToWriter(writer, value);
            },
            .@"union" => if (value != .any) {
                try value.tag().serializeToWriter(writer);
                try value.serializePayloadToWriter(writer);
            },
            else => unreachable,
        }
    }
}

fn take(reader: *std.Io.Reader, comptime T: type) error{InvalidFormat}!T {
    return reader.takeInt(T, .little) catch error.InvalidFormat;
}

fn parseBool(reader: *std.Io.Reader) error{InvalidFormat}!bool {
    return (try take(reader, u8)) > 0;
}

fn parseUnsigned(reader: *std.Io.Reader) error{InvalidFormat}!u32 {
    return take(reader, u32);
}

fn parseRange(reader: *std.Io.Reader) error{InvalidFormat}!Range {
    return .{ .from = try take(reader, u32), .to = try take(reader, u32) };
}

fn parseString(reader: *std.Io.Reader) error{InvalidFormat}![]const u8 {
    const len = try take(reader, u32);
    return reader.take(len) catch error.InvalidFormat;
}

fn serializeBoolToWriter(writer: *std.Io.Writer, value: bool) error{WriteFailed}!void {
    return writer.writeInt(u8, @intFromBool(value), .little);
}

fn serializeUnsignedToWriter(writer: *std.Io.Writer, value: u32) error{WriteFailed}!void {
    return writer.writeInt(u32, value, .little);
}

fn serializeRangeToWriter(writer: *std.Io.Writer, from: u32, to: u32) error{WriteFailed}!void {
    try serializeUnsignedToWriter(writer, from);
    try serializeUnsignedToWriter(writer, to);
}

fn serializeStringToWriter(writer: *std.Io.Writer, value: []const u8) error{WriteFailed}!void {
    try writer.writeInt(u32, @truncate(value.len), .little);
    return writer.writeAll(value);
}

test "Flags" {
    var buffer: [512]u8 = undefined;

    const cases = [_]Flags{
        .{ .noreply = false, .free = false, .by = .any },
        .{ .noreply = true, .free = false, .by = .{ .index = 42 } },
        .{ .noreply = false, .free = true, .by = .{ .range = .{ .from = 5, .to = 15 } } },
        .{ .noreply = true, .free = true, .by = .{ .key = "abc" } },
    };

    for (cases) |original| {
        var writer: std.Io.Writer = .fixed(&buffer);

        try original.serializeToWriter(&writer);

        const parsed: Flags = try .parse(writer.buffered());

        try std.testing.expectEqual(original.noreply, parsed.noreply);
        try std.testing.expectEqual(original.free, parsed.free);

        switch (original.by) {
            .any => switch (parsed.by) {
                .any => {},
                else => return error.TestFailure,
            },
            .index => |v| switch (parsed.by) {
                .index => |pv| try std.testing.expectEqual(v, pv),
                else => return error.TestFailure,
            },
            .range => |r| switch (parsed.by) {
                .range => |pr| {
                    try std.testing.expectEqual(r.from, pr.from);
                    try std.testing.expectEqual(r.to, pr.to);
                },
                else => return error.TestFailure,
            },
            .key => |k| switch (parsed.by) {
                .key => |pk| try std.testing.expectEqualStrings(k, pk),
                else => return error.TestFailure,
            },
        }
    }

    {
        var stream = std.io.fixedBufferStream(&buffer);
        const w = &stream.writer();

        try w.writeByte(@intFromEnum(Flags.Tag.byindex));
        try w.writeInt(u32, 99, .little);

        try w.writeByte(@intFromEnum(Flags.Tag.noreply));
        try w.writeByte(1);

        try w.writeByte(@intFromEnum(Flags.Tag.free));
        try w.writeByte(1);

        const parsed = try Flags.parse(stream.getWritten());

        try std.testing.expect(parsed.noreply);
        try std.testing.expect(parsed.free);

        switch (parsed.by) {
            .index => |v| try std.testing.expectEqual(@as(u32, 99), v),
            else => return error.TestFailure,
        }
    }

    {
        const parsed: Flags = try .parse(&[_]u8{});
        try std.testing.expect(!parsed.noreply);
        try std.testing.expect(!parsed.free);

        switch (parsed.by) {
            .any => {},
            else => return error.TestFailure,
        }
    }

    {
        const data = [_]u8{0xFF};
        try std.testing.expectError(error.UnknownFlag, Flags.parse(&data));
    }

    {
        var stream = std.io.fixedBufferStream(&buffer);
        const w = &stream.writer();

        try w.writeByte(@intFromEnum(Flags.Tag.byindex));

        try std.testing.expectError(
            error.InvalidFormat,
            Flags.parse(stream.getWritten()),
        );
    }

    {
        var stream = std.io.fixedBufferStream(&buffer);
        const w = &stream.writer();

        try w.writeByte(@intFromEnum(Flags.Tag.bykey));
        try w.writeInt(u32, 10, .little);
        try w.writeByte(1);

        try std.testing.expectError(
            error.InvalidFormat,
            Flags.parse(stream.getWritten()),
        );
    }
}
