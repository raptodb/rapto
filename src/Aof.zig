//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of AOF.

/// AOF handler, loader and updater.
const Aof = @This();

const std = @import("std");
const frames = @import("frames.zig");
const state_machine = @import("state_machine.zig");
const assert = std.debug.assert;

const Pipeline = @import("Pipeline.zig");
const RwBuffer = @import("RwBuffer.zig");
const Query = @import("Query.zig");
const Memory = @import("Memory.zig");

pub const Config = struct {
    /// Name of Server instance.
    name: []const u8,
    /// When this parameter is enabled, writes in AOF
    /// in name.raptodb file.
    aof: bool,
    /// When this parameter is enabled, reads the AOF
    /// file. When both `aof` and `aof_file` are enabled
    /// writes on file as the same name of `aof_file`.
    aof_file: ?[]const u8,
    /// Minimum size for read/write buffers. This optimizes the
    /// allocation/deallocation overhead.
    /// The preserved size is allocated at initialization time
    /// and is never deallocated until the `.deinit()` method.
    preserved_size: u32 = 16 * 1024,
};

config: Config,

file: std.Io.File,
rw_buffer: RwBuffer,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
) (std.mem.Allocator.Error || std.Io.File.OpenError)!?Aof {
    if (!config.aof and config.aof_file == null)
        return null;

    var owned_path: ?[]u8 = null;
    if (config.aof_file == null) {
        owned_path = try std.fmt.allocPrint(allocator, "{s}.raptodb", .{config.name});
    }
    defer if (owned_path) |path| allocator.free(path);

    const file = try std.Io.Dir.createFileAbsolute(
        io,
        config.aof_file orelse owned_path.?,
        .{ .truncate = false, .read = true },
    );

    const rw_buffer_config: RwBuffer.Config = .{
        .preserved_size = config.preserved_size,
        .single_buffer = true,
    };

    return .{
        .file = file,
        .rw_buffer = try .init(allocator, rw_buffer_config),
        .config = config,
    };
}

pub fn deinit(self: *Aof, io: std.Io) void {
    self.file.close(io);
    self.rw_buffer.deinit();
}

const Iterator = struct {
    reader: *std.Io.Reader,

    const Batch = struct {
        timestamp: std.Io.Timestamp,
        // Likely to be accessed with Pipeline.Iterator.
        pipeline: []const u8,
    };

    pub fn next(self: *Iterator) ?Batch {
        const ts = self.reader.takeInt(u64, .little) catch return null;
        const len = self.reader.takeInt(u64, .little) catch return null;
        const pipeline = self.reader.take(len) catch return null;
        return .{ .pipeline = pipeline, .timestamp = .fromNanoseconds(ts) };
    }
};

pub fn append(
    self: *Aof,
    timestamp: std.Io.Timestamp,
    pipeline: []const u8,
) std.mem.Allocator.Error!void {
    // Derived from std.Io.Writer.Allocating.
    // Any WriteFailed error corresponds to OutOfMemory.
    const writer = self.rw_buffer.writer();
    const ns_timestamp: u64 = @intCast(timestamp.toNanoseconds());
    writer.writeInt(u64, ns_timestamp, .little) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
    };
    frames.append(writer, Pipeline.Header, pipeline) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
    };
}

/// Flushes all appended pipelines to AOF file.
pub fn flush(self: *Aof, io: std.Io) std.Io.File.Writer.Error!void {
    const written = self.rw_buffer.peek();
    if (written.len == 0) return;
    var buf: [4 * 1024]u8 = undefined;
    var aof_writer = self.file.writer(io, &buf);

    aof_writer.interface.writeAll(written) catch |err| return switch (err) {
        error.WriteFailed => aof_writer.err.?,
    };
    aof_writer.interface.flush() catch |err| return switch (err) {
        error.WriteFailed => aof_writer.err.?,
    };

    self.rw_buffer.reset();
}

pub fn load(
    self: Aof,
    allocator: std.mem.Allocator,
    io: std.Io,
    memory: *Memory,
) std.mem.Allocator.Error!void {
    var tmp: std.Io.Writer.Allocating = .init(allocator);
    defer tmp.deinit();
    const writer = &tmp.writer;

    var buf: [4 * 1024]u8 = undefined;
    var reader = self.file.reader(io, &buf);

    var batches: Aof.Iterator = .{ .reader = &reader.interface };
    while (batches.next()) |batch| {
        try loadPipeline(allocator, writer, memory, batch.pipeline);
    }
}

fn loadPipeline(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    memory: *Memory,
    pipeline: []const u8,
) std.mem.Allocator.Error!void {
    var queries: Pipeline.Iterator = .init(pipeline);
    while (queries.next()) |maybe_error| {
        const query = maybe_error catch continue;

        if (query.command.kind() != .write) return;
        state_machine.execute(
            allocator,
            memory,
            writer,
            &query,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // Returned only by down, that is considered a control command.
            // Only write commands can be executed.
            error.Shutdown => unreachable,
        };
    }
}
