//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of Flags field of Query.

const Flags = @This();

const std = @import("std");

pub const Error = error{ UnknownFlag, InvalidFlagUnion, InvalidFormat };

/// If true, the command will not
/// send a reply to the client.
noreply: Bool = .init(false),
/// If true, ERASE operations
/// frees all objects.
free: Bool = .init(false),
/// Specifies which elements will be
/// filtered for the operation.
/// This affects key or value, related
/// to the type of the operation.
filter_by: FilterBy = .default,

pub const FilterBy = struct {
    value: Union,

    const Union = union(enum) {
        any,

        index: Unsigned,
        range: Range,
        key: String,
        regex: String,
    };

    const default: FilterBy = .{ .value = .any };

    pub fn init(comptime filter_by_tag: enum { any, index, range, key }, flag: anytype) FilterBy {
        return .{ .value = switch (filter_by_tag) {
            .any => .any,
            .index => .{ .index = flag },
            .range => .{ .range = flag },
            .key => .{ .key = flag },
        } };
    }

    pub fn get(self: FilterBy) Union {
        return self.value;
    }

    fn tag(self: FilterBy) Tag {
        return switch (self.value) {
            .any => .filter_by_any,
            .index => .filter_by_index,
            .range => .filter_by_range,
            .key => .filter_by_key,
        };
    }

    fn parseContentFromReader(
        reader: *std.Io.Reader,
        comptime filter_by_tag: enum { any, index, range, key },
    ) error{InvalidFormat}!FilterBy {
        return .{ .value = switch (filter_by_tag) {
            .any => .any,
            .index => .{ .index = try .parseFromReader(reader) },
            .range => .{ .range = try .parseFromReader(reader) },
            .key => .{ .key = try .parseFromReader(reader) },
        } };
    }

    fn serializeContentToWriter(self: FilterBy, writer: *std.Io.Writer) std.Io.Writer.Error!void {
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

    fn parseFromReader(reader: *std.Io.Reader) error{InvalidFormat}!Bool {
        const n = try take(reader, u8);
        return .init(n != 0);
    }

    fn serializeToWriter(self: Bool, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeInt(u8, @intFromBool(self.value), .little);
    }
};

pub const Range = struct {
    value: struct { from: Unsigned, to: Unsigned },

    pub fn init(from_arg: Unsigned, to_arg: Unsigned) Range {
        return .{
            .value = .{
                .from = from_arg,
                .to = to_arg,
            },
        };
    }

    pub fn from(self: Range) Unsigned {
        return self.value.from;
    }

    pub fn to(self: Range) Unsigned {
        return self.value.to;
    }

    fn parseFromReader(reader: *std.Io.Reader) error{InvalidFormat}!Range {
        const from_param: Unsigned = try .parseFromReader(reader);
        const to_param: Unsigned = try .parseFromReader(reader);
        return .init(from_param, to_param);
    }

    fn serializeToWriter(self: Range, writer: *std.Io.Writer) std.Io.Writer.Error!void {
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

    fn parseFromReader(reader: *std.Io.Reader) error{InvalidFormat}!Unsigned {
        return .init(try take(reader, u32));
    }

    fn serializeToWriter(self: Unsigned, writer: *std.Io.Writer) std.Io.Writer.Error!void {
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

    fn parseFromReader(reader: *std.Io.Reader) error{InvalidFormat}!String {
        const len = try take(reader, u32);
        const str = reader.take(len) catch return error.InvalidFormat;
        return .init(str);
    }

    fn serializeToWriter(self: String, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeInt(u32, @truncate(self.value.len), .little);
        return writer.writeAll(self.value);
    }
};

/// Tag of all flags of this struct.
const Tag = enum(u6) {
    noreply = 0,
    free,

    filter_by_any,
    filter_by_index,
    filter_by_range,
    filter_by_key,

    fn bitmask(self: Tag) u64 {
        return @as(u64, 1) << @as(u6, @intFromEnum(self));
    }
};

pub fn parseFromReader(reader: *std.Io.Reader) Error!Flags {
    var self: Flags = .{};

    const mask = try take(reader, u64);

    const by_bits =
        mask & (Tag.bitmask(.filter_by_index) | Tag.bitmask(.filter_by_range) | Tag.bitmask(.filter_by_key));
    if (@popCount(by_bits) > 1) return error.InvalidFlagUnion;

    if (mask & Tag.bitmask(.noreply) != 0) self.noreply = try Bool.parseFromReader(reader);
    if (mask & Tag.bitmask(.free) != 0) self.free = try Bool.parseFromReader(reader);
    if (mask & Tag.bitmask(.filter_by_index) != 0) self.filter_by = try FilterBy.parseContentFromReader(reader, .index);
    if (mask & Tag.bitmask(.filter_by_range) != 0) self.filter_by = try FilterBy.parseContentFromReader(reader, .range);
    if (mask & Tag.bitmask(.filter_by_key) != 0) self.filter_by = try FilterBy.parseContentFromReader(reader, .key);

    return self;
}

pub fn serializeToWriter(self: Flags, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var mask: u64 = 0;
    if (self.noreply.get()) mask |= Tag.bitmask(.noreply);
    if (self.free.get()) mask |= Tag.bitmask(.free);
    mask |= switch (self.filter_by.value) {
        .any => 0,
        .index => Tag.bitmask(.filter_by_index),
        .range => Tag.bitmask(.filter_by_range),
        .key => Tag.bitmask(.filter_by_key),
    };
    try writer.writeInt(u64, mask, .little);

    if (self.noreply.get()) try self.noreply.serializeToWriter(writer);
    if (self.free.get()) try self.free.serializeToWriter(writer);
    try self.filter_by.serializeContentToWriter(writer);
}

pub fn isEqualTo(self: Flags, flags: Flags) bool {
    if (self.noreply.get() != flags.noreply.get()) return false;
    if (self.free.get() != flags.free.get()) return false;

    return switch (self.filter_by.value) {
        .any => flags.filter_by.value == .any,
        .index => |v| switch (flags.filter_by.value) {
            .index => |pv| v.get() == pv.get(),
            else => false,
        },
        .range => |r| switch (flags.filter_by.value) {
            .range => |pr| r.from().get() == pr.from().get() and
                r.to().get() == pr.to().get(),
            else => false,
        },
        .key => |k| switch (flags.filter_by.value) {
            .key => |pk| std.mem.eql(u8, k.get(), pk.get()),
            else => false,
        },
    };
}

fn take(reader: *std.Io.Reader, comptime T: type) error{InvalidFormat}!T {
    return reader.takeInt(T, .little) catch error.InvalidFormat;
}

test "Flags" {
    const cases = [_]Flags{
        .{},
        .{ .noreply = .init(true) },
        .{ .free = .init(true) },
        .{ .filter_by = .init(.index, Unsigned.init(0)) },
        .{ .filter_by = .init(.index, Unsigned.init(42)) },
        .{ .filter_by = .init(.index, Unsigned.init(std.math.maxInt(u32))) },
        .{ .filter_by = .init(.range, Range.init(.init(0), .init(0))) },
        .{ .filter_by = .init(.range, Range.init(.init(5), .init(15))) },
        .{ .filter_by = .init(.range, Range.init(.init(0), .init(std.math.maxInt(u32)))) },
        .{ .filter_by = .init(.key, String.init("")) },
        .{ .filter_by = .init(.key, String.init("a")) },
        .{ .filter_by = .init(.key, String.init("abc")) },
        .{ .filter_by = .init(.key, String.init("longer_key_test")) },
        .{
            .noreply = .init(true),
            .filter_by = .init(.index, Unsigned.init(1)),
        },
        .{
            .free = .init(true),
            .filter_by = .init(.range, Range.init(.init(10), .init(20))),
        },
        .{
            .noreply = .init(true),
            .free = .init(true),
            .filter_by = .init(.index, Unsigned.init(999)),
        },
        .{
            .noreply = .init(true),
            .free = .init(true),
            .filter_by = .init(.range, Range.init(.init(1), .init(1))),
        },
        .{
            .noreply = .init(true),
            .filter_by = .init(.key, String.init("user:123")),
        },
        .{
            .free = .init(true),
            .filter_by = .init(.key, String.init("session_token")),
        },
        .{
            .noreply = .init(true),
            .free = .init(true),
            .filter_by = .init(.key, String.init("abc")),
        },
    };

    for (cases) |c| {
        var buffer: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        try c.serializeToWriter(&writer);
        var reader: std.Io.Reader = .fixed(writer.buffered());
        const parsed: Flags = try .parseFromReader(&reader);

        try std.testing.expect(c.isEqualTo(parsed));
    }
}
