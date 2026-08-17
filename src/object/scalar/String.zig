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

ptr: *std.ArrayList(u8),

pub fn initFromContent(
    allocator: std.mem.Allocator,
    content: []const u8,
) std.mem.Allocator.Error!String {
    const list_ptr = try allocator.create(std.ArrayList(u8));
    errdefer allocator.destroy(list_ptr);
    list_ptr.* = try .initCapacity(allocator, content.len);
    list_ptr.appendSliceAssumeCapacity(content);
    return .{ .ptr = list_ptr };
}

pub fn deinit(self: String, allocator: std.mem.Allocator) void {
    self.ptr.deinit(allocator);
    allocator.destroy(self.ptr);
}

pub fn set(
    self: String,
    allocator: std.mem.Allocator,
    content: []const u8,
) std.mem.Allocator.Error!void {
    try self.resize(allocator, content.len);
    @memcpy(self.ptr.items[0..content.len], content);
}

/// Inserts string at specific index. Assumes index is in bounds
pub fn insert(
    self: String,
    allocator: std.mem.Allocator,
    index: u64,
    content: []const u8,
) std.mem.Allocator.Error!void {
    try self.ptr.ensureTotalCapacityPrecise(allocator, self.len() + content.len);
    self.ptr.insertSliceAssumeCapacity(index, content);
}

/// Replaces string at specific index. Assumes index is in bounds.
pub fn replace(
    self: String,
    index: u64,
    content: []const u8,
) (std.mem.Allocator.Error || error{RangeOverflow})!void {
    if (index +| content.len > self.len()) return error.RangeOverflow;
    self.ptr.replaceRangeAssumeCapacity(index, content.len, content);
}

pub fn dupe(self: String, allocator: std.mem.Allocator) std.mem.Allocator.Error!String {
    return .initFromContent(allocator, self.get());
}

pub fn get(self: String) []const u8 {
    return self.ptr.items;
}

pub fn len(self: String) u64 {
    return self.get().len;
}

pub fn serializeContentToWriter(self: String, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(self.get());
}

fn resize(self: String, allocator: std.mem.Allocator, new_len: u64) std.mem.Allocator.Error!void {
    if (self.len() > new_len) {
        try self.ptr.shrinkAndFreePrecise(allocator, new_len);
    } else if (self.len() < new_len) {
        try self.ptr.ensureTotalCapacityPrecise(allocator, new_len);
        self.ptr.expandToCapacity();
    }
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
