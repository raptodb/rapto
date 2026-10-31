//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of record.

const std = @import("std");
const value = @import("../value.zig");
const assert = std.debug.assert;

const Record = @This();

/// Representation of first 8 bytes of record.
/// Used to store metadata such as length and
/// other utilities.
pub const Metadata = packed struct(u64) {
    const size: u64 = @sizeOf(Metadata);

    key_len: u8,
    value_len: u32,
    value_type: value.Type,

    locked: bool = false,

    // Reserved for incoming features.
    _: u19 = undefined,
};

pub const Error = error{ KeyTooLong, InvalidKey } || std.mem.Allocator.Error;

/// Pointer to record's layout that represent:
/// [metadata][key][value]
ptr: [*]align(@alignOf(Metadata)) u8,

pub fn init(
    allocator: std.mem.Allocator,
    new_key: []const u8,
    value_type: value.Type,
    inline_value: []const u8,
) Error!Record {
    if (new_key.len > std.math.maxInt(u8)) return error.KeyTooLong;
    if (new_key.len == 0) return error.InvalidKey;

    const m: Metadata = .{
        .key_len = @truncate(new_key.len),
        .value_len = @truncate(inline_value.len),
        .value_type = value_type,
    };

    const new_slice = slice: {
        const new_len = Metadata.size + new_key.len + inline_value.len;
        break :slice try allocator.alignedAlloc(u8, .of(Metadata), new_len);
    };

    const self: Record = .{ .ptr = new_slice.ptr };
    self.write(m, new_key, inline_value);
    return self;
}

pub fn deinit(self: Record, allocator: std.mem.Allocator) void {
    allocator.free(self.slice());
}

pub fn set(
    self: *Record,
    allocator: std.mem.Allocator,
    value_type: value.Type,
    inline_value: []const u8,
) Error!void {
    var m = self.metadata();

    if (m.value_len != inline_value.len) {
        const new_len = Metadata.size + m.key_len + inline_value.len;
        const old_slice = self.slice();
        assert(old_slice.len != new_len);

        const new_slice = try allocator.realloc(old_slice, new_len);
        self.ptr = new_slice.ptr;
        m = self.metadata();

        m.value_len = @truncate(inline_value.len);
    }
    errdefer comptime unreachable;

    m.value_type = value_type;
    self.writeValue(m.*, inline_value);
}

pub fn metadata(self: Record) *Metadata {
    return std.mem.bytesAsValue(Metadata, self.ptr[0..Metadata.size]);
}

pub fn key(self: Record) []const u8 {
    const m = self.metadata();
    return self.ptr[Metadata.size..][0..m.key_len];
}

pub fn valueAsBytes(self: Record) []const u8 {
    const m = self.metadata();
    return self.ptr[Metadata.size + m.key_len ..][0..m.value_len];
}

fn slice(self: Record) []align(@alignOf(Metadata)) u8 {
    const m = self.metadata();
    const len = Metadata.size + m.key_len + m.value_len;
    return self.ptr[0..len];
}

fn write(self: Record, m: Metadata, new_key: []const u8, inline_value: []const u8) void {
    const len = Metadata.size + new_key.len + inline_value.len;
    var writer: std.Io.Writer = .fixed(self.ptr[0..len]);

    const m_buf = writer.writableArray(Metadata.size) catch unreachable;
    std.mem.writeInt(u64, m_buf, @bitCast(m), .little);
    _ = writer.writeVec(&.{ new_key, inline_value }) catch unreachable;
    assert(writer.unusedCapacityLen() == 0);
}

/// As `write()` but keeping the same key.
fn writeValue(self: Record, m: Metadata, inline_value: []const u8) void {
    const len = Metadata.size + m.key_len + inline_value.len;
    var writer: std.Io.Writer = .fixed(self.ptr[0..len]);

    const m_buf = writer.writableArray(Metadata.size) catch unreachable;
    std.mem.writeInt(u64, m_buf, @bitCast(m), .little);
    writer.advance(m.key_len);
    _ = writer.write(inline_value) catch unreachable;
    assert(writer.unusedCapacityLen() == 0);
}

test "record" {
    const allocator = std.testing.allocator;

    const types = std.meta.tags(value.Type);
    const keys: [256]u8 = @splat('a');
    const a: [1024]u8 = @splat(0x00);
    const b: [1024]u8 = @splat(0xFF);

    try std.testing.expectError(error.InvalidKey, Record.init(allocator, "", types[0], ""));
    try std.testing.expectError(error.KeyTooLong, Record.init(allocator, &keys, types[0], ""));

    var key_size: usize = 2;
    while (key_size <= keys.len) : (key_size *= 2) {
        const key_len = key_size - 1;
        var r: Record = try .init(allocator, keys[0..key_len], types[0], "");
        defer r.deinit(allocator);

        var m = r.metadata();
        try std.testing.expect(key_len == m.key_len);
        try std.testing.expect(m.value_len == 0);
        try std.testing.expect(types[0] == m.value_type);
        try std.testing.expect(!m.locked);
        try std.testing.expectEqualStrings(keys[0..key_len], r.key());
        try std.testing.expectEqualStrings("", r.valueAsBytes());

        m.locked = true;

        for (types) |kind| {
            var size: usize = 1;
            while (size <= a.len * 2) : (size *= 2) {
                const len = size / 2;

                for ([_][]const u8{ a[0..len], b[0..len] }) |bytes| {
                    try r.set(allocator, kind, bytes);
                    m = r.metadata();

                    try std.testing.expect(key_len == @as(usize, m.key_len));
                    try std.testing.expect(len == @as(usize, m.value_len));
                    try std.testing.expect(kind == m.value_type);
                    try std.testing.expect(m.locked);
                    try std.testing.expectEqualStrings(keys[0..key_len], r.key());
                    try std.testing.expectEqualStrings(bytes, r.valueAsBytes());
                }
            }
        }
    }
}
