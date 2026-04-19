//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of task.

/// Indipendent operation for dispatch. It contains
/// pipeline of queries and its metadata.
const Task = @This();

const std = @import("std");
const frames = @import("frames.zig");

pub const Query = @import("Task/Query.zig");

/// Pipeline containing the raw queries to be executed.
pipeline: []const u8,
/// Timestamp used to track when the task was executed.
/// This indicator is useful also for unique id.
timestamp: u64,
/// Callback function to send reply to source of the Task.
callbackFn: ?CallbackFnType,

const CallbackFnType = *const fn (ctx: *anyopaque, data: []const u8) anyerror!void;

/// Initializes a task with the given reply callback function and pipeline.
/// The timestamp is set to the current time in nanoseconds,
/// useful for tracking execution time and to identify tasks.
/// This function assumes ownership of the pipeline.
pub fn init(pipeline: []const u8, timestamp: std.Io.Timestamp, callbackFn: ?CallbackFnType) Task {
    return .{
        .pipeline = pipeline,
        .timestamp = @intCast(timestamp.toMicroseconds()),
        .callbackFn = callbackFn,
    };
}

pub fn deinit(self: *const Task, allocator: std.mem.Allocator) void {
    allocator.free(self.pipeline);
}

/// Iterator of queries.
pub const Iterator = struct {
    wrapped_iterator: frames.Iterator,

    /// Returns the next query in the pipeline.
    pub fn next(self: *Iterator) ?Query.ParseError!Query {
        const frame = self.wrapped_iterator.next() orelse return null;
        return .parse(frame);
    }
};

pub fn iterator(self: *const Task) Iterator {
    return .{ .wrapped_iterator = .init(self.pipeline) };
}

test "Task" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();
    const writer = &allocating.writer;

    const queries = [_]struct {
        command: Query.Command,
        flags: Query.Flags,
        args: []const []const u8,
    }{
        .{ .command = .PING, .flags = .{}, .args = &.{} },
        .{ .command = .SET, .flags = .{ .noreply = .init(true) }, .args = &.{} },
        .{ .command = .GET, .flags = .{}, .args = &.{"k"} },
        .{ .command = .COPY, .flags = .{}, .args = &.{ "k1", "k2" } },
    };

    for (queries) |q| {
        var qw: std.Io.Writer.Allocating = .init(allocator);
        defer qw.deinit();
        try Query.serializeToWriter(&qw.writer, q.command, q.flags, q.args);
        const serialized = qw.writer.buffered();
        try writer.writeInt(u32, @truncate(serialized.len), .little);
        try writer.writeAll(serialized);
    }

    const pipeline = try allocator.dupe(u8, writer.buffered());
    const task: Task = .init(pipeline, std.Io.Timestamp.now(io, .awake), null);
    defer task.deinit(allocator);

    try std.testing.expect(task.timestamp != 0);

    var it = task.iterator();
    for (queries) |expected| {
        const q = try it.next().?;
        try std.testing.expectEqual(expected.command, q.command);
        try std.testing.expectEqual(expected.flags.noreply.get(), q.flags.noreply.get());
        var args = q.args;
        for (expected.args) |a|
            try std.testing.expectEqualStrings(a, args.next().?);
        try std.testing.expectEqual(null, args.next());
    }

    try std.testing.expectEqual(null, it.next());
}
