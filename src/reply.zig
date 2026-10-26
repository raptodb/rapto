//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of reply.

const std = @import("std");
const frames = @import("frames.zig");
const value = @import("value.zig");

pub const ErrorCode = enum(u8) {
    key_not_found = 0,
    invalid_key,
    invalid_format,
    missing_tokens,
    mismatch_type,
    unknown_type,
    math_overflow,
    range_overflow,
    unknown_command,
    locked,
    key_already_exists,

    unknown = std.math.maxInt(u8),

    pub fn fromContent(content: []const u8) error{InvalidFormat}!ErrorCode {
        if (content.len != 1) return error.InvalidFormat;
        return std.enums.fromInt(ErrorCode, content[0]) orelse unreachable;
    }

    pub fn serializeToWriter(code: ErrorCode, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeInt(u8, @backingInt(code), .little);
    }

    pub fn fromError(err: anyerror) ErrorCode {
        return switch (err) {
            error.KeyNotFound => .key_not_found,
            error.InvalidKey => .invalid_key,
            error.InvalidFormat => .invalid_format,
            error.MissingTokens => .missing_tokens,
            error.MismatchType => .mismatch_type,
            error.UnknownType => .unknown_type,
            error.MathOverflow => .math_overflow,
            error.RangeOverflow => .range_overflow,
            error.UnknownCommand => .unknown_command,
            error.Locked => .locked,
            error.KeyAlreadyExists => .key_already_exists,
            else => .unknown,
        };
    }
};

pub fn writeValue(writer: *std.Io.Writer, val: value.Union) std.Io.Writer.Error!void {
    return val.serializeToWriter(writer);
}

pub fn writeError(writer: *std.Io.Writer, err_code: ErrorCode) std.Io.Writer.Error!void {
    try writer.writeInt(u8, std.math.maxInt(u8), .little);
    try err_code.serializeToWriter(writer);
}
