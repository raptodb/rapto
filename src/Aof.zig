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

const version = @import("main.zig").version;
const header_magic: [5]u8 = "RAPTO".*;

pub const Config = struct {
    /// Name of Server instance, owner of current AOF file.
    /// Length must be less than 128 bytes.
    name: []const u8,
    /// Minimum size for read/write buffers. This optimizes the
    /// allocation/deallocation overhead.
    /// The preserved size is allocated at initialization time
    /// and is never deallocated until the `deinit()` method.
    rw_buffer_preserved_size: u64,
};

config: Config,

write_offset: u64 = 0,
file: std.Io.File,
/// Based on default configuration, this is used
/// only for append/flush methods.
/// This implementation resizes buffer efficiently.
rw_buffer: RwBuffer,

const Header = extern struct {
    const Error = error{ InvalidMagic, UnsupportedVersion, NameTooLong };

    magic: [5]u8 = header_magic,
    version: extern struct {
        const Version = @This();

        major: u64,
        minor: u64,
        // Patch is not considered because it's
        // assumed that there are no changes to API.
        // patch: u64,

        const current: Version = .{ .major = version.major, .minor = version.minor };

        fn fromSemanticVersion(sv: std.SemanticVersion) Version {
            return .{ .major = sv.major, .minor = sv.minor };
        }

        fn isCompatible(self: Version, v: Version) bool {
            return self.major == v.major and self.minor == v.minor;
        }
    } = .current,

    /// Original server name that created
    server_name: [128]u8 = @splat(0),
    /// Reserved for incoming features.
    _: [512]u8 = @splat(0),

    pub fn init(server_name: []const u8) error{NameTooLong}!Header {
        var self: Header = .{};
        if (server_name.len >= self.server_name.len) return error.NameTooLong;
        @memcpy(self.magic[0..header_magic.len], &header_magic);
        @memcpy(self.server_name[0..server_name.len], server_name);
        self.version = .fromSemanticVersion(version);
        return self;
    }

    pub const DeserializeError = std.Io.Reader.Error || error{ InvalidMagic, UnsupportedVersion };

    pub fn deserializeFromReader(reader: *std.Io.Reader) DeserializeError!Header {
        const self = try reader.takeStruct(Header, .little);
        if (!std.mem.eql(u8, &self.magic, &header_magic)) return error.InvalidMagic;
        if (!self.version.isCompatible(.current)) return error.UnsupportedVersion;
        return self;
    }

    pub fn serializeToWriter(self: Header, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeStruct(self, .little);
    }
};

pub const InitError = std.mem.Allocator.Error || std.Io.File.OpenError || EnsureHeader || std.Io.File.LengthError || error{NameTooLong};

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    config: Config,
) InitError!Aof {
    const options: std.Io.Dir.CreateFileOptions = .{ .truncate = false, .read = true };
    const file = try std.Io.Dir.createFileAbsolute(io, path, options);
    errdefer file.close(io);

    const rw_buffer_config: RwBuffer.Config = .{
        .preserved_size = config.rw_buffer_preserved_size,
        .single_buffer = true,
    };
    var rw_buffer: RwBuffer = try .init(allocator, rw_buffer_config);
    errdefer rw_buffer.deinit();

    var self: Aof = .{ .file = file, .rw_buffer = rw_buffer, .config = config };

    // Default header when file doesn't exist or is corrupted.
    const default_header: Header = try .init(config.name);
    try self.ensureHeader(io, default_header);

    return self;
}

pub fn deinit(self: *Aof, io: std.Io) void {
    self.file.close(io);
    self.rw_buffer.deinit();
}

const WriteHeaderError =
    std.Io.File.Writer.Error || std.Io.File.Writer.SeekError || std.Io.File.SyncError || std.Io.File.LengthError;

fn writeHeader(self: *Aof, io: std.Io, header: Header) WriteHeaderError!void {
    var writer = self.file.writer(io, self.rw_buffer.unusedCapacitySlice());
    try writer.seekToUnbuffered(0);
    header.serializeToWriter(&writer.interface) catch |err| return switch (err) {
        error.WriteFailed => writer.err.?,
    };
    writer.interface.flush() catch |err| return switch (err) {
        error.WriteFailed => writer.err.?,
    };
    try self.file.sync(io);
    self.write_offset = try self.file.length(io);
}

const EnsureHeader = Header.Error || WriteHeaderError || std.Io.File.Reader.Error;

fn ensureHeader(self: *Aof, io: std.Io, header: Header) EnsureHeader!void {
    const size = try self.file.length(io);
    if (size == 0) {
        // File is empty or just created.
        try self.writeHeader(io, header);
        return;
    }

    var reader = self.file.reader(io, self.rw_buffer.unusedCapacitySlice());
    const maybe_error = Header.deserializeFromReader(&reader.interface);

    _ = maybe_error catch |err| switch (err) {
        error.EndOfStream => {
            // Stream too short, maybe corrupted.
            // We have to overwrite data at offset 0 with
            // valid header.
            try self.writeHeader(io, header);
        },
        error.ReadFailed => return reader.err.?,
        error.UnsupportedVersion,
        error.InvalidMagic,
        => |e| return e,
    };
}

const Iterator = struct {
    reader: *std.Io.Reader,
    allocating: std.Io.Writer.Allocating,

    fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader) Iterator {
        return .{ .reader = reader, .allocating = .init(allocator) };
    }

    fn deinit(self: *Iterator) void {
        self.allocating.deinit();
    }

    const Batch = struct {
        timestamp: std.Io.Timestamp,
        pipeline: []const u8,

        fn iterator(self: Batch) Pipeline.Iterator {
            return .init(self.pipeline);
        }
    };

    const Error = std.mem.Allocator.Error || std.Io.Reader.Error || error{InvalidFormat};

    fn next(self: *Iterator) Error!?Batch {
        self.allocating.clearRetainingCapacity();
        const writer = &self.allocating.writer;

        const ts = self.reader.takeInt(
            u64,
            .little,
        ) catch |err| return switch (err) {
            error.ReadFailed => error.ReadFailed,
            // No other queries to read.
            error.EndOfStream => null,
        };
        const len = self.reader.takeInt(
            Pipeline.Header,
            .little,
        ) catch |err| return switch (err) {
            error.ReadFailed => error.ReadFailed,
            error.EndOfStream => error.InvalidFormat,
        };

        const pipeline = writer.writableSlice(len) catch |err| return switch (err) {
            error.WriteFailed => error.OutOfMemory,
        };
        self.reader.readSliceAll(pipeline) catch |err| return switch (err) {
            error.ReadFailed => error.ReadFailed,
            error.EndOfStream => error.InvalidFormat,
        };

        return .{ .pipeline = pipeline, .timestamp = .fromNanoseconds(ts) };
    }
};

/// Appends to abstract queue the current pipeline.
/// When `flush` is called, queue drains the content
/// to file and `append` starts from empty queue.
pub fn append(self: *Aof, ts: std.Io.Timestamp, pipeline: []const u8) std.mem.Allocator.Error!void {
    // Derived from std.Io.Writer.Allocating.
    // Any WriteFailed error corresponds to OutOfMemory.
    const writer = self.rw_buffer.writer();
    const ns_timestamp: u64 = @intCast(ts.toNanoseconds());
    writer.writeInt(u64, ns_timestamp, .little) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
    };
    frames.append(writer, Pipeline.Header, pipeline) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
    };
}

pub const FlushError = std.Io.File.SyncError || std.Io.File.WritePositionalError;

/// Flushes all appended pipelines to AOF file. Waits
/// until file is syncronized with flushed content.
pub fn flush(self: *Aof, io: std.Io) FlushError!void {
    const written = self.rw_buffer.take();
    if (written.len == 0) return;

    try self.file.writePositionalAll(io, written, self.write_offset);
    try self.file.sync(io);

    self.rw_buffer.reset();
    self.write_offset += written.len;
}

pub const LoadError = Iterator.Error;

pub fn load(
    self: *Aof,
    allocator: std.mem.Allocator,
    io: std.Io,
    memory: *Memory,
) Iterator.Error!void {
    var tmp: std.Io.Writer.Allocating = .init(allocator);
    defer tmp.deinit();
    const writer = &tmp.writer;

    // Minimus buffer required for .takeInt() methods.
    var min_buf: [8]u8 = undefined;
    var reader = self.file.reader(io, &min_buf);
    reader.seekTo(@sizeOf(Header)) catch unreachable;

    var batches: Aof.Iterator = .init(allocator, &reader.interface);
    defer batches.deinit();

    while (try batches.next()) |batch| {
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
    while (queries.next()) |maybe_query| {
        const query = maybe_query catch continue;
        if (query.command.kind() != .write) return;

        const maybe_error =
            state_machine.execute(allocator, memory, writer, &query);

        maybe_error catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // Returned only by down, that is considered a control command.
            // Only write commands can be executed.
            error.Shutdown => unreachable,
        };
    }
}
