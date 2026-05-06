//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of task.

/// Indipendent collection of operations for
/// the StateMachine execution. It contains
/// pipeline of queries and its metadata.
const Task = @This();

const std = @import("std");
const frames = @import("frames.zig");

pub const Query = @import("Task/Query.zig");

/// Microsecond timestamp used to track when the task was
/// executed. This indicator is useful also for unique id.
timestamp: u64,
/// Pipeline containing the raw queries to be executed.
pipeline: []const u8,

/// Initializes a task with pipeline and timestamp without
/// taking the ownership of the pipeline. The timestamp is
/// expressed in microseconds, useful for tracking execution
/// time and to identify tasks.
pub fn init(pipeline: []const u8, timestamp: std.Io.Timestamp) Task {
    return .{
        .pipeline = pipeline,
        .timestamp = @intCast(timestamp.toMicroseconds()),
    };
}

/// Iterator of queries.
pub const Iterator = struct {
    wrapped_iterator: frames.Iterator,

    /// Returns the next query in the pipeline.
    pub fn next(self: *Iterator) ?Query.Error!Query {
        const frame = self.wrapped_iterator.next() orelse return null;
        return .parse(frame);
    }
};

pub fn iterator(self: *const Task) Iterator {
    return .{ .wrapped_iterator = .init(self.pipeline) };
}

const Hasher = std.hash.crc.Crc32Iscsi;

pub fn serializeToWriter(self: *const Task, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const hasher_instance: Hasher = .init();
    var hashed_writer: std.Io.Writer.Hashed(Hasher) = .initHasher(
        writer,
        hasher_instance,
        &.{},
    );

    try hashed_writer.writer.writeInt(u64, self.timestamp, .little);
    try hashed_writer.writer.writeAll(self.pipeline);
    try hashed_writer.writer.writeInt(u32, hashed_writer.hasher.final(), .little);
}

/// Initializes Task by deserializing buffer. It does not takes ownership.
pub fn deserialize(buf: []u8) error{ InvalidFormat, ChecksumMismatch }!Task {
    if (buf.len < @sizeOf(u32)) return error.InvalidFormat;

    const raw_task = buf[0 .. buf.len - @sizeOf(u32)];

    const hash: u32 = @bitCast(buf[buf.len - @sizeOf(u32) ..][0..@sizeOf(u32)].*);
    const taken_hash = Hasher.hash(raw_task);
    if (hash != taken_hash) return error.ChecksumMismatch;

    var reader: std.Io.Reader = .fixed(raw_task);

    const timestamp = reader.takeInt(u64, .little) catch
        return error.InvalidFormat;
    const pipeline = reader.take(reader.bufferedLen()) catch
        return error.InvalidFormat;

    return .{ .timestamp = timestamp, .pipeline = pipeline };
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
        .{ .command = .ping, .flags = .{}, .args = &.{} },
        .{ .command = .set, .flags = .{ .noreply = .init(true) }, .args = &.{} },
        .{ .command = .get, .flags = .{}, .args = &.{"k"} },
        .{ .command = .copy, .flags = .{}, .args = &.{ "k1", "k2" } },
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
    defer allocator.free(pipeline);
    const task: Task = .init(pipeline, std.Io.Timestamp.now(io, .awake));

    try std.testing.expect(task.timestamp != 0);

    var it = task.iterator();
    for (queries) |expected| {
        const q = try it.next().?;
        try std.testing.expectEqual(expected.command, q.command);
        try std.testing.expectEqual(expected.flags.noreply.get(), q.flags.noreply.get());
        var args = q.argsIterator();
        for (expected.args) |expected_arg|
            try std.testing.expectEqualStrings(expected_arg, args.next().?);
        try std.testing.expectEqual(null, args.next());
    }

    try std.testing.expectEqual(null, it.next());

    allocating.clearRetainingCapacity();

    try task.serializeToWriter(writer);
    const serialized = writer.buffered();
    const task_clone: Task = try .deserialize(serialized);

    it = task.iterator();
    var it2 = task_clone.iterator();
    while (it.next()) |maybe_expected| {
        var expected = try maybe_expected;
        const a = try it2.next().?;
        try std.testing.expect(expected.isEqualTo(&a));
    }
}
