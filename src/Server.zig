//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of server.

/// IO networking manager and executor loop.
const Server = @This();

const std = @import("std");
const cli = @import("cli.zig");
const frames = @import("frames.zig");
const reply = @import("reply.zig");
const state_machine = @import("state_machine.zig");
const log = std.log.scoped(.server);

const Aof = @import("Aof.zig");
const Memory = @import("Memory.zig");
const Pipeline = @import("Pipeline.zig");
const Stream = @import("Stream.zig");
const Listener = @import("Server/Listener.zig");

pub const Context = struct {
    config: Config,
    pipeline: Pipeline,
    memory: Memory,
    aof: ?Aof,
    listener: Listener,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: *const cli.Command.Server,
    ) !Context {
        const config: Server.Config = .{ .aof_sync_seconds = args.aof_sync_seconds };

        const pipeline_config: Pipeline.Config = .{
            .rw_buffer_preserved_size = args.io_preserved_size,
        };
        const memory_config: Memory.Config = .{ .initial_keys = args.expected_keys };
        const aof_config: Aof.Config = .{
            .name = args.name,
            // TODO: make this separate from --io-preserved-size.
            // Consider specific flag as --aof-buffer-size.
            .rw_buffer_preserved_size = args.io_preserved_size,
        };

        var pipeline: Pipeline = try .init(allocator, pipeline_config);
        errdefer pipeline.deinit();
        var memory: Memory = try .init(allocator, memory_config);
        errdefer memory.deinit(allocator);

        var aof: ?Aof = null;
        if (args.aof) {
            const path = args.aof_file orelse
                try std.fmt.allocPrint(allocator, "{s}.raptodb", .{args.name});
            defer if (args.aof_file == null) allocator.free(path);
            aof = try Aof.init(allocator, io, path, aof_config);
        }
        errdefer if (aof) |*a| a.deinit(io);

        const listener: Listener = try .listen(
            allocator,
            io,
            .{
                // Quick-n-dirty trick to disable timeout when `aof_sync_seconds` is zero.
                .timeout_ms = args.aof_sync_seconds * std.time.ms_per_s - 1,
                .address = args.address,
            },
        );
        errdefer comptime unreachable;

        return .{
            .config = config,
            .pipeline = pipeline,
            .memory = memory,
            .aof = aof,
            .listener = listener,
        };
    }

    pub fn deinit(self: *Context, allocator: std.mem.Allocator, io: std.Io) void {
        self.pipeline.deinit();
        self.memory.deinit(allocator);
        if (self.aof) |*a| a.deinit(io);
        self.listener.deinit(allocator, io);
    }

    /// Load queries from AOF. Assumes AOF is enabled.
    pub fn loadAof(self: *Context, allocator: std.mem.Allocator, io: std.Io) Aof.LoadError!void {
        return self.aof.?.load(allocator, io, &self.memory);
    }

    pub fn server(self: *Context) Server {
        return .{
            .config = self.config,
            .listener = &self.listener,
            .memory = &self.memory,
            .pipeline = &self.pipeline,
            .aof = if (self.aof) |*a| a else null,
        };
    }
};

pub const Config = struct {
    /// Writes every `aof_sync_seconds` to aof file.
    /// When is 0, writes always after any query.
    aof_sync_seconds: i32,
};

pub const Error = std.mem.Allocator.Error || error{Shutdown};

config: Config,

listener: *Listener,
memory: *Memory,
pipeline: *Pipeline,
aof: ?*Aof,

pub fn run(self: Server, allocator: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error!void {
    var running: bool = true;
    var last_flush: std.Io.Timestamp = .now(io, .awake);

    while (running) {
        // Whatever event happens, like an error or shutdown,
        // we must ensure at least that new queries received
        // must be written to the AOF.
        defer if (self.aof) |aof| {
            const now: std.Io.Timestamp = .now(io, .awake);
            const elapsed = last_flush.durationTo(now);
            if (elapsed.toSeconds() >= self.config.aof_sync_seconds) {
                // When at least `aof_sync_seconds` are elapsed,
                // we have to update aof file with new queries.
                aof.flush(io) catch |err| {
                    log.err("occurred error={t} while updating AOF", .{err});
                    running = false;
                };
                last_flush = now;
            }
        };

        var events = try self.listener.collectEvents(allocator);
        while (events.next()) |event| {
            const maybe_error: Server.Error!void =
                self.consumeEvent(allocator, io, event);

            maybe_error catch |err| return switch (err) {
                error.Shutdown => {},
                error.OutOfMemory => error.OutOfMemory,
            };
        }
    }
}

pub fn consumeEvent(
    self: Server,
    allocator: std.mem.Allocator,
    io: std.Io,
    event: Listener.Event,
) Error!void {
    return switch (event) {
        .accept => self.onAccept(allocator, io),
        .disconnect => |s| self.onDisconnect(allocator, io, s),
        .readable => |s| err: {
            @branchHint(.likely);
            break :err self.onReadable(allocator, io, s);
        },
    };
}

fn onAccept(self: Server, allocator: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error!void {
    var acceptor = self.listener.acceptor();
    while (true) {
        const client = acceptor.acceptNext(
            allocator,
            io,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => log.err("occurred error={t} on accept", .{err}),
        };
        const stream = client orelse break; // No available clients.
        log.info("client {f} connected", .{stream.address()});
    }
}

fn onDisconnect(
    self: Server,
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: Stream,
) std.mem.Allocator.Error!void {
    try self.listener.disconnect(allocator, io, stream);
    log.info("client {f} disconnected", .{stream.address()});
}

fn onReadable(self: Server, allocator: std.mem.Allocator, io: std.Io, stream: Stream) Error!void {
    var reader = stream.reader(io);
    var writer = stream.writer(io);

    self.pipeline.read(&reader.interface) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.EndOfStream => self.onDisconnect(allocator, io, stream),
        error.ReadFailed => err: {
            log.warn("occurred error={t} while reading batch", .{reader.err.?});
            break :err self.onDisconnect(allocator, io, stream);
        },
        error.StreamTooLong => err: {
            log.warn("occurred error={t} while reading batch", .{err});
            break :err self.onDisconnect(allocator, io, stream);
        },
    };

    if (self.aof) |aof| {
        const pipeline_timestamp: std.Io.Timestamp = .now(io, .awake);
        try aof.append(pipeline_timestamp, self.pipeline.peek());
    }

    self.execute(allocator) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Shutdown => err: {
            log.info("shutdown requested by {f}", .{stream.address()});
            break :err error.Shutdown;
        },
    };

    self.pipeline.stream(&writer.interface) catch |err| return switch (err) {
        error.WriteFailed => err: {
            log.err("occurred error={t} while sending replies", .{writer.err.?});
            break :err self.onDisconnect(allocator, io, stream);
        },
    };
}

fn execute(self: Server, allocator: std.mem.Allocator) Error!void {
    const w = self.pipeline.writer();

    const queries = self.pipeline.take();
    var iterator: Pipeline.Iterator = .init(queries);
    while (iterator.next()) |maybe_error| {
        var builder: Pipeline.Builder = try .begin(self.pipeline);
        defer builder.end();

        const result = if (maybe_error) |query|
            state_machine.execute(allocator, self.memory, w, &query)
        else |err|
            reply.writeError(w, .fromError(err));

        result catch |err| return switch (err) {
            // Assuming the provided writer is from Allocating,
            // error.WriteFailed can be casted into OOM
            error.WriteFailed => error.OutOfMemory,
            error.OutOfMemory, error.Shutdown => |e| e,
        };
    }
}
