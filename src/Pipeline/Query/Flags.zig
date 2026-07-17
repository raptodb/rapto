//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of Flags field of Query.

const Flags = @This();

const std = @import("std");

pub const Error = error{InvalidFormat};

/// Maximum number of results emitted.
limit: Quota = .default,

pub const Quota = enum(u64) {
    unlimited = std.math.maxInt(usize),
    _,

    const default: Quota = .unlimited;

    pub fn init(value: u64) Quota {
        return @enumFromInt(value);
    }

    pub fn get(self: Quota) u64 {
        return @intFromEnum(self);
    }

    pub fn isDefault(self: Quota) bool {
        return self == .unlimited;
    }

    fn parseFromReader(reader: *std.Io.Reader) error{InvalidFormat}!Quota {
        return @enumFromInt(try take(reader, u64));
    }

    fn serializeContentToWriter(self: Quota, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeInt(u64, @intFromEnum(self), .little);
    }

    fn isEqualTo(self: Quota, limit: Quota) bool {
        return self.get() == limit.get();
    }
};

/// Tag of all flags of this struct.
const Tag = enum(u6) {
    limit,

    fn bitmask(self: Tag) u64 {
        return @as(u64, 1) << @as(u6, @intCast(@intFromEnum(self)));
    }
};

const Mask = struct {
    raw: u64,

    pub const empty: Mask = .{ .raw = 0 };

    pub fn parseFromReader(reader: *std.Io.Reader) Error!Mask {
        return .{ .raw = try take(reader, u64) };
    }

    pub fn get(self: Mask) u64 {
        return self.raw;
    }

    pub fn add(self: *Mask, tag: Tag) void {
        self.raw |= tag.bitmask();
    }

    pub fn has(self: Mask, tag: Tag) bool {
        return self.raw & tag.bitmask() != 0;
    }
};

pub fn parseFromReader(reader: *std.Io.Reader) Error!Flags {
    var limit: Quota = .unlimited;

    const mask: Mask = try .parseFromReader(reader);
    if (mask.has(.limit)) {
        limit = try .parseFromReader(reader);
    }

    return .{ .limit = limit };
}

pub fn serializeToWriter(self: Flags, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var mask: Mask = .empty;

    if (!self.limit.isDefault()) mask.add(.limit);

    try writer.writeInt(u64, mask.get(), .little);
    if (mask.has(.limit)) {
        try self.limit.serializeContentToWriter(writer);
    }
}

pub fn isEqualTo(self: Flags, flags: Flags) bool {
    inline for (comptime std.meta.fieldNames(Flags)) |field| {
        const a = @field(self, field);
        const b = @field(flags, field);
        if (!a.isEqualTo(b)) return false;
    }
    return true;
}

fn take(reader: *std.Io.Reader, comptime T: type) Error!T {
    return reader.takeInt(T, .little) catch error.InvalidFormat;
}

test "Flags" {
    const cases = [_]Flags{
        .{},
        .{ .limit = .init(0) },
        .{ .limit = .init(1) },
        .{ .limit = .init(100) },
        .{ .limit = .init(std.math.maxInt(u64)) },
    };

    for (cases) |c| {
        var buffer: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        try c.serializeToWriter(&writer);
        var reader: std.Io.Reader = .fixed(writer.buffered());
        const parsed: Flags = try .parseFromReader(&reader);

        try std.testing.expect(c.isEqualTo(parsed));
    }
}
