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

pub const Query = @import("Pipeline/Query.zig");
/// Convetional definition as string.
pub const Reply = []const u8;

pub const Config = struct {
    /// Minimum size for Query and Reply. This optimizes the
    /// allocation/deallocation overhead.
    /// The preserved size is allocated at initialization time
    /// and is never deallocated until the `.deinit()` method.
    preserved_size: u32 = 16 * 1024 * 2,
};

config: Config,

start_segment_index: u64 = 0,
allocating: std.Io.Writer.Allocating,

pub fn init(allocator: std.mem.Allocator, config: Config) std.mem.Allocator.Error!Pipeline {
    var self: Pipeline = undefined;
    self.config = config;
    self.allocating = try .initCapacity(allocator, config.preserved_size);
    return self;
}

pub fn deinit(self: *Pipeline) void {
    self.allocating.deinit();
}

pub fn reset(self: *Pipeline) void {
    resizeAllocating(&self.allocating, self.config.preserved_size);
}

pub fn take(self: *Pipeline) []const u8 {
    const w = self.writer();
    const content = w.buffer[self.start_segment_index..w.end];
    self.start_segment_index = w.end;
    return content;
}

pub fn writer(self: *Pipeline) *std.Io.Writer {
    return &self.allocating.writer;
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
