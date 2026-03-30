//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of task.

const std = @import("std");

pub const Query = @import("Task/Query.zig");
const Task = @This();

/// Pipeline containing the raw queries to be executed. The format
/// of the pipeline is a sequence of length-prefixed queries.
/// Format [len:u32][query][len:u32][query]...
pipeline: []const u8,
/// Timestamp used to track when the task was executed.
timestamp: u64,
/// Callback function to send reply to source of the Task.
replyFn: ?replyFnType,

const replyFnType = *const fn (
    ctx: *anyopaque,
    header: []const u8,
    data: [][]const u8,
) anyerror!void;

/// Initializes a task with the given reply callback function and pipeline.
/// The timestamp is set to the current time in nanoseconds,
/// useful for tracking execution time and to identify tasks.
/// This function assumes ownership of the pipeline.
pub fn init(pipeline: []const u8, replyFn: ?replyFnType) Task {
    return .{
        .pipeline = pipeline,
        .timestamp = @intCast(std.time.nanoTimestamp()),
        .replyFn = replyFn,
    };
}
pub fn deinit(self: *const Task, allocator: std.mem.Allocator) void {
    allocator.free(self.pipeline);
}

/// Iterator of queries.
pub const Iterator = struct {
    reader: std.Io.Reader,

    fn init(pipeline: []const u8) Iterator {
        return .{ .reader = .fixed(pipeline) };
    }

    /// Returns the next query in the pipeline.
    pub fn next(
        self: *Iterator,
    ) ?error{ UnknownCommand, MismatchType, UnknownFlag, InvalidFormat }!Query {
        const len = self.reader.takeInt(u32, .little) catch return null;
        const query = self.reader.take(len) catch return null;
        return try .parse(query);
    }
};
