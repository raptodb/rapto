//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of reply builder and task processor.

const std = @import("std");
const status = @import("Reply/status.zig");
const dispatcher = @import("Reply/dispatcher.zig");

const Memory = @import("Memory.zig");
const Module = @import("Reply/Module.zig");
const Task = @import("Task.zig");
const Reply = @This();

const HeaderType: type = u32;

allocating: std.Io.Writer.Allocating,
memory: *Memory,
static_size: u32,

pub fn init(memory: *Memory, static_size: u32) error{OutOfMemory}!Reply {
    return .{
        .allocating = try .initCapacity(memory.allocator, static_size),
        .memory = memory,
        .static_size = static_size,
    };
}

pub fn deinit(self: *Reply) void {
    self.allocating.deinit();
}

/// Processes a task and builds the reply.
/// The returned slice is valid until the next call to `process`.
pub fn process(self: *Reply, task: *const Task) error{ OutOfMemory, Shutdown }![]const u8 {
    self.clearAndShrink();
    const module: Module = .init(self.memory, &self.allocating.writer);

    var iterator = task.iterator();
    while (iterator.next()) |maybe_query| {
        const header_offset = try self.reserveHeader(HeaderType);

        const maybe_error = if (maybe_query) |query| blk: {
            var mut_query = query;
            break :blk dispatcher.dispatch(module, &mut_query);
        } else |err| blk: {
            // parsing errors should be handled by
            // the client, thus this branch is cold
            @branchHint(.cold);
            break :blk status.write(module.writer, status.fromParseError(err));
        };

        // if catches an error, it is considered a fatal error
        maybe_error catch |err| switch (err) {
            inline error.OutOfMemory,
            error.Shutdown,
            => |e| e,
            // assuming always writer of module is derived
            // by std.Io.Writer.Allocating, an error about
            // write is always OOM
            error.WriteFailed => error.OutOfMemory,
        };

        const length = module.writer.end - header_offset - @sizeOf(HeaderType);
        self.writeOffset(HeaderType, @intCast(length), header_offset);
    }

    return self.allocating.written();
}

fn reserveHeader(self: *Reply, comptime T: type) error{WriteFailed}!u64 {
    const header_offset = self.allocating.writer.end;
    self.allocating.writer.writeInt(T, 0, .little);
    return header_offset;
}

fn clearAndShrink(self: *Reply) void {
    const allocator = self.allocating.allocator;
    var list = self.allocating.toArrayList();
    if (list.capacity > self.static_size) list.shrinkAndFree(allocator, self.static_size);
    self.allocating = .fromArrayList(allocator, &list);
    self.allocating.clearRetainingCapacity();
}

fn writeOffset(self: *Reply, comptime T: type, value: T, offset: u64) void {
    const writer = self.allocating.writer;
    std.mem.writeInt(
        T,
        writer.buffer[offset .. offset + @sizeOf(T)][0..@sizeOf(T)],
        value,
        .little,
    );
}
