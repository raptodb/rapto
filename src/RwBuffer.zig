//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of read/write swapping buffers.

const RwBuffer = @This();

const std = @import("std");
const frames = @import("frames.zig");
const assert = std.debug.assert;

pub const Config = struct {
    /// Minimum size for write/read buffers. This optimizes the
    /// allocation/deallocation overhead.
    /// The preserved size is allocated at initialization time
    /// and is never deallocated until the `.deinit()` method.
    preserved_size: u64,
    /// Only write buffer is used. When enabled, `take` will
    /// have the same behavior of `peek` with cursor reset.
    single_buffer: bool = false,
};

config: Config,

write_buffer: std.Io.Writer.Allocating,
read_buffer: std.Io.Writer.Allocating,

pub fn init(allocator: std.mem.Allocator, config: Config) std.mem.Allocator.Error!RwBuffer {
    var self: RwBuffer = undefined;
    self.config = config;
    if (config.single_buffer) {
        self.write_buffer = try .initCapacity(allocator, config.preserved_size);
    } else {
        const shared_preserved_size = @divFloor(config.preserved_size, 2);
        self.write_buffer = try .initCapacity(allocator, shared_preserved_size);
        self.read_buffer = try .initCapacity(allocator, shared_preserved_size);
    }
    return self;
}

pub fn deinit(self: *RwBuffer) void {
    self.write_buffer.deinit();
    self.read_buffer.deinit();
}

pub fn reset(self: *RwBuffer) void {
    // Shrinks when used buffer is a quarter of capacity.
    const threshold = 4;

    if (self.config.single_buffer) {
        resizeAllocating(&self.write_buffer, self.config.preserved_size, threshold);
    } else {
        const shared_preserved_size = @divFloor(self.config.preserved_size, 2);
        resizeAllocating(&self.write_buffer, shared_preserved_size, threshold);
        resizeAllocating(&self.read_buffer, shared_preserved_size, threshold);
    }
}

/// As `peek` followed by buffer swap/clear.
/// Returned buffer is valid until next `take`.
/// This function invalidates last taken/peeked buffer.
pub fn take(self: *RwBuffer) []const u8 {
    const content = self.peek();
    if (content.len == 0 or self.config.single_buffer) {
        // There is nothing to swap.
        self.write_buffer.clearRetainingCapacity();
        return content;
    }
    // Swapping from write buffer to read buffer
    // ensures that ptr of content is not invalidated
    // when write_buffer does a memory remap.
    std.mem.swap(std.Io.Writer.Allocating, &self.read_buffer, &self.write_buffer);
    self.write_buffer.clearRetainingCapacity();
    return content;
}

pub fn peek(self: *RwBuffer) []const u8 {
    return self.write_buffer.writer.buffered();
}

pub fn addManyAsSlice(self: *RwBuffer, n: u64) std.mem.Allocator.Error![]u8 {
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

pub fn writer(self: *RwBuffer) *std.Io.Writer {
    return &self.write_buffer.writer;
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

test "RwBuffer" {
    const allocator = std.testing.allocator;

    var rw_buffer: RwBuffer = try .init(allocator, .{ .preserved_size = 16 });
    defer rw_buffer.deinit();

    try rw_buffer.writer().writeAll("abc");
    try std.testing.expectEqualStrings("abc", rw_buffer.take());

    try rw_buffer.writer().writeAll("def");
    try std.testing.expectEqualStrings("def", rw_buffer.take());

    try std.testing.expect(rw_buffer.take().len == 0);

    const cap_before = rw_buffer.write_buffer.writer.buffer.len;
    rw_buffer.reset();
    const cap_after = rw_buffer.write_buffer.writer.buffer.len;
    try std.testing.expectEqual(cap_before, cap_after);
    try std.testing.expect(rw_buffer.writer().end == 0);

    const big_chunk = [_]u8{'a'} ** 256;
    try rw_buffer.writer().writeAll(&big_chunk);
    var cap = rw_buffer.write_buffer.writer.buffer.len;
    try std.testing.expect(cap > 8);

    rw_buffer.reset();
    cap = rw_buffer.write_buffer.writer.buffer.len;
    try std.testing.expect(cap > 8);

    rw_buffer.reset();
    cap = rw_buffer.write_buffer.writer.buffer.len;
    try std.testing.expectEqual(@as(u64, 8), cap);

    try rw_buffer.writer().writeAll("new");
    try std.testing.expectEqualStrings("new", rw_buffer.take());
}
