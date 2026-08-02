//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of reply.

const std = @import("std");
const frames = @import("frames.zig");
const assert = std.debug.assert;

const Value = @import("object.zig").Value;

pub const ListSerializer = Value.List.Serializer;
pub const MapSerializer = Value.Map.Serializer;

pub const ErrorCode = enum(u8) {
    key_not_found = 0,
    invalid_key,
    invalid_format,
    missing_tokens,
    mismatch_type,
    unknown_type,
    math_overflow,
    range_overflow,
    map_key_not_found,
    duplicated_key,
    unknown_command,

    unknown = std.math.maxInt(u8),

    pub fn fromContent(content: []const u8) error{InvalidFormat}!ErrorCode {
        if (content.len != 1) return error.InvalidFormat;
        return std.enums.fromInt(ErrorCode, content[0]) orelse unreachable;
    }

    pub fn serializeToWriter(code: ErrorCode, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeInt(u8, @intFromEnum(code), .little);
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
            error.MapKeyNotFound => .map_key_not_found,
            error.DuplicatedKey => .duplicated_key,
            error.UnknownCommand => .unknown_command,
            else => .unknown,
        };
    }
};

pub fn writeValue(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    return Value.serializeToWriter(writer, value);
}

/// Method to serialize error as serializing value with `serializeToWriter`.
pub fn writeError(writer: *std.Io.Writer, err_code: ErrorCode) std.Io.Writer.Error!void {
    try writer.writeInt(u8, std.math.maxInt(u8), .little);
    try err_code.serializeToWriter(writer);
}

pub fn writeSerialized(
    writer: *std.Io.Writer,
    value_type: Value.Type,
    content: []const u8,
) std.Io.Writer.Error!void {
    try value_type.serializeToWriter(writer);
    return writer.writeAll(content);
}
