//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of void field.

const std = @import("std");

/// Void field type represented as "void" string. Indicates a empty value.
const Void = @This();

pub fn init() Void {
    return .{};
}

pub fn set(_: *Void) void {
    // nothing
}

pub fn get(_: Void) void {
    // nothing
}

pub fn len(_: Void) u64 {
    return 0;
}

pub fn serializeContentToWriter(_: Void, _: *std.Io.Writer) void {
    // nothing
}

test "Void" {
    var s: Void = .init();

    try std.testing.expectEqual(void{}, s.get());
    try std.testing.expect(s.len() == 0);
}
