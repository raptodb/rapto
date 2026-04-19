//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of code writer.

const std = @import("std");

const ExecuteError = @import("StateMachine.zig").Error;
const ParseError = @import("Task.zig").Query.Error;

pub const Code = enum(u8) {
    // Success (0-99)
    OK = 0,

    // Execute errors from StateMachine (100-199)
    ExecuteKeyNotFound = 100,
    ExecuteInvalidKey,
    ExecuteInvalidFormat,
    ExecuteMissingTokens,
    ExecuteMismatchType,
    ExecuteUnknownType,
    ExecuteMismatchFlag,
    ExecuteMathOverflow,
    ExecuteRangeOverflow,

    // Parse errors from Query (200+)
    ParseUnknownCommand = 200,
    ParseUnknownFlag,
    ParseInvalidFormat,
};

pub fn writeCode(writer: *std.Io.Writer, code: Code) error{WriteFailed}!void {
    return writer.writeByte(@intFromEnum(code));
}

pub fn fromExecuteError(err: ExecuteError) Code {
    return switch (err) {
        error.KeyNotFound => .ExecuteKeyNotFound,
        error.InvalidKey => .ExecuteInvalidKey,
        error.InvalidFormat => .ExecuteInvalidFormat,
        error.MissingTokens => .ExecuteMissingTokens,
        error.MismatchType => .ExecuteMismatchType,
        error.UnknownType => .ExecuteUnknownType,
        error.MismatchFlag => .ExecuteMismatchFlag,
        error.MathOverflow => .ExecuteMathOverflow,
        error.RangeOverflow => .ExecuteRangeOverflow,
    };
}

pub fn fromParseError(err: ParseError) Code {
    return switch (err) {
        error.UnknownCommand => .ParseUnknownCommand,
        error.UnknownFlag => .ParseUnknownFlag,
        error.InvalidFormat => .ParseInvalidFormat,
    };
}
