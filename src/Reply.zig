//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of reply builder and task processor.

/// Reply builder by processing Task(s).
const Reply = @This();

const std = @import("std");
const status = @import("Reply/status.zig");
const dispatcher = @import("Reply/dispatcher.zig");
const assert = std.debug.assert;

const Memory = @import("Memory.zig");
const Module = @import("Reply/Module.zig");
const Task = @import("Task.zig");

pub const Config = struct {
    /// Minimum size of Allocating. This optimizes the
    /// allocation/deallocation overhead.
    /// Static size is allocated on initialization time
    /// and never deallocated until `.deinit()` method.
    static_size: u32 = 16 * 1024,
    /// If noreply is enabled, forces noreply
    /// flag to true for all queries.
    noreply: bool = false,
};

allocating: std.Io.Writer.Allocating,
memory: *Memory,

config: Config,

pub fn init(memory: *Memory, config: Config) error{OutOfMemory}!Reply {
    return .{
        .allocating = try .initCapacity(memory.allocator, config.static_size),
        .memory = memory,
        .config = config,
    };
}

pub fn deinit(self: *Reply) void {
    self.allocating.deinit();
}

/// Processes a task and builds the reply.
/// The returned slice is valid until the next call to this function.
pub fn processTask(self: *Reply, task: *const Task) error{ OutOfMemory, Shutdown }![]const u8 {
    // if catches an error, it is considered a
    // fatal error to be returned directly
    return self.processTaskUnmapped(task) catch |err| switch (err) {
        inline error.OutOfMemory,
        error.Shutdown,
        => |e| e,
        // assuming always writer of module is derived
        // by std.Io.Writer.Allocating, an error about
        // write is always OOM
        error.WriteFailed => error.OutOfMemory,
    };
}

fn processTaskUnmapped(
    self: *Reply,
    task: *const Task,
) error{ WriteFailed, OutOfMemory, Shutdown }![]const u8 {
    self.clearAndShrink();
    const module: Module = .init(self.memory, &self.allocating.writer);

    var iterator = task.iterator();
    while (iterator.next()) |maybe_query| {
        const header_offset = try self.reserveHeader(u32);

        if (maybe_query) |query| {
            var mut_query = query;
            if (self.config.noreply) mut_query.flags = .{ .noreply = .init(true) };

            try dispatcher.dispatch(module, &mut_query);
        } else |err| {
            // parsing errors should be handled by
            // the client, thus this branch is cold
            @branchHint(.cold);
            try status.writeCode(module.writer, status.fromParseError(err));

            assert(module.writer.end - header_offset - @sizeOf(u32) == 1);
        }

        const length = module.writer.end - header_offset - @sizeOf(u32);
        self.writeOffset(u32, @intCast(length), header_offset);
    }

    return self.allocating.written();
}

fn reserveHeader(self: *Reply, comptime T: type) error{WriteFailed}!u64 {
    const header_offset = self.allocating.writer.end;
    try self.allocating.writer.writeInt(T, 0, .little);
    return header_offset;
}

fn clearAndShrink(self: *Reply) void {
    const allocator = self.allocating.allocator;
    var list = self.allocating.toArrayList();
    defer self.allocating = .fromArrayList(allocator, &list);

    if (list.capacity > self.config.static_size) {
        list.shrinkAndFree(allocator, self.config.static_size);
    }
    list.clearRetainingCapacity();
}

fn writeOffset(self: *Reply, comptime T: type, value: T, offset: u64) void {
    const writer = self.allocating.writer;

    assert(writer.buffer.len >= @sizeOf(T));
    assert(writer.buffer.len >= offset + @sizeOf(T));

    std.mem.writeInt(
        T,
        writer.buffer[offset .. offset + @sizeOf(T)][0..@sizeOf(T)],
        value,
        .little,
    );
}
