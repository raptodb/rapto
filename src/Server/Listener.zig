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

pub const Config = struct {
    /// Address of listener.
    address: std.Io.net.IpAddress,
    /// Timeout about `collectEvents`.
    timeout_ms: i32,
};

pub const Event = union(enum) {
    /// Stream of accepted client.
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

events: struct {
    const EventBuffer = @This();

    buffer: std.ArrayList(linux.epoll_event),

    /// Initializes buffer ensuring at least one usable slot.
    fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!EventBuffer {
        var self: EventBuffer = .{ .buffer = .empty };
        try self.grow(allocator);
        return self;
    }

    fn deinit(self: *EventBuffer, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
    }

    /// Returns buffer until capacity.
    fn buffered(self: EventBuffer) []linux.epoll_event {
        return self.buffer.items;
    }

    /// All element pointers are invalidated after
    /// calling this function. To get the events
    /// slice, `.buffered()` must be called again.
    fn grow(self: *EventBuffer, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        @branchHint(.cold);
        try self.buffer.ensureUnusedCapacity(allocator, 1);
        self.buffer.expandToCapacity();
    }
},

streams: struct {
    const Streams = @This();

    /// Maps file descriptors directly to their stream addresses.
    table: std.ArrayList(std.Io.net.IpAddress),
    /// Tracks which file descriptors are currently registered,
    /// optimizes also iterator and allows efficient shrink.
    registered: std.DynamicBitSetUnmanaged,

    const init: Streams = .{
        .table = .empty,
        .registered = .{},
    };

    fn deinit(self: *Streams, allocator: std.mem.Allocator, io: std.Io) void {
        var iter = self.iterator();
        while (iter.next()) |stream| stream.close(io);
        self.table.deinit(allocator);
        self.registered.deinit(allocator);
    }

    fn get(self: Streams, fd: linux.fd_t) ?Stream {
        const index: u64 = @intCast(fd);
        if (index >= self.registered.capacity()) return null;
        if (!self.registered.isSet(index)) return null;

        const addr = self.table.items[index];
        return .from(fd, addr);
    }

    fn put(
        self: *Streams,
        allocator: std.mem.Allocator,
        stream: Stream,
    ) std.mem.Allocator.Error!void {
        const fd = stream.fd();
        const index: u64 = @intCast(fd);

        try self.ensure(allocator, fd);
        self.table.items[index] = stream.address();
        self.registered.set(index);
    }

    fn pop(
        self: *Streams,
        allocator: std.mem.Allocator,
        fd: linux.fd_t,
    ) std.mem.Allocator.Error!?Stream {
        const index: u64 = @intCast(fd);
        const stream = self.get(fd) orelse return null;
        self.registered.unset(index);
        // `ensure` grows the table precisely to `fd + 1`, so the last
        // table slot is always occupied by the greatest registered fd.
        if (index == self.table.items.len - 1) {
            // Listener file descriptor is never removed before `.deinit()`.
            // At least one valid file descriptor is present.
            const max_fd: linux.fd_t = @intCast(self.registered.findLastSet() orelse unreachable);
            try self.shrink(allocator, max_fd);
        }
        return stream;
    }

    /// Ensures that table has an accessible slot for fd. If buffer is
    /// smaller, grows it. After calling this function, raw accesses to
    /// table with this file descriptor, never causes out of bounds exceptions.
    fn ensure(
        self: *Streams,
        allocator: std.mem.Allocator,
        fd: linux.fd_t,
    ) std.mem.Allocator.Error!void {
        if (fd >= self.table.items.len) {
            @branchHint(.unlikely);
            const new_len: u64 = @intCast(fd + 1);
            try self.table.ensureTotalCapacityPrecise(allocator, new_len);
            self.table.expandToCapacity();
            try self.registered.resize(allocator, new_len, false);
        }
    }

    fn shrink(
        self: *Streams,
        allocator: std.mem.Allocator,
        max_fd: linux.fd_t,
    ) std.mem.Allocator.Error!void {
        if (self.table.items.len > max_fd) {
            @branchHint(.unlikely);
            const new_len: u64 = @intCast(max_fd + 1);
            try self.table.shrinkAndFreePrecise(allocator, new_len);
            try self.registered.resize(allocator, new_len, false);
        }
    }

    const Iterator = struct {
        s: Streams,
        registered: std.DynamicBitSetUnmanaged.Iterator(.{}),

        fn next(self: *Iterator) ?Stream {
            const fd = self.registered.next() orelse return null;
            return self.s.get(@intCast(fd));
        }
    };

    fn iterator(self: Streams) Iterator {
        return .{
            .s = self,
            .registered = self.registered.iterator(.{}),
        };
    }
},

pub fn listen(allocator: std.mem.Allocator, io: std.Io, config: Config) Error!Listener {
    const server = try config.address.listen(io, .{ .reuse_address = true });
    const server_socket = server.socket;
    setNonBlock(server_socket.handle);

    var self: Listener = .{
        .config = config,
        .epoll_fd = @intCast(linux.epoll_create1(linux.EPOLL.CLOEXEC)),
        .server = server,
        .events = try .init(allocator),
        .streams = .init,
    };
    // Register listener as first file descriptor.
    try self.register(allocator, .fromSocket(server_socket));

    return self;
}

pub fn deinit(self: *Listener, allocator: std.mem.Allocator, io: std.Io) void {
    self.streams.deinit(allocator, io);
    self.events.deinit(allocator);
}

pub const EventQueue = struct {
    listener: *Listener,
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
        const event_type = self.listener.type(event_fd, epoll_event.events);

        return switch (event_type) {
            .new_connection => blk: {
                const server = &self.listener.server;
                const client = Stream.nonBlockAccept(
                    io,
                    server,
                ) catch |err| switch (err) {
                    // Client disconnected during accept. We have to
                    // check if another client is available. self.index
                    // is not incremented to trigger new_connection
                    // label for next call to `.next()`.
                    error.ConnectionAborted => break :blk self.next(allocator, io),

                    // Finally, we have accepted all incoming clients.
                    // self.index has been increased to handle next event.
                    error.WouldBlock => {
                        self.index += 1;
                        break :blk self.next(allocator, io);
                    },
                    else => {
                        // self.index has been increased to avoid error loop.
                        self.index += 1;
                        break :blk .{ .accept_error = err };
                    },
                };

                try self.listener.register(allocator, client);
                // After successful registration of client, we will not
                // increment self.index to handle the same new_connection
                // event and accept other clients.
                break :blk .{ .accepted = client };
            },
            .disconnection => blk: {
                self.index += 1;
                const stream = try self.listener.unregister(allocator, event_fd);
                stream.close(io);
                break :blk .{ .closed = stream.address() };
            },
            .incoming_data => blk: {
                self.index += 1;
                const stream = self.listener.streams.get(event_fd) orelse unreachable;
                break :blk .{ .readable = stream };
            },
            .unknown => blk: {
                @branchHint(.cold);
                self.index += 1;
                break :blk self.next(allocator, io);
            },
        };
    }
};

pub fn collectEvents(
    self: *Listener,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!EventQueue {
    var events = self.events.buffered();
    assert(events.len > 0);
    const rc = linux.epoll_wait(
        self.epoll_fd,
        events.ptr,
        @intCast(events.len),
        self.config.timeout_ms,
    );

    const len: usize = switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => 0, // No events available.
        else => |err| {
            std.debug.panic("epoll_wait: occurred error={t}\n", .{err});
        },
    };

    assert(events.len >= len);
    // More events available than capacity?
    if (len == events.len) {
        @branchHint(.unlikely);
        // More available events for next call to `collectEvents`.
        try self.events.grow(allocator);
        // `grow` invalidates events. We can get slice again.
        events = self.events.buffered();
    }

    return .{ .listener = self, .events = events[0..len] };
}

/// Registers a stream previously accepted.
pub fn register(
    self: *Listener,
    allocator: std.mem.Allocator,
    stream: Stream,
) std.mem.Allocator.Error!void {
    const stream_fd = stream.fd();
    try self.streams.put(allocator, stream);

    var event: linux.epoll_event = .{
        .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
        .data = .{ .fd = stream_fd },
    };

    const rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, stream_fd, &event);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .EXIST => unreachable, // Never exist before registration.
        else => |err| {
            std.debug.panic("epoll_ctl: occurred error={t} with op=add\n", .{err});
        },
    }
}

/// Transfer ownership to caller. The caller is responsible for closing the stream.
pub fn unregister(
    self: *Listener,
    allocator: std.mem.Allocator,
    stream_fd: linux.fd_t,
) std.mem.Allocator.Error!Stream {
    _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, stream_fd, null);
    return try self.streams.pop(allocator, stream_fd) orelse unreachable;
}

const EventType = enum { new_connection, disconnection, incoming_data, unknown };

/// Translates lower-level event to higher-level classification.
fn @"type"(self: Listener, event_fd: linux.fd_t, event: u32) EventType {
    const EPOLL = linux.EPOLL;
    const EPOLL_ERRHUP = EPOLL.ERR | EPOLL.HUP;
    const listener_fd = self.server.socket.handle;
    // zig fmt: off
    if (event_fd == listener_fd)   return .new_connection;
    if (event & EPOLL_ERRHUP != 0) return .disconnection;
    if (event & EPOLL.IN != 0)     return .incoming_data;
    if (event & EPOLL.RDHUP != 0)  return .disconnection;
    // zig fmt: on
    return .unknown;
}

fn setNonBlock(fd: linux.fd_t) void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    var o: linux.O = @bitCast(@as(u32, @intCast(flags)));
    o.NONBLOCK = true;
    const args: u32 = @bitCast(o);
    _ = linux.fcntl(fd, linux.F.SETFL, @intCast(args));
}
