//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of query dispatcher.

const std = @import("std");
const status = @import("status.zig");

const Module = @import("Module.zig");
const Query = @import("../Task.zig").Query;

/// Union of all errors can be returned
/// from any functions of Module.
pub const DispatchError = error{
    KeyNotFound, // code 1
    InvalidKey,
    InvalidFormat,
    MissingTokens,
    MismatchType,
    UnknownType,
    MismatchFlag,
    MathOverflow,
    RangeOverflow,
};

/// Dispatch wraps handle by passing context improving modularity, response
/// is written in the buffer of the writer. Errors returned by handle are
/// subdivided in dispatch errors and fatal errors. Dispatch errors are
/// written in writer buffer, while fatal errors are returned directly.
/// NOTE: The writer is assumed to be derived from std.Io.Writer.Allocating.
pub fn dispatch(module: Module, query: *Query) error{ WriteFailed, OutOfMemory, Shutdown }!void {
    const writer = module.writer;
    const start_offset = writer.end;

    const response = handle(module, query) catch |fatal| {
        @branchHint(.cold);
        return fatal;
    };

    // response is written in the buffer,
    // in this case OK is implicit
    if (writer.end != start_offset) return;

    return switch (response) {
        .ok => status.write(writer, .OK),
        .err => |err| status.write(writer, status.fromDispatchError(err)),
    };
}

const Response = union(enum) { ok, err: DispatchError };

/// Handles command, executing and writing response into ctx.writer.
/// If error is occurred, returns it as DispatchError.
fn handle(module: Module, query: *Query) error{ WriteFailed, OutOfMemory, Shutdown }!Response {
    // handle command and writes result from writer of ctx
    // zig fmt: off
    const maybe_error = switch (query.command) {
        .PING   => module.ping(query),
 
        // CRUD operations
        .SET    => module.set(query),
        .GET    => module.get(query),
        .UPDATE => module.update(query),
        .DEL    => module.del(query),
 
        .COPY   => module.copy(query),
        .RENAME => module.rename(query),
        .COUNT  => module.count(query),
        .TYPE   => module.type(query),
        .LIST   => module.list(query),
        .EXIST  => module.exist(query),
        .ERASE  => module.erase(query),
 
        .DOWN   => error.Shutdown,
    };
    // zig fmt: on

    maybe_error catch |err| return switch (err) {
        else => .{ .err = @errorCast(err) },
        inline error.OutOfMemory,
        error.WriteFailed,
        error.Shutdown,
        => |e| return e,
    };

    return .ok;
}
