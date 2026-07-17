//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of code writer.

const std = @import("std");

const CommandError = @import("state_machine.zig").CommandError;
const ParseError = @import("Pipeline/Query.zig").Error;

pub const Code = enum(u8) {
    // Success (0-99)
    ok = 0,

    key_not_found = 100,
    invalid_key,
    invalid_format,
    missing_tokens,
    mismatch_type,
    unknown_type,
    missing_flag,
    math_overflow,
    range_overflow,
    map_key_not_found,
    duplicated_key,
    unknown_command,

    pub fn writeError(code: Code, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeInt(u8, @intFromEnum(code), .little);
    }

    pub fn from(err: anyerror) Code {
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
            else => unreachable,
        };
    }
};
