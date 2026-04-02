//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of reply code serializer.

const std = @import("std");

const DispatchError = @import("../Reply/dispatcher.zig").DispatchError;
const ParseError = @import("../Task.zig").Query.ParseError;

pub const Code = enum(u8) {
    // success
    OK = 0,

    // dispatch errors (1–9)
    KeyNotFound = 1,
    InvalidKey,
    InvalidFormat,
    MissingTokens,
    MismatchType,
    UnknownType,
    MismatchFlag,
    MathOverflow,
    RangeOverflow,

    // parse errors (10+)
    ParseUnknownCommand = 10,
    ParseMismatchType,
    ParseUnknownFlag,
    ParseInvalidFormat,
};

pub fn write(writer: *std.Io.Writer, code: Code) error{WriteFailed}!void {
    return writer.writeByte(@intFromEnum(code));
}

pub fn fromDispatchError(err: DispatchError) Code {
    return switch (err) {
        error.KeyNotFound => .KeyNotFound,
        error.InvalidKey => .InvalidKey,
        error.InvalidFormat => .InvalidFormat,
        error.MissingTokens => .MissingTokens,
        error.MismatchType => .MismatchType,
        error.UnknownType => .UnknownType,
        error.MismatchFlag => .MismatchFlag,
        error.MathOverflow => .MathOverflow,
        error.RangeOverflow => .RangeOverflow,
    };
}

pub fn fromParseError(err: ParseError) Code {
    return switch (err) {
        error.UnknownCommand => .ParseUnknownCommand,
        error.MismatchType => .ParseMismatchType,
        error.UnknownFlag => .ParseUnknownFlag,
        error.InvalidFormat => .ParseInvalidFormat,
    };
}
