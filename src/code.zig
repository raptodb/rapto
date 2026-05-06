//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of code writer.

const std = @import("std");

const CommandError = @import("state_machine.zig").CommandError;
const ParseError = @import("Task.zig").Query.Error;

pub const Code = enum(u8) {
    // Success (0-99)
    OK = 0,

    // Command errors from StateMachine (100-199)
    CommandKeyNotFound = 100,
    CommandInvalidKey,
    CommandInvalidFormat,
    CommandMissingTokens,
    CommandMismatchType,
    CommandUnknownType,
    CommandMismatchFlag,
    CommandMathOverflow,
    CommandRangeOverflow,
    CommandMapKeyNotFound,

    // Parse errors from Query (200+)
    ParseUnknownCommand = 200,
    ParseUnknownFlag,
    ParseInvalidFormat,
};

pub fn writeCode(writer: *std.Io.Writer, code: Code) std.Io.Writer.Error!void {
    return writer.writeByte(@intFromEnum(code));
}

pub fn fromCommandError(err: CommandError) Code {
    return switch (err) {
        error.KeyNotFound => .CommandKeyNotFound,
        error.InvalidKey => .CommandInvalidKey,
        error.InvalidFormat => .CommandInvalidFormat,
        error.MissingTokens => .CommandMissingTokens,
        error.MismatchType => .CommandMismatchType,
        error.UnknownType => .CommandUnknownType,
        error.MismatchFlag => .CommandMismatchFlag,
        error.MathOverflow => .CommandMathOverflow,
        error.RangeOverflow => .CommandRangeOverflow,
        error.MapKeyNotFound => .CommandMapKeyNotFound,
    };
}

pub fn fromParseError(err: ParseError) Code {
    return switch (err) {
        error.UnknownCommand => .ParseUnknownCommand,
        error.UnknownFlag => .ParseUnknownFlag,
        error.InvalidFormat => .ParseInvalidFormat,
    };
}
