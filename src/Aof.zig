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

const Query = @import("Query.zig");
const Memory = @import("Memory.zig");

file: std.Io.File,

allocating: std.Io.Writer.Allocating,
preserved_size: u64,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    preserved_size: u64,
) (std.mem.Allocator.Error || std.Io.File.OpenError)!Aof {
    var self: Aof = undefined;

    const options: std.Io.Dir.CreateFileOptions = .{
        .truncate = false,
        .read = true,
    };
    self.file = try std.Io.Dir.createFileAbsolute(io, path, options);

    self.preserved_size = preserved_size;
    self.allocating = try .initCapacity(
        allocator,
        preserved_size,
    );

    return self;
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
        writer.writeInt(i64, timestamp.toMicroseconds(), .little) catch
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

pub fn begin(self: *Aof, timestamp: std.Io.Timestamp) std.mem.Allocator.Error!Builder {
    return .begin(self, timestamp);
}

const Iterator = struct {
    reader: std.Io.Reader,

    fn fromReader(aof: *Aof, io: std.Io, buf: []u8) Iterator {
        const reader = aof.file.reader(io, buf);
        return .{ .reader = reader.interface };
    }

    const Pipeline = struct {
        reader: std.Io.Reader,

        pub fn deserialize(
            self: *Pipeline,
        ) std.Io.Reader.Error!struct { std.Io.Timestamp, frames.Iterator } {
            const timestamp = try self.reader.takeInt(i64, .little);
            return .{
                .fromNanoseconds(@as(i96, timestamp) * std.time.ns_per_us),
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
    return .fromReader(self, io, buf);
}

pub fn flush(self: *Aof, io: std.Io) std.Io.File.Writer.Error!void {
    const aof_buffer_writer = &self.allocating.writer;
    if (aof_buffer_writer.end == 0) return;

    var buf: [4 * 1024]u8 = undefined;
    var aof_writer = self.file.writer(io, &buf);

    aof_writer.interface.writeAll(aof_buffer_writer.buffered()) catch return aof_writer.err.?;
    aof_writer.interface.flush() catch return aof_writer.err.?;

    resizeAllocating(&self.allocating, self.preserved_size);
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

fn resizeAllocating(
    allocating: *std.Io.Writer.Allocating,
    preserved_size: u64,
) void {
    if (allocating.writer.buffer.len > preserved_size) {
        @branchHint(.unlikely);
        shrinkAllocating(allocating, preserved_size);
    }
    return allocating.clearRetainingCapacity();
}

fn shrinkAllocating(
    allocating: *std.Io.Writer.Allocating,
    preserved_size: u64,
) void {
    assert(allocating.writer.buffer.len > preserved_size);

    var list = allocating.toArrayList();
    defer allocating.* = .fromArrayList(allocating.allocator, &list);

    list.shrinkAndFree(allocating.allocator, preserved_size);
}
