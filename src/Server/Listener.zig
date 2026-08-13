//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of network event loop and client handler.

const Listener = @This();

const std = @import("std");
const linux = std.os.linux;
const assert = std.debug.assert;

const Stream = @import("../Stream.zig");

const StreamMap = std.HashMapUnmanaged(
    linux.fd_t,
    Entry,
    std.hash_map.AutoContext(linux.fd_t),
    75,
);

const Entry = struct {
    stream: Stream,
    event: linux.epoll_event,
};

pub const Config = struct {
    /// Address of listener.
    address: std.Io.net.IpAddress,
    /// Timeout about `collectEvents`.
    timeout_ms: i32,
};

pub const Event = union(enum) {
    /// Probably never returned.
    none,
    /// Stream of accepted stream.
    accepted: Stream,
    accept_error: Stream.AcceptError,
    /// Incoming data from stream is available.
    readable: Stream,
    /// Only address of closed stream. Stream
    /// is not returned because fd is closed.
    closed: std.Io.net.IpAddress,
};

pub const Error = std.mem.Allocator.Error || std.Io.net.IpAddress.ListenError;

config: Config,

epoll_fd: linux.fd_t,
server: std.Io.net.Server,

events: std.ArrayList(linux.epoll_event) = .empty,
stream_map: StreamMap = .empty,

pub fn listen(allocator: std.mem.Allocator, io: std.Io, config: Config) Error!Listener {
    const server = try config.address.listen(io, .{ .reuse_address = true });
    setNonBlock(server.socket.handle);

    var self: Listener = .{
        .config = config,
        .epoll_fd = @intCast(linux.epoll_create1(linux.EPOLL.CLOEXEC)),
        .server = server,
    };
    try self.events.ensureTotalCapacity(allocator, 16);
    self.events.expandToCapacity();
    // Register listener as first file descriptor.
    try self.register(allocator, .fromSocket(server.socket));

    return self;
}

pub fn deinit(self: *Listener, allocator: std.mem.Allocator, io: std.Io) void {
    var iter = self.stream_map.valueIterator();
    // Unregister all entries.
    while (iter.next()) |entry| entry.stream.close(io);
    self.stream_map.deinit(allocator);
    self.events.deinit(allocator);
}

pub const EventQueue = struct {
    l: *Listener,
    index: u64 = 0,
    events: []const linux.epoll_event,

    pub fn next(
        self: *EventQueue,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) std.mem.Allocator.Error!?Event {
        if (self.index >= self.events.len) return null;

        const epoll_event = self.events[self.index];
        const event_fd = epoll_event.data.fd;
        const event_type = self.l.classify(event_fd, epoll_event.events);

        return switch (event_type) {
            .new_connection => blk: {
                const client = Stream.nonBlockAccept(io, &self.l.server) catch |err| {
                    self.index += 1;
                    break :blk switch (err) {
                        // Finally, we have accepted all incoming clients.
                        // self.index has been increased to handle next event.
                        error.WouldBlock => self.next(allocator, io),
                        // In this case, self.index has been increased to avoid
                        // loop of accept_error.
                        else => .{ .accept_error = err },
                    };
                };
                try self.l.register(allocator, client);
                // After successful registration of client, we will not
                // increment self.index to handle the same new_connection
                // event and accept other clients.
                break :blk .{ .accepted = client };
            },
            .connection_closed => blk: {
                const stream = self.l.unregister(event_fd);
                stream.close(io);
                self.index += 1;
                break :blk .{ .closed = stream.address() };
            },
            .incoming_data => blk: {
                const entry = self.l.stream_map.get(event_fd) orelse unreachable;
                self.index += 1;
                break :blk .{ .readable = entry.stream };
            },
            .unknown => blk: {
                @branchHint(.cold);
                self.index += 1;
                break :blk .none;
            },
        };
    }
};

pub fn collectEvents(
    self: *Listener,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!EventQueue {
    var events = self.events.allocatedSlice();

    const len = linux.epoll_wait(
        self.epoll_fd,
        events.ptr,
        @intCast(events.len),
        self.config.timeout_ms,
    );

    assert(events.len >= len);
    // More events available than capacity?
    if (len == events.len) {
        @branchHint(.unlikely);
        try self.events.ensureUnusedCapacity(allocator, 1);
        // `ensureUnusedCapacity` causes remap of slice,
        // invalidating events. We can get slice again.
        events = self.events.allocatedSlice();
        // More available events for next call to `collectEvents`.
        self.events.expandToCapacity();
    }

    return .{ .l = self, .events = events[0..len] };
}

/// Registers a stream previously accepted.
pub fn register(
    self: *Listener,
    allocator: std.mem.Allocator,
    stream: Stream,
) std.mem.Allocator.Error!void {
    const stream_fd = stream.fd();

    var entry: Entry = .{ .stream = stream, .event = .{
        .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
        .data = .{ .fd = stream_fd },
    } };
    try self.stream_map.putNoClobber(allocator, stream_fd, entry);

    _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, stream_fd, &entry.event);
}

/// Transfer ownership to caller. Stream must be closed.
pub fn unregister(self: *Listener, stream_fd: linux.fd_t) Stream {
    _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, stream_fd, null);
    const kv = self.stream_map.fetchRemove(stream_fd) orelse unreachable;
    return kv.value.stream;
}

/// Translate lower-level event to higher-level classification.
fn classify(
    self: Listener,
    event_fd: linux.fd_t,
    event: u32,
) enum { new_connection, connection_closed, incoming_data, unknown } {
    if (event_fd == self.server.socket.handle)
        return .new_connection;
    if (event & (linux.EPOLL.ERR | linux.EPOLL.HUP) != 0)
        return .connection_closed;
    if (event & linux.EPOLL.IN != 0)
        return .incoming_data;
    if (event & linux.EPOLL.RDHUP != 0)
        return .connection_closed;

    return .unknown;
}

fn setNonBlock(fd: linux.fd_t) void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    var o: linux.O = @bitCast(@as(u32, @intCast(flags)));
    o.NONBLOCK = true;
    const args: u32 = @bitCast(o);
    _ = linux.fcntl(fd, linux.F.SETFL, @intCast(args));
}
