//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of void value.

/// Void value type represented as "void" string. Indicates an empty value.
const Void = @This();

const std = @import("std");

pub fn fromContent() Void {
    return .{};
}

pub fn set(_: *Void) void {
    // nothing
}

pub fn get(_: Void) void {
    // nothing
}

pub fn dupe(_: Void) Void {
    return .{};
}

pub fn len(_: Void) u64 {
    return 0;
}

pub fn serializeContentToWriter(_: Void, _: *std.Io.Writer) std.Io.Writer.Error!void {
    // nothing
}

test "Void" {
    var s: Void = .fromContent();

    try std.testing.expectEqual(void{}, s.get());
    try std.testing.expect(s.len() == 0);
}
