//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of Stream.

const Stream = @This();

const std = @import("std");
const linux = std.os.linux;

pub const ConnectError = std.Io.net.IpAddress.ConnectError || std.posix.SetSockOptError;
pub const AcceptError = std.Io.net.Server.AcceptError || std.posix.SetSockOptError;
pub const ReadError = std.Io.net.Stream.Reader.Error || error{EndOfStream};
pub const WriteError = std.Io.net.Stream.Writer.Error;

const StreamingHeader = u64;

stream: std.Io.net.Stream,

pub fn nonBlockAccept(io: std.Io, server: *std.Io.net.Server) AcceptError!Stream {
    // Waiting stdlib update to use Io instead of this.
    // For now, non-block accept is not supported.
    _ = io;

    var storage: std.Io.Threaded.PosixAddress = undefined;
    var addr_len: linux.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);

    const socket_fd: linux.fd_t = while (true) {
        const rc = linux.accept4(
            server.socket.handle,
            &storage.any,
            &addr_len,
            linux.SOCK.CLOEXEC,
        );

        break switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => continue,
            else => |e| return switch (e) {
                .AGAIN => error.WouldBlock,
                .CONNABORTED => error.ConnectionAborted,
                .INVAL => error.SocketNotListening,
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NOBUFS, .NOMEM => error.SystemResources,
                .PROTO => error.ProtocolFailure,
                .PERM => error.BlockedByFirewall,
                else => |err| {
                    std.debug.panic("unexpected error={t} in nonBlockAccept", .{err});
                },
            },
        };
    };

    return .from(socket_fd, std.Io.Threaded.addressFromPosix(&storage));
}

pub fn connect(io: std.Io, addr: std.Io.net.IpAddress) ConnectError!Stream {
    const stream = try addr.connect(io, .{ .mode = .stream });
    try setNoDelay(stream.socket.handle);
    return .{ .stream = stream };
}

pub fn fromSocket(socket: std.Io.net.Socket) Stream {
    return .{ .stream = .{ .socket = socket } };
}

pub fn from(socket_fd: linux.fd_t, socket_addr: std.Io.net.IpAddress) Stream {
    const socket: std.Io.net.Socket = .{
        .address = socket_addr,
        .handle = socket_fd,
    };
    return .fromSocket(socket);
}

pub fn close(s: Stream, io: std.Io) void {
    s.stream.close(io);
}

pub fn address(s: Stream) std.Io.net.IpAddress {
    return s.stream.socket.address;
}

pub fn fd(s: Stream) linux.fd_t {
    return s.stream.socket.handle;
}

pub fn reader(s: Stream, io: std.Io) std.Io.net.Stream.Reader {
    return s.stream.reader(io, &.{});
}

pub fn writer(s: Stream, io: std.Io) std.Io.net.Stream.Writer {
    return s.stream.writer(io, &.{});
}

fn setNoDelay(socket_fd: linux.fd_t) std.posix.SetSockOptError!void {
    var optval: u32 = 1;
    const optval_bytes = std.mem.asBytes(&optval);
    try std.posix.setsockopt(socket_fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, optval_bytes);
}
