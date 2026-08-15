//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of Flags field of Query.

const Flags = @This();

const std = @import("std");

pub const Error = error{InvalidFormat};

/// Limit iteration to only operations whose size depends
/// on undefined operations as patterns and ranges.
limit: Quota = .default,
/// Starting cursor for the operation.
/// Mostly used for pattern matching commands.
cursor: Unsigned = .default,
/// Used for insert command.
replace: Bool = .default,
/// Used for put/set/copy/rename command.
if_not_exists: Bool = .default,

pub const Quota = enum(u64) {
    unlimited = std.math.maxInt(usize),
    _,

    pub const default: Quota = .unlimited;

    pub fn init(value: u64) Quota {
        return @enumFromInt(value);
    }

    pub fn get(self: Quota) u64 {
        return @intFromEnum(self);
    }

    pub fn isDefault(self: Quota) bool {
        return self.isEqualTo(default);
    }

    fn deserializeFromReader(reader: *std.Io.Reader) error{InvalidFormat}!Quota {
        return @enumFromInt(try take(reader, u64));
    }

    fn serializeContentToWriter(self: Quota, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeInt(u64, @intFromEnum(self), .little);
    }

    fn isEqualTo(self: Quota, limit: Quota) bool {
        return self == limit;
    }
};

pub const Bool = struct {
    value: bool,

    pub const default: Bool = .init(false);

    pub fn init(value: bool) Bool {
        return .{ .value = value };
    }

    pub fn get(self: Bool) bool {
        return self.value;
    }

    pub fn isDefault(self: Bool) bool {
        return self.isEqualTo(default);
    }

    pub fn deserializeFromReader(reader: *std.Io.Reader) error{InvalidFormat}!Bool {
        return .{ .value = (try take(reader, u8)) != 0 };
    }

    pub fn serializeContentToWriter(self: Bool, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeByte(@intFromBool(self.get()));
    }

    pub fn isEqualTo(self: Bool, other: Bool) bool {
        return self.get() == other.get();
    }
};

pub const Unsigned = struct {
    value: u64,

    pub const default: Unsigned = .init(0);

    pub fn init(value: u64) Unsigned {
        return .{ .value = value };
    }

    pub fn get(self: Unsigned) u64 {
        return self.value;
    }

    pub fn isDefault(self: Unsigned) bool {
        return self.isEqualTo(default);
    }

    pub fn deserializeFromReader(reader: *std.Io.Reader) error{InvalidFormat}!Unsigned {
        return .{ .value = try take(reader, u64) };
    }

    pub fn serializeContentToWriter(self: Unsigned, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeInt(u64, self.get(), .little);
    }

    pub fn isEqualTo(self: Unsigned, other: Unsigned) bool {
        return self.get() == other.get();
    }
};

const Tag = std.meta.FieldEnum(Flags);

fn bitmask(tag: Tag) u64 {
    return @as(u64, 1) << @as(u6, @intCast(@intFromEnum(tag)));
}

const Mask = struct {
    raw: u64,

    pub const empty: Mask = .{ .raw = 0 };

    pub fn deserializeFromReader(reader: *std.Io.Reader) Error!Mask {
        return .{ .raw = try take(reader, u64) };
    }

    pub fn get(self: Mask) u64 {
        return self.raw;
    }

    pub fn add(self: *Mask, tag: Tag) void {
        self.raw |= bitmask(tag);
    }

    pub fn has(self: Mask, tag: Tag) bool {
        return self.raw & bitmask(tag) != 0;
    }
};

pub fn deserializeFromReader(reader: *std.Io.Reader) Error!Flags {
    const has_default_flags = reader.takeInt(u8, .little) catch return error.InvalidFormat;
    // When the first byte is zero, all flags are default.
    if (has_default_flags == 0) return .{};

    var result: Flags = .{};

    const mask: Mask = try .deserializeFromReader(reader);
    inline for (comptime std.meta.fieldNames(Flags)) |name| {
        if (mask.has(@field(Tag, name))) {
            @field(result, name) = try @TypeOf(
                @field(result, name),
            ).deserializeFromReader(reader);
        }
    }

    return result;
}

pub fn serializeToWriter(self: Flags, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.isEqualTo(.{})) {
        // When all flags are default we can avoid
        // flag deserialization with hint byte before.
        return writer.writeByte(0);
    } else {
        // Otherwise if there is any non-default flag
        // we can proceed to serialize.
        try writer.writeByte(1);
    }

    var mask: Mask = .empty;
    inline for (comptime std.meta.fieldNames(Flags)) |name| {
        const has_default_flag = @field(self, name).isDefault();
        if (!has_default_flag) mask.add(@field(Tag, name));
    }

    try writer.writeInt(u64, mask.get(), .little);
    inline for (comptime std.meta.fieldNames(Flags)) |name| {
        if (mask.has(@field(Tag, name))) {
            try @field(self, name).serializeContentToWriter(writer);
        }
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
        .{ .limit = .init(100), .replace = .init(true) },
        .{ .limit = .init(std.math.maxInt(u64)) },
        .{ .if_not_exists = .init(true) },
        .{ .replace = .init(false), .if_not_exists = .init(false) },
        .{ .limit = .init(1), .cursor = .init(100) },
        .{ .cursor = .init(350) },
    };

    for (cases) |c| {
        var buffer: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        try c.serializeToWriter(&writer);
        var reader: std.Io.Reader = .fixed(writer.buffered());
        const deserialized: Flags = try .deserializeFromReader(&reader);

        try std.testing.expect(c.isEqualTo(deserialized));
    }
}
