//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of query executor.

/// Query executor on Memory instance.
const StateMachine = @This();

const std = @import("std");
const status = @import("StateMachine/status.zig");
const assert = std.debug.assert;

const Memory = @import("Memory.zig");
const Module = @import("StateMachine/Module.zig");
const Query = @import("Task.zig").Query;

memory: *Memory,

/// Union of all errors can be returned
/// from any functions of Module.
pub const DispatchError = error{
    KeyNotFound,
    InvalidKey,
    InvalidFormat,
    MissingTokens,
    MismatchType,
    UnknownType,
    MismatchFlag,
    MathOverflow,
    RangeOverflow,
};

pub fn init(memory: *Memory) StateMachine {
    return .{ .memory = memory };
}

/// Executes query on this configuration. Fatal errors will be returned
/// directly instead of Dispatch errors, these will be written on writer.
/// If no error is occurred, writes OK code to output.
pub fn execute(
    self: StateMachine,
    query: *const Query, // Input
    writer: *std.Io.Writer, // Output: maybe Allocating
) error{ OutOfMemory, Shutdown, WriteFailed }!void {
    const module: Module = .init(self.memory, writer, query);

    const start_offset = writer.end;
    const response = dispatch(module) catch |fatal| {
        @branchHint(.cold);
        return fatal;
    };

    // When response is written in buffer, it is implicit OK.
    // While, when noreply is enabled, response is not written.
    if (writer.end != start_offset or query.flags.noreply.get()) return;

    return switch (response) {
        .ok => status.writeCode(writer, .OK),
        .err => |err| status.writeCode(writer, status.fromDispatchError(err)),
    };
}

const Response = union(enum) { ok, err: DispatchError };

/// Dispatches command, executing and writing response into ctx.writer.
/// If error is occurred, returns it as DispatchError.
inline fn dispatch(module: Module) error{ WriteFailed, OutOfMemory, Shutdown }!Response {
    const query = module.query;

    // zig fmt: off
    const maybe_error = switch (query.command) {
        .PING   => module.ping(),
 
        // CRUD operations
        .SET    => module.set(),
        .GET    => module.get(),
        .UPDATE => module.update(),
        .DEL    => module.del(),
 
        .COPY   => module.copy(),
        .RENAME => module.rename(),
        .COUNT  => module.count(),
        .TYPE   => module.type(),
        .LIST   => module.list(),
        .EXIST  => module.exist(),
        .ERASE  => module.erase(),
 
        .DOWN   => error.Shutdown,
    };
    // zig fmt: on

    maybe_error catch |err| return switch (err) {
        else => .{ .err = @errorCast(err) },
        error.OutOfMemory,
        error.WriteFailed,
        error.Shutdown,
        => |e| return e,
    };

    return .ok;
}
