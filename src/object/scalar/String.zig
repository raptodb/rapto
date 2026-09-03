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

pub const Error = std.mem.Allocator.Error || error{InvalidFormat};

/// Pointer to byte array. The first 4 bytes
/// header represents the length of string.
ptr: [*]u8,

pub const Header = u32;

pub fn initFromContent(allocator: std.mem.Allocator, content: []const u8) Error!String {
    if (content.len -| @sizeOf(Header) > std.math.maxInt(u32)) return error.InvalidFormat;

    const str = try allocator.alloc(u8, @sizeOf(Header) + content.len);
    var self: String = .{ .ptr = str.ptr };
    self.setLen(@truncate(content.len));
    try self.set(allocator, content);

    return self;
}

pub fn deinit(self: String, allocator: std.mem.Allocator) void {
    allocator.free(self.allocatedSlice());
}

pub fn set(
    self: *String,
    allocator: std.mem.Allocator,
    content: []const u8,
) Error!void {
    if (content.len -| @sizeOf(Header) > std.math.maxInt(u32)) return error.InvalidFormat;

    const length = self.len();
    const content_length: u32 = @truncate(content.len);

    if (length != content_length) {
        const slice: []u8 = try allocator.realloc(
            self.ptr[0 .. @sizeOf(Header) + length],
            @sizeOf(Header) + content_length,
        );

        self.ptr = slice.ptr;
        self.setLen(content_length);
    }

    @memcpy(self.getMutable(), content);
}

/// Inserts string at specific offset. Assumes offset is in bounds.
pub fn insert(
    self: *String,
    allocator: std.mem.Allocator,
    index: u32,
    content: []const u8,
) Error!void {
    if (content.len -| (std.math.maxInt(u32) - self.len()) > 0) return error.InvalidFormat;

    const old_len = self.len();
    const new_len = old_len + @as(u32, @truncate(content.len));

    var str: std.ArrayList(u8) = .fromOwnedSlice(self.allocatedSlice());
    try str.ensureTotalCapacityPrecise(allocator, @sizeOf(Header) + new_len);
    str.insertSliceAssumeCapacity(@sizeOf(Header) + index, content);
    self.ptr = str.toOwnedSliceAssert().ptr;

    self.setLen(new_len);
}

/// Replaces string at specific offset. Assumes offset is in bounds.
pub fn replace(
    self: *String,
    index: u32,
    content: []const u8,
) (Error || error{RangeOverflow})!void {
    if (index +| content.len > self.len()) return error.RangeOverflow;
    var str: std.ArrayList(u8) = .fromOwnedSlice(self.allocatedSlice());
    str.replaceRangeAssumeCapacity(@sizeOf(Header) + index, content.len, content);
    self.ptr = str.toOwnedSliceAssert().ptr;
}

pub fn dupe(self: String, allocator: std.mem.Allocator) std.mem.Allocator.Error!String {
    const buf = try allocator.dupe(u8, self.allocatedSlice());
    return .{ .ptr = buf.ptr };
}

pub fn get(self: String) []const u8 {
    return self.ptr[@sizeOf(Header) .. @sizeOf(Header) + self.len()];
}

fn setLen(self: String, length: u32) void {
    std.mem.writeInt(Header, self.ptr[0..@sizeOf(Header)], length, .little);
}

fn getMutable(self: String) []u8 {
    return self.ptr[@sizeOf(Header) .. @sizeOf(Header) + self.len()];
}

fn allocatedSlice(self: String) []u8 {
    return self.ptr[0 .. @sizeOf(Header) + self.len()];
}

/// Returns logical length of string content, excluding header.
pub fn len(self: String) u32 {
    return std.mem.readInt(Header, self.ptr[0..@sizeOf(Header)], .little);
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

    allocating.clearRetainingCapacity();
    try s.set(allocator, "heo");
    try s.insert(allocator, 2, "ll");
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(allocating.written(), "hello");

    allocating.clearRetainingCapacity();
    try s.set(allocator, "hello");
    try s.insert(allocator, s.len(), " world");
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(allocating.written(), "hello world");

    allocating.clearRetainingCapacity();
    try s.set(allocator, "world");
    try s.insert(allocator, 0, "hello ");
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(allocating.written(), "hello world");

    allocating.clearRetainingCapacity();
    try s.set(allocator, "hello mars");
    try s.replace(6, "worl");
    try s.insert(allocator, s.len(), "d");
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(allocating.written(), "hello world");

    allocating.clearRetainingCapacity();
    try s.set(allocator, "aaaabbbaa");
    try s.replace(4, "aaa");
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(allocating.written(), "aaaaaaaaa");

    allocating.clearRetainingCapacity();
    try s.set(allocator, "text");
    try s.replace(0, "word");
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(allocating.written(), "word");

    try s.set(allocator, "text2");
    try std.testing.expectError(
        error.RangeOverflow,
        s.replace(0, "long-text"),
    );

    try s.set(allocator, "mom");
    try std.testing.expectError(
        error.RangeOverflow,
        s.replace(s.len(), "m"),
    );

    allocating.clearRetainingCapacity();
    try s.set(allocator, "pool");
    try s.replace(s.len(), "");
    try s.serializeContentToWriter(&allocating.writer);
    try std.testing.expectEqualStrings(allocating.written(), "pool");

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
