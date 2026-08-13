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

pub const Notification = union(enum) {
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
    /// When address is null, file descriptor is not registered.
    table: std.ArrayList(?std.Io.net.IpAddress),

    const init: Streams = .{ .table = .empty };

    fn deinit(self: *Streams, allocator: std.mem.Allocator, io: std.Io) void {
        var iter = self.iterator();
        while (iter.next()) |stream| stream.close(io);
        self.table.deinit(allocator);
    }

    fn get(self: Streams, fd: linux.fd_t) ?Stream {
        assert(fd >= 0);
        if (fd >= self.table.items.len) return null;
        const addr = self.table.items[@intCast(fd)] orelse return null;
        return .from(fd, addr);
    }

    fn put(
        self: *Streams,
        allocator: std.mem.Allocator,
        stream: Stream,
    ) std.mem.Allocator.Error!void {
        const fd = stream.fd();
        assert(fd >= 0);
        try self.ensure(allocator, fd);
        self.table.items[@intCast(fd)] = stream.address();
    }

    fn pop(self: *Streams, fd: linux.fd_t) ?Stream {
        assert(fd >= 0);
        const stream = self.get(fd) orelse return null;
        self.table.items[@intCast(fd)] = null;
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
            @branchHint(.cold);
            const new_cap: u64 = @intCast(fd + 1);
            try self.table.ensureTotalCapacityPrecise(allocator, new_cap);
            self.table.expandToCapacity();
        }
    }

    const Iterator = struct {
        s: Streams,
        // Used as index.
        fd: linux.fd_t = 0,

        fn next(self: *Iterator) ?Stream {
            while (self.fd < self.s.table.items.len) {
                const maybe_stream = self.s.get(self.fd);
                self.fd += 1;
                if (maybe_stream) |stream| return stream;
            }
            return null;
        }
    };

    fn iterator(self: Streams) Iterator {
        return .{ .s = self };
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
    ) std.mem.Allocator.Error!?Notification {
        if (self.index >= self.events.len) return null;

        const epoll_event = self.events[self.index];
        const event_fd = epoll_event.data.fd;
        const event_type = self.listener.type(event_fd, epoll_event.events);

        return switch (event_type) {
            .new_connection => blk: {
                const server = &self.listener.server;
                const client = Stream.nonBlockAccept(io, server) catch |err| {
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
                try self.listener.register(allocator, client);
                // After successful registration of client, we will not
                // increment self.index to handle the same new_connection
                // event and accept other clients.
                break :blk .{ .accepted = client };
            },
            .disconnection => blk: {
                self.index += 1;
                const stream = self.listener.unregister(event_fd);
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
pub fn unregister(self: *Listener, stream_fd: linux.fd_t) Stream {
    _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, stream_fd, null);
    return self.streams.pop(stream_fd) orelse unreachable;
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
