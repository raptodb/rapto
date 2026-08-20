//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of pipeline,
//! transport protocol between Server and Client.

const Pipeline = @This();

const std = @import("std");
const frames = @import("frames.zig");

const RwBuffer = @import("RwBuffer.zig");
const Query = @import("Query.zig");

pub const Config = struct {
    /// Minimum size for read/write buffer. This optimizes the
    /// allocation/deallocation overhead.
    /// The preserved size is allocated at initialization time
    /// and is never deallocated until the `.deinit()` method.
    rw_buffer_preserved_size: u64,
    /// Maximum readable bytes from `.read()` over header.
    /// This avoid too large inputs from reader (maybe socket)
    /// throwing error.StreamTooLong.
    /// TODO: make this configurable with cli flags.
    max_pipeline_bytes: u64 =
        // Allows clients to send 512 MiB as Redis/Valkey.
        (512 * 1024 * 1024) - @sizeOf(Header),
};

/// Size type for length-prefix.
pub const Header = u32;

config: Config,

rw_buffer: RwBuffer,

pub fn init(allocator: std.mem.Allocator, config: Config) std.mem.Allocator.Error!Pipeline {
    const rwb_config: RwBuffer.Config = .{ .preserved_size = config.rw_buffer_preserved_size };
    return .{
        .config = config,
        .rw_buffer = try .init(allocator, rwb_config),
    };
}

pub fn deinit(self: *Pipeline) void {
    self.rw_buffer.deinit();
}

pub fn append(self: *Pipeline, serialized: []const u8) std.mem.Allocator.Error!void {
    const w = self.writer();
    frames.Builder.writeHeader(
        w,
        @intCast(serialized.len),
    ) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
    };
    w.writeAll(serialized) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
    };
}

pub fn writer(self: *Pipeline) *std.Io.Writer {
    return self.rw_buffer.writer();
}

pub const ReadError = std.mem.Allocator.Error || std.Io.Reader.DelimiterError;

/// Reads a length-prefixed buffer with two syscalls.
/// This function invalidates buffers, starting a new pipeline cycle.
pub fn read(self: *Pipeline, reader: *std.Io.Reader) ReadError!void {
    self.rw_buffer.reset();
    var buf: [@sizeOf(Header)]u8 = undefined;
    // To reduce syscalls overhead based on size of buffer,
    // we can read header of pipeline and next perform a single read.
    try reader.readSliceAll(&buf);
    const size = std.mem.readInt(Header, &buf, .little);
    if (size > self.config.max_pipeline_bytes) return error.StreamTooLong;

    // Now we can allocate one buffer directly with all length required.
    const read_buffer = try self.rw_buffer.addManyAsSlice(size);
    // Since buf belongs to pipeline, this single-read syscall trasfers
    // all data directly to pipeline, reusing the same buffer.
    try reader.readSliceAll(read_buffer);
}

pub fn stream(self: *Pipeline, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const written = self.rw_buffer.take();
    var header: [@sizeOf(Header)]u8 = undefined;
    std.mem.writeInt(Header, &header, @intCast(written.len), .little);
    // Builds buffer with length-prefix.
    var buf: [2][]const u8 = .{ &header, written };
    try w.writeVecAll(&buf);
}

pub const Builder = struct {
    wrapped_builder: frames.Builder,

    pub fn begin(pipeline: *Pipeline) std.mem.Allocator.Error!Builder {
        const w = pipeline.writer();
        return .{ .wrapped_builder = try .begin(w) };
    }

    pub fn end(self: Builder) void {
        self.wrapped_builder.end();
    }
};

pub const Iterator = struct {
    wrapped_iterator: frames.Iterator,

    pub fn init(pipeline: []const u8) Iterator {
        return .{ .wrapped_iterator = .init(pipeline) };
    }

    pub fn next(self: *Iterator) ?Query.DeserializeError!Query {
        const serialized = self.wrapped_iterator.next() orelse return null;
        return .deserialize(serialized);
    }

    pub fn nextSerialized(self: *Iterator) ?[]const u8 {
        return self.wrapped_iterator.next();
    }
};

pub fn take(self: *Pipeline) []const u8 {
    return self.rw_buffer.take();
}

pub fn peek(self: *Pipeline) []const u8 {
    return self.rw_buffer.peek();
}
