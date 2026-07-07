//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of string value.

/// String value type represented as raw bytes data.
const String = @This();

const std = @import("std");
const assert = std.debug.assert;

/// Pointer to byte array. The first 4 bytes
/// header represents the length of string.
ptr: [*]u8,

pub const Header: type = u32;

pub fn initFromContent(
    allocator: std.mem.Allocator,
    content: []const u8,
) std.mem.Allocator.Error!String {
    const str = try allocator.alloc(u8, @sizeOf(Header) + content.len);
    std.mem.writeInt(Header, str[0..@sizeOf(Header)], @truncate(content.len), .little);
    @memcpy(str[@sizeOf(Header)..], content);

    return .{ .ptr = str.ptr };
}

pub fn set(
    self: *String,
    allocator: std.mem.Allocator,
    content: []const u8,
) std.mem.Allocator.Error!void {
    const length = self.len();

    // content.len is never longer than serialized query.
    assert(content.len <= std.math.maxInt(u32));
    const content_length: u32 = @truncate(content.len);

    if (length != content_length) {
        const slice: []u8 = try allocator.realloc(
            self.ptr[0 .. @sizeOf(Header) + length],
            @sizeOf(Header) + content_length,
        );

        self.ptr = slice.ptr;

        std.mem.writeInt(
            Header,
            self.ptr[0..@sizeOf(Header)],
            @truncate(content_length),
            .little,
        );
    }

    @memcpy(self.ptr[@sizeOf(Header) .. @sizeOf(Header) + content_length], content);
}

pub fn dupe(
    self: String,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!String {
    const buf = try allocator.dupe(u8, self.ptr[0 .. @sizeOf(Header) + self.len()]);
    return .{ .ptr = buf.ptr };
}

pub fn get(self: String) []const u8 {
    return self.ptr[@sizeOf(Header) .. @sizeOf(Header) + self.len()];
}

/// Returns logical length of string content, excluding header.
pub fn len(self: String) u32 {
    return std.mem.readInt(Header, self.ptr[0..@sizeOf(Header)], .little);
}

pub fn deinit(self: String, allocator: std.mem.Allocator) void {
    allocator.free(self.ptr[0 .. @sizeOf(Header) + self.len()]);
}

pub fn serializeContentToWriter(self: String, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(self.get());
}

test "String" {
    const allocator = std.testing.allocator;

    var s: String = try .initFromContent(allocator, "example string");
    defer s.deinit(allocator);

    try std.testing.expectEqualStrings("example string", s.get());
    try std.testing.expect(s.len() == 14);

    try s.set(allocator, "hello");
    try std.testing.expectEqualStrings("hello", s.get());
    try std.testing.expect(s.len() == 5);

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings("hello", allocating.written());

    const long_text = "this is a string with spaces\t and identations";
    try s.set(allocator, long_text);
    try std.testing.expectEqualStrings(long_text, s.get());
    try std.testing.expect(s.len() == long_text.len);

    allocating.clearRetainingCapacity();
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(long_text, allocating.written());

    try s.set(allocator, "");
    try std.testing.expectEqualStrings("", s.get());
    try std.testing.expect(s.len() == 0);

    allocating.clearRetainingCapacity();
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings("", allocating.written());

    const special = "line1\nline2\tend";
    try s.set(allocator, special);
    try std.testing.expectEqualStrings(special, s.get());
    try std.testing.expect(s.len() == special.len);

    allocating.clearRetainingCapacity();
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(special, allocating.written());

    const with_null = "abc\x00def";
    try s.set(allocator, with_null);
    try std.testing.expectEqualStrings(s.get(), with_null);
    try std.testing.expect(s.len() == with_null.len);

    allocating.clearRetainingCapacity();
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(allocating.written(), with_null);

    const cases = [_][]const u8{
        "a",
        "ab",
        "abc",
        "abcd",
        "abcde",
        "a much much longer string than before to test realloc behavior",
    };

    for (cases) |c| {
        try s.set(allocator, c);
        try std.testing.expectEqualStrings(c, s.get());
        try std.testing.expect(s.len() == c.len);

        allocating.clearRetainingCapacity();
        try s.serializeContentToWriter(&allocating.writer);
        try std.testing.expectEqualStrings(c, allocating.written());
    }
}
