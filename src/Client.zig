//! BSD 3-Clause License
//!
//! Copyright (c) raptodb
//! Copyright (c) Andrea Vaccaro
//! All rights reserved.
//!
//! Redistribution and use in source and binary forms, with or without
//! modification, are permitted provided that the following conditions are met:
//!
//! 1. Redistributions of source code must retain the above copyright notice, this
//!    list of conditions and the following disclaimer.
//!
//! 2. Redistributions in binary form must reproduce the above copyright notice,
//!    this list of conditions and the following disclaimer in the documentation
//!    and/or other materials provided with the distribution.
//!
//! 3. Neither the name of the copyright holder nor the names of its
//!    contributors may be used to endorse or promote products derived from
//!    this software without specific prior written permission.
//!
//! THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//! AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//! IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//! DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
//! FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//! DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//! SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//! CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//! OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//! OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//!
//! This file is part of "Rapto".
//! It contains the implementation of client and IO functions associated to client for server.

const RAPTO_VERSION = @import("rapto.zig").RAPTO_VERSION;

const std = @import("std");

const signal = @import("signal.zig");
const Logger = @import("log.zig").Logger;

const Self = @This();

/// Limits of 512 MiB for READ
const MAXFLOW = 1024 * 1024 * 512;
const DEADLINE_MS = 5000;

/// Client unique ID.
id: u64 = undefined,
/// Address of client.
address: std.net.Address = undefined,
/// Name of client.
name: ?[]const u8 = null,

/// File descriptor of client stream.
handle: std.posix.socket_t,

writer: std.net.Stream.Writer,
reader: std.net.Stream.Reader,

pub const SendError = std.net.Stream.WriteError;
pub const RecvError = std.net.Stream.ReadError || error{ InvalidLength, EndOfStream, OutOfMemory };

/// Initializes client with ID and connection.
/// With this function an IO writer/reader are provided
/// to send and receive buf from peers.
/// Next establishes connection with server.
///
/// NOTE: with this initialization `self.address` and
/// `self.log()` must not be used.
pub fn initClient(
    allocator: std.mem.Allocator,
    stream: *const std.net.Stream,
    name: []const u8,
) (std.posix.SetSockOptError || SendError || RecvError || error{UnmatchVersion})!*Self {
    const client = try allocator.create(Self);
    errdefer allocator.destroy(client);

    // use buffering on reader to
    // make takeInt working with 8 bytes
    var buf: [8]u8 = undefined;

    // save client info and setup with setsockopt
    client.* = .{
        .handle = stream.handle,
        .writer = stream.writer(&.{}),
        .reader = stream.reader(&buf),
    };

    try client.setupSockopt();

    // check compatibility by version
    try client.send(RAPTO_VERSION);
    const response = try client.recv(allocator);
    defer allocator.free(response);
    if (!std.mem.eql(u8, response, "OK")) @panic(response);

    // send conventional client name
    try client.send(name);

    return client;
}

/// Initializes IO associated to client with ID and connection.
/// With this function an IO writer/reader are provided
/// to send and receive buf from peers.
pub fn initServerIO(allocator: std.mem.Allocator, id: u64, connection: *const std.net.Server.Connection) error{OutOfMemory}!*Self {
    const client = try allocator.create(Self);
    errdefer allocator.destroy(client);

    // use buffering on reader to
    // make takeInt working with 8 bytes
    var buf: [8]u8 = undefined;

    // save client info and setup with setsockopt
    client.* = .{
        .id = id,
        .handle = connection.stream.handle,
        .writer = connection.stream.writer(&.{}),
        .reader = connection.stream.reader(&buf),
        .address = connection.address,
    };

    return client;
}

/// Setup client with configs. Enables ReuseAddr and disables
/// Nagle's algorithm to improve general perforamance.
/// Sets deadline with timeout for read and write stream.
pub fn setupSockopt(self: *Self) std.posix.SetSockOptError!void {
    const val: u32 = 1;

    // enable REUSEADDR to use same address more frequently
    try self.setsockopt(std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&val));
    // disable Nagle's algorithm and optimizes network performance
    try self.setsockopt(std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&val));

    const opt: std.posix.timeval = .{
        .sec = @intCast(@divTrunc(DEADLINE_MS, std.time.ms_per_s)),
        .usec = @intCast(@mod(DEADLINE_MS, std.time.ms_per_s)),
    };
    const so = [2]comptime_int{ std.posix.SO.RCVTIMEO, std.posix.SO.SNDTIMEO };
    inline for (so) |optname|
        // set the timeout for recv/send function.
        try self.setsockopt(std.posix.SOL.SOCKET, optname, std.mem.toBytes(opt)[0..]);
}

/// Sends query and return the response.
/// If bench is enabled, returns as second parameter
/// the latency of response in ns.
///
/// NOTE: this function is exclusive of initialization as client.
pub fn sendQuery(self: *Self, allocator: std.mem.Allocator, query: []const u8, comptime bench: bool) !struct { []const u8, ?u64 } {
    var timer: std.time.Timer = if (bench)
        std.time.Timer.start() catch unreachable
    else
        undefined;

    try self.send(query);
    const response = try self.recv(allocator);

    return .{
        response,
        if (bench) timer.read() else null,
    };
}

/// Sends a buf to peer with length information.
pub fn send(self: *Self, buf: []const u8) SendError!void {
    // build msg using iovec method
    var msg: [2][]const u8 = .{
        // length of content as u64
        @constCast(&@as([8]u8, @bitCast(buf.len))),
        // content
        @constCast(buf),
    };

    // send iovecs to file descriptor
    self.writer.interface.writeVecAll(&msg) catch return self.writer.err.?;
}

/// Receives message from peer. Uses length to read all message
/// without corruption. If returns error.ConnectionResetByPeer, peer
/// has disconnected from session.
pub fn recv(self: *Self, allocator: std.mem.Allocator) RecvError![]u8 {
    var buf: [8]u8 = undefined;
    const raw_len = self.reader.interface().readSliceShort(&buf) catch return self.reader.getError().?;

    switch (raw_len) {
        8 => {
            @branchHint(.likely);

            // convert buf to content length
            const len = std.mem.readInt(u64, &buf, .little);
            if (len == 0 or len > MAXFLOW) {
                @branchHint(.unlikely);
                return error.InvalidLength;
            }

            // receive buf according to length
            return self.reader.interface().readAlloc(allocator, len) catch |err| return switch (err) {
                error.ReadFailed => self.reader.getError().?,
                else => @errorCast(err),
            };
        },
        // disconnected peer
        0 => return error.ConnectionResetByPeer,
        // corrupted message
        else => return error.EndOfStream,
    }
}

/// Logs a message with client information.
pub inline fn log(
    self: *Self,
    logger: *Logger,
    logtype: enum { info, warning, critical },
    comptime format: []const u8,
    args: anytype,
) void {
    const msg = std.fmt.allocPrint(logger.allocator, format, args) catch signal.OOM();
    const f = "CLIENT [id={d};name={s};{f}] {s}";
    switch (logtype) {
        .info => logger.info(f, .{ self.id, self.name orelse "", self.address, msg }),
        .warning => logger.warning(f, .{ self.id, self.name orelse "", self.address, msg }),
        .critical => logger.critical(f, .{ self.id, self.name orelse "", self.address, msg }),
    }
}

/// Alias fot std.posix.setsockopt with handle
/// integrated and cleaner API.
inline fn setsockopt(self: *Self, level: i32, optname: u32, opt: []const u8) std.posix.SetSockOptError!void {
    return std.posix.setsockopt(self.handle, level, optname, opt);
}

/// Closes connection with peer.
pub inline fn close(self: *Self) void {
    std.posix.close(self.handle);
}

/// Destroy client. Deallocates all memory associated with it.
/// NOTE: does not closes connection with peer, first, call `close()`.
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (self.name) |n|
        allocator.free(n);

    allocator.destroy(self);

    self.* = undefined;
}

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}
