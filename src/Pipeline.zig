//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of query and reply pipeline.

const Pipeline = @This();

const std = @import("std");
const frames = @import("frames.zig");
const assert = std.debug.assert;

pub const Config = struct {
    /// Minimum size for Query and Reply. This optimizes the
    /// allocation/deallocation overhead.
    /// The preserved size is allocated at initialization time
    /// and is never deallocated until the `.deinit()` method.
    preserved_size: u64,
};

config: Config,

start_segment_index: u64 = 0,
allocating: std.Io.Writer.Allocating,

pub fn init(allocator: std.mem.Allocator, config: Config) std.mem.Allocator.Error!Pipeline {
    return .{
        .config = config,
        .allocating = try .initCapacity(allocator, config.preserved_size),
    };
}

pub fn deinit(self: *Pipeline) void {
    self.allocating.deinit();
}

pub fn reset(self: *Pipeline) void {
    self.start_segment_index = 0;
    resizeAllocating(&self.allocating, self.config.preserved_size);
}

pub fn take(self: *Pipeline) []const u8 {
    const content = self.peek();
    self.start_segment_index = self.writer().end;
    return content;
}

pub fn peek(self: *Pipeline) []const u8 {
    const w = self.writer();
    return w.buffer[self.start_segment_index..w.end];
}

pub fn addManyAsSlice(self: *Pipeline, n: u64) std.mem.Allocator.Error![]u8 {
    const w = self.writer();
    try self.allocating.ensureUnusedCapacity(n);
    const start = w.end;
    w.advance(n);
    return w.buffer[start..w.end];
}

pub fn writer(self: *Pipeline) *std.Io.Writer {
    return &self.allocating.writer;
}

pub fn beginFrame(self: *Pipeline) std.mem.Allocator.Error!frames.Builder {
    return frames.Builder.begin(self.writer()) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
    };
}

fn resizeAllocating(allocating: *std.Io.Writer.Allocating, preserved_size: u64) void {
    if (allocating.writer.buffer.len > preserved_size) {
        @branchHint(.unlikely);
        shrinkAllocating(allocating, preserved_size);
    }
    return allocating.clearRetainingCapacity();
}

fn shrinkAllocating(allocating: *std.Io.Writer.Allocating, preserved_size: u64) void {
    assert(allocating.writer.buffer.len > preserved_size);

    var list = allocating.toArrayList();
    defer allocating.* = .fromArrayList(allocating.allocator, &list);

    list.shrinkAndFree(allocating.allocator, preserved_size);
}

test "Pipeline" {
    const allocator = std.testing.allocator;

    var pipeline: Pipeline = try .init(allocator, .{ .preserved_size = 16 });
    defer pipeline.deinit();
    var w = pipeline.writer();

    try w.writeAll("abc");
    try std.testing.expectEqualStrings("abc", pipeline.take());

    try w.writeAll("def");
    try std.testing.expectEqualStrings("def", pipeline.take());

    try std.testing.expect(pipeline.take().len == 0);

    const capacity_before = pipeline.allocating.writer.buffer.len;
    pipeline.reset();
    try std.testing.expectEqual(capacity_before, pipeline.allocating.writer.buffer.len);
    try std.testing.expect(w.end == 0);
    try std.testing.expect(pipeline.start_segment_index == 0);

    const big_chunk = [_]u8{'a'} ** 256;
    try w.writeAll(&big_chunk);
    try std.testing.expect(pipeline.allocating.writer.buffer.len > 16);

    pipeline.reset();
    try std.testing.expectEqual(@as(u64, 16), pipeline.allocating.writer.buffer.len);

    try w.writeAll("new");
    try std.testing.expectEqualStrings("new", pipeline.take());
}
