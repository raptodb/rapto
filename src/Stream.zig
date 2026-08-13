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

    const socket: std.Io.net.Socket = .{
        .handle = socket_fd,
        .address = std.Io.Threaded.addressFromPosix(&storage),
    };

    return .fromSocket(socket);
}

pub fn connect(io: std.Io, addr: std.Io.net.IpAddress) ConnectError!Stream {
    const stream = try addr.connect(io, .{ .mode = .stream });
    try setNoDelay(stream.socket.handle);
    return .{ .stream = stream };
}

pub fn fromSocket(socket: std.Io.net.Socket) Stream {
    return .{ .stream = .{ .socket = socket } };
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

pub fn writeOutgoing(self: Stream, io: std.Io, data: []const u8) WriteError!void {
    var writer = self.stream.writer(io, &.{});

    var header: [@sizeOf(StreamingHeader)]u8 = undefined;
    std.mem.writeInt(StreamingHeader, &header, data.len, .little);
    var buf: [2][]const u8 = .{ &header, data };
    writer.interface.writeSplatAll(&buf, 1) catch |err| return switch (err) {
        error.WriteFailed => writer.err.?,
    };
}

pub fn readIncomingSize(self: Stream, io: std.Io) ReadError!u64 {
    var buf: [@sizeOf(StreamingHeader)]u8 = undefined;
    var reader = self.stream.reader(io, &buf);
    return reader.interface.takeInt(
        StreamingHeader,
        .little,
    ) catch |err| return switch (err) {
        error.ReadFailed => reader.err.?,
        error.EndOfStream => |e| e,
    };
}

pub fn readIncoming(self: Stream, io: std.Io, buf: []u8) ReadError!void {
    var reader = self.stream.reader(io, &.{});
    reader.interface.readSliceAll(buf) catch |err| return switch (err) {
        error.ReadFailed => reader.err.?,
        error.EndOfStream => |e| e,
    };
}

fn setNoDelay(socket_fd: linux.fd_t) std.posix.SetSockOptError!void {
    var optval: u32 = 1;
    const optval_bytes = std.mem.asBytes(&optval);
    try std.posix.setsockopt(socket_fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, optval_bytes);
}
