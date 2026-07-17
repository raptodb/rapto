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

const Query = @import("Pipeline/Query.zig");
const Memory = @import("Memory.zig");

pub const Config = struct {
    /// Name of Server instance.
    name: []const u8,
    /// When this parameter is enabled, writes in AOF
    /// in name.raptodb file.
    aof: bool = false,
    /// When this parameter is enabled, reads the AOF
    /// file. When both `aof` and `aof_file` are enabled
    /// writes on file as the same name of `aof_file`.
    aof_file: ?[]const u8,
    /// Minimum size of Allocating. This optimizes the
    /// allocation/deallocation overhead.
    /// The preserved size is allocated at initialization time
    /// and is never deallocated until the `.deinit()` method.
    preserved_size: u32 = 16 * 1024,
};

config: Config,

file: std.Io.File,
allocating: std.Io.Writer.Allocating,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
) (std.mem.Allocator.Error || std.Io.File.OpenError)!?Aof {
    if (!config.aof and config.aof_file == null)
        return null;

    const owned_path = if (config.aof_file == null)
        try std.fmt.allocPrint(allocator, "{s}.raptodb", .{config.name})
    else
        null;
    defer if (owned_path) |path|
        allocator.free(path);

    const path = config.aof_file orelse owned_path.?;

    const options: std.Io.Dir.CreateFileOptions = .{
        .truncate = false,
        .read = true,
    };

    return .{
        .file = try std.Io.Dir.createFileAbsolute(
            io,
            path,
            options,
        ),
        .allocating = try .initCapacity(
            allocator,
            config.preserved_size,
        ),
        .config = config,
    };
}

pub fn deinit(self: *Aof, io: std.Io) void {
    self.file.close(io);
    self.allocating.deinit();
}

pub const Builder = struct {
    wrapped_builder: frames.ExtendedBuilder,

    pub fn begin(aof: *Aof, timestamp: std.Io.Timestamp) std.mem.Allocator.Error!Builder {
        const writer = &aof.allocating.writer;

        const builder = frames.ExtendedBuilder.begin(writer) catch
            return error.OutOfMemory;
        writer.writeInt(i96, timestamp.toNanoseconds(), .little) catch
            return error.OutOfMemory;

        return .{ .wrapped_builder = builder };
    }

    pub fn append(self: *Builder, serialized_query: []const u8) std.mem.Allocator.Error!void {
        var builder = frames.Builder.begin(self.wrapped_builder.writer) catch
            return error.OutOfMemory;
        defer builder.end();
        builder.writer.writeAll(serialized_query) catch return error.OutOfMemory;
    }

    pub fn end(self: Builder) void {
        self.wrapped_builder.end();
    }
};

const Iterator = struct {
    reader: std.Io.Reader,

    const Pipeline = struct {
        reader: std.Io.Reader,

        pub fn deserialize(
            self: *Pipeline,
        ) std.Io.Reader.Error!struct { std.Io.Timestamp, frames.Iterator } {
            const timestamp = try self.reader.takeInt(i64, .little);
            return .{
                .fromNanoseconds(timestamp),
                .init(self.reader.buffered()),
            };
        }
    };

    pub fn next(self: *Iterator) ?Pipeline {
        const len = self.reader.takeInt(u64, .little) catch return null;
        const pipeline = self.reader.take(len) catch return null;
        return .{ .reader = .fixed(pipeline) };
    }
};

pub fn iterator(self: *Aof, io: std.Io, buf: []u8) Iterator {
    const reader = self.file.reader(io, buf);
    return .{ .reader = reader.interface };
}

pub fn flush(self: *Aof, io: std.Io) std.Io.File.Writer.Error!void {
    const aof_buffer_writer = &self.allocating.writer;
    if (aof_buffer_writer.end == 0) return;

    var buf: [4 * 1024]u8 = undefined;
    var aof_writer = self.file.writer(io, &buf);

    aof_writer.interface.writeAll(aof_buffer_writer.buffered()) catch return aof_writer.err.?;
    aof_writer.interface.flush() catch return aof_writer.err.?;

    resizeAllocating(&self.allocating, self.config.preserved_size);
}

pub fn load(
    self: *Aof,
    allocator: std.mem.Allocator,
    io: std.Io,
    memory: *Memory,
) (state_machine.FatalError || std.Io.Reader.Error || Query.Error)!void {
    var discarding: std.Io.Writer.Discarding = .init(&.{});
    const writer = &discarding.writer;

    var buf: [4 * 1024]u8 = undefined;
    var iter = self.iterator(io, &buf);

    while (iter.next()) |pipeline| {
        var pipeline_copy = pipeline;
        _, var query_iter = try pipeline_copy.deserialize();
        while (query_iter.next()) |serialized_query| {
            const query: Query = try .parse(serialized_query);
            try state_machine.execute(allocator, memory, writer, &query);
        }
    }
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
