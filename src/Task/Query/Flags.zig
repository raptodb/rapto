//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of Flags field of Query.

const Flags = @This();

const std = @import("std");

/// If true, the command will not
/// send a reply to the client.
noreply: Bool = .init(false),
/// If true, ERASE operations
/// frees all objects.
free: Bool = .init(false),
/// Specifies which elements has
/// been selected for the operation.
by: By = .default,

pub const By = struct {
    value: Union,

    const Union = union(enum) {
        any,

        index: Unsigned,
        range: Range,
        key: String,
    };

    const default: By = .{ .value = .any };

    pub fn init(comptime by_tag: enum { any, index, range, key }, flag: anytype) By {
        return .{
            .value = switch (by_tag) {
                .any => .any,
                .index => .{ .index = flag },
                .range => .{ .range = flag },
                .key => .{ .key = flag },
            },
        };
    }

    pub fn get(self: By) Union {
        return self.value;
    }

    fn tag(self: @This()) Tag {
        return switch (self.value) {
            .any => .byany,
            .index => .byindex,
            .range => .byrange,
            .key => .bykey,
        };
    }

    fn serializeContentToWriter(self: @This(), writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (self.value) {
            .any => {},
            .index => |value| try value.serializeToWriter(writer),
            .range => |value| try value.serializeToWriter(writer),
            .key => |value| try value.serializeToWriter(writer),
        }
    }
};

pub const Bool = struct {
    value: bool,

    pub fn init(value: bool) Bool {
        return .{ .value = value };
    }

    pub fn get(self: Bool) bool {
        return self.value;
    }

    fn parse(reader: *std.Io.Reader) error{InvalidFormat}!Bool {
        const n = try take(reader, u8);
        return .init(n != 0);
    }

    fn serializeToWriter(self: Bool, writer: *std.Io.Writer) error{WriteFailed}!void {
        return writer.writeInt(u8, @intFromBool(self.value), .little);
    }
};

pub const Range = struct {
    value: struct { from: Unsigned, to: Unsigned },

    pub fn init(from_param: Unsigned, to_param: Unsigned) Range {
        return .{
            .value = .{
                .from = from_param,
                .to = to_param,
            },
        };
    }

    pub fn from(self: Range) Unsigned {
        return self.value.from;
    }

    pub fn to(self: Range) Unsigned {
        return self.value.to;
    }

    fn parse(reader: *std.Io.Reader) error{InvalidFormat}!Range {
        const from_param: Unsigned = try .parse(reader);
        const to_param: Unsigned = try .parse(reader);
        return .init(from_param, to_param);
    }

    fn serializeToWriter(self: Range, writer: *std.Io.Writer) error{WriteFailed}!void {
        try self.value.from.serializeToWriter(writer);
        try self.value.to.serializeToWriter(writer);
    }
};

pub const Unsigned = struct {
    value: u32,

    pub fn init(value: u32) Unsigned {
        return .{ .value = value };
    }

    pub fn get(self: Unsigned) u32 {
        return self.value;
    }

    fn parse(reader: *std.Io.Reader) error{InvalidFormat}!Unsigned {
        return .init(try take(reader, u32));
    }

    fn serializeToWriter(self: Unsigned, writer: *std.Io.Writer) error{WriteFailed}!void {
        return writer.writeInt(u32, self.value, .little);
    }
};

pub const String = struct {
    value: []const u8,

    pub fn init(value: []const u8) String {
        return .{ .value = value };
    }

    pub fn get(self: String) []const u8 {
        return self.value;
    }

    fn parse(reader: *std.Io.Reader) error{InvalidFormat}!String {
        const len = try take(reader, u32);
        const str = reader.take(len) catch return error.InvalidFormat;
        return .init(str);
    }

    fn serializeToWriter(self: String, writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u32, @truncate(self.value.len), .little);
        return writer.writeAll(self.value);
    }
};

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

pub fn parseFromReader(reader: *std.Io.Reader, length: u32) error{ UnknownFlag, InvalidFormat }!Flags {
    var self: Flags = .{};

    const start = reader.seek;
    while (reader.seek - start < length) {
        const flag_byte = reader.takeByte() catch return error.InvalidFormat;

        const flag_tag: Tag = try .fromInt(flag_byte);
        switch (flag_tag) {
            .noreply => self.noreply = try .parse(reader),
            .free => self.free = try .parse(reader),

            .byindex => self.by = .init(.index, try Unsigned.parse(reader)),
            .byrange => self.by = .init(.range, try Range.parse(reader)),
            .bykey => self.by = .init(.key, try String.parse(reader)),
            .byany => self.by = .init(.any, undefined),
        }
    }

    return self;
}

pub fn serializeToWriter(self: Flags, writer: *std.Io.Writer) error{WriteFailed}!void {
    inline for (std.meta.fields(Flags)) |field| {
        const flag = @field(self, field.name);

        switch (field.type) {
            Bool => if (flag.get()) {
                const tag = std.meta.stringToEnum(Tag, field.name).?;
                try tag.serializeToWriter(writer);
                try flag.serializeToWriter(writer);
            },
            Range, Unsigned, String => {
                const tag = std.meta.stringToEnum(Tag, field.name).?;
                try tag.serializeToWriter(writer);
                flag.serializeToWriter(writer);
            },
            By => if (flag.get() != .any) {
                try flag.tag().serializeToWriter(writer);
                try flag.serializeContentToWriter(writer);
            },
            else => unreachable,
        }
    }
}

fn take(reader: *std.Io.Reader, comptime T: type) error{InvalidFormat}!T {
    return reader.takeInt(T, .little) catch error.InvalidFormat;
}

test "Flags" {
    const cases = [_]Flags{
        .{},
        .{ .noreply = .init(true) },
        .{ .free = .init(true) },
        .{ .by = .init(.index, Unsigned.init(0)) },
        .{ .by = .init(.index, Unsigned.init(42)) },
        .{ .by = .init(.index, Unsigned.init(std.math.maxInt(u32))) },
        .{ .by = .init(.range, Range.init(.init(0), .init(0))) },
        .{ .by = .init(.range, Range.init(.init(5), .init(15))) },
        .{ .by = .init(.range, Range.init(.init(0), .init(std.math.maxInt(u32)))) },
        .{ .by = .init(.key, String.init("")) },
        .{ .by = .init(.key, String.init("a")) },
        .{ .by = .init(.key, String.init("abc")) },
        .{ .by = .init(.key, String.init("longer_key_test")) },
        .{
            .noreply = .init(true),
            .by = .init(.index, Unsigned.init(1)),
        },
        .{
            .free = .init(true),
            .by = .init(.range, Range.init(.init(10), .init(20))),
        },
        .{
            .noreply = .init(true),
            .free = .init(true),
            .by = .init(.index, Unsigned.init(999)),
        },
        .{
            .noreply = .init(true),
            .free = .init(true),
            .by = .init(.range, Range.init(.init(1), .init(1))),
        },
        .{
            .noreply = .init(true),
            .by = .init(.key, String.init("user:123")),
        },
        .{
            .free = .init(true),
            .by = .init(.key, String.init("session_token")),
        },
        .{
            .noreply = .init(true),
            .free = .init(true),
            .by = .init(.key, String.init("abc")),
        },
    };

    for (cases) |c| {
        var buffer: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        try c.serializeToWriter(&writer);
        var reader: std.Io.Reader = .fixed(writer.buffered());
        const parsed = try Flags.parseFromReader(&reader, @truncate(writer.end));

        try expectFlagsEqual(c, parsed);
    }

    {
        var buffer: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        try writer.writeByte(@intFromEnum(Flags.Tag.byindex));
        try writer.writeInt(u32, 99, .little);

        try writer.writeByte(@intFromEnum(Flags.Tag.noreply));
        try writer.writeByte(1);

        try writer.writeByte(@intFromEnum(Flags.Tag.free));
        try writer.writeByte(1);

        var reader: std.Io.Reader = .fixed(writer.buffered());
        const parsed = try Flags.parseFromReader(&reader, @truncate(writer.end));

        try std.testing.expect(parsed.noreply.get());
        try std.testing.expect(parsed.free.get());

        switch (parsed.by.value) {
            .index => |v| try std.testing.expectEqual(@as(u32, 99), v.get()),
            else => return error.TestFailure,
        }
    }

    {
        var reader: std.Io.Reader = .fixed(&[_]u8{});
        const parsed = try Flags.parseFromReader(&reader, 0);

        try std.testing.expect(!parsed.noreply.get());
        try std.testing.expect(!parsed.free.get());
        try std.testing.expect(parsed.by.value == .any);
    }

    {
        var reader: std.Io.Reader = .fixed(&[_]u8{0xFF});

        try std.testing.expectError(
            error.UnknownFlag,
            Flags.parseFromReader(&reader, 1),
        );
    }

    {
        var buffer: [16]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        try writer.writeByte(@intFromEnum(Flags.Tag.byindex));

        var reader: std.Io.Reader = .fixed(writer.buffered());

        try std.testing.expectError(
            error.InvalidFormat,
            Flags.parseFromReader(&reader, @truncate(writer.end)),
        );
    }

    {
        var buffer: [32]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        try writer.writeByte(@intFromEnum(Flags.Tag.bykey));
        try writer.writeInt(u32, 10, .little);
        try writer.writeByte(1);

        var reader: std.Io.Reader = .fixed(writer.buffered());

        try std.testing.expectError(
            error.InvalidFormat,
            Flags.parseFromReader(&reader, @truncate(writer.end)),
        );
    }
}

pub fn expectFlagsEqual(a: Flags, b: Flags) !void {
    try std.testing.expectEqual(a.noreply.get(), b.noreply.get());
    try std.testing.expectEqual(a.free.get(), b.free.get());

    switch (a.by.value) {
        .any => try std.testing.expect(b.by.value == .any),

        .index => |v| switch (b.by.value) {
            .index => |pv| try std.testing.expectEqual(v.get(), pv.get()),
            else => return error.TestFailure,
        },

        .range => |r| switch (b.by.value) {
            .range => |pr| {
                try std.testing.expectEqual(r.from().get(), pr.from().get());
                try std.testing.expectEqual(r.to().get(), pr.to().get());
            },
            else => return error.TestFailure,
        },

        .key => |k| switch (b.by.value) {
            .key => |pk| try std.testing.expectEqualStrings(k.get(), pk.get()),
            else => return error.TestFailure,
        },
    }
}
