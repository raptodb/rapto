//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of IO/serialization pipeline.

const Pipeline = @This();

const std = @import("std");
const frames = @import("frames.zig");
const assert = std.debug.assert;

pub const Config = struct {
    /// Minimum size for write/read buffers. This optimizes the
    /// allocation/deallocation overhead.
    /// The preserved size is allocated at initialization time
    /// and is never deallocated until the `.deinit()` method.
    preserved_size: u64,
};

config: Config,

write_buffer: std.Io.Writer.Allocating,
read_buffer: std.Io.Writer.Allocating,

pub fn init(allocator: std.mem.Allocator, config: Config) std.mem.Allocator.Error!Pipeline {
    const preserved_size = @divFloor(config.preserved_size, 2);
    return .{
        .config = config,
        .write_buffer = try .initCapacity(allocator, preserved_size),
        .read_buffer = try .initCapacity(allocator, preserved_size),
    };
}

pub fn deinit(self: *Pipeline) void {
    self.write_buffer.deinit();
    self.read_buffer.deinit();
}

pub fn reset(self: *Pipeline) void {
    const preserved_size = @divFloor(self.config.preserved_size, 2);
    const threshold = 4;
    resizeAllocating(&self.write_buffer, preserved_size, threshold);
    resizeAllocating(&self.read_buffer, preserved_size, threshold);
}

pub fn take(self: *Pipeline) []const u8 {
    const content = self.peek();
    if (content.len == 0) {
        // There is nothing to swap.
        @branchHint(.unlikely);
        return &.{};
    }
    // Swapping from write buffer to read buffer
    // ensures that ptr of content is not invalidated
    // when write_buffer does a memory remap.
    std.mem.swap(std.Io.Writer.Allocating, &self.read_buffer, &self.write_buffer);
    self.write_buffer.clearRetainingCapacity();
    return content;
}

pub fn peek(self: *Pipeline) []const u8 {
    return self.write_buffer.writer.buffered();
}

pub fn addManyAsSlice(self: *Pipeline, n: u64) std.mem.Allocator.Error![]u8 {
    const w = self.writer();
    const start = w.end;
    const needed_size = start + n;
    if (needed_size > w.buffer.len) {
        // addManyAsSlice is often used with empty and
        // preallocated buffer. preserved_size might be
        // enough, so we can avoid extra allocation.
        @branchHint(.unlikely);
        try self.write_buffer.ensureTotalCapacityPrecise(needed_size);
    }
    // Extends logical free buffer to capacity.
    w.advance(n);
    return w.buffer[start..w.end];
}

pub fn writer(self: *Pipeline) *std.Io.Writer {
    return &self.write_buffer.writer;
}

pub fn beginFrame(self: *Pipeline) std.mem.Allocator.Error!frames.Builder {
    return frames.Builder.begin(self.writer()) catch |err| switch (err) {
        // Assuming writer is derived from std.Io.Writer.Allocating,
        // write fails are caused by OOM.
        error.WriteFailed => error.OutOfMemory,
    };
}

fn resizeAllocating(
    allocating: *std.Io.Writer.Allocating,
    preserved_size: u64,
    threshold: u64,
) void {
    const cap = allocating.writer.buffer.len;
    if (cap > preserved_size and cap >= allocating.writer.end * threshold) {
        @branchHint(.unlikely);
        shrinkAllocating(allocating, preserved_size);
    }
    return allocating.clearRetainingCapacity();
}

fn shrinkAllocating(allocating: *std.Io.Writer.Allocating, preserved_size: u64) void {
    assert(allocating.writer.buffer.len > preserved_size);

    var list = allocating.toArrayList();
    defer allocating.* = .fromArrayList(allocating.allocator, &list);

    list.expandToCapacity();
    list.shrinkAndFree(allocating.allocator, preserved_size);
}

test "Pipeline" {
    const allocator = std.testing.allocator;

    var pipeline: Pipeline = try .init(allocator, .{ .preserved_size = 16 });
    defer pipeline.deinit();

    try pipeline.writer().writeAll("abc");
    try std.testing.expectEqualStrings("abc", pipeline.take());

    try pipeline.writer().writeAll("def");
    try std.testing.expectEqualStrings("def", pipeline.take());

    try std.testing.expect(pipeline.take().len == 0);

    const cap_before = pipeline.write_buffer.writer.buffer.len;
    pipeline.reset();
    const cap_after = pipeline.write_buffer.writer.buffer.len;
    try std.testing.expectEqual(cap_before, cap_after);
    try std.testing.expect(pipeline.writer().end == 0);

    const big_chunk = [_]u8{'a'} ** 256;
    try pipeline.writer().writeAll(&big_chunk);
    var cap = pipeline.write_buffer.writer.buffer.len;
    try std.testing.expect(cap > 8);

    pipeline.reset();
    cap = pipeline.write_buffer.writer.buffer.len;
    try std.testing.expect(cap > 8);

    pipeline.reset();
    cap = pipeline.write_buffer.writer.buffer.len;
    try std.testing.expectEqual(@as(u64, 8), cap);

    try pipeline.writer().writeAll("new");
    try std.testing.expectEqualStrings("new", pipeline.take());
}
