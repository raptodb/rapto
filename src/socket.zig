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
//! It contains the implementation of socket stream
//! with deadline implementation.

const std = @import("std");

const signal = @import("signal.zig");
const utils = @import("utils.zig");

const posix = std.posix;

/// Limits of 512 MiB for READ
const MAXFLOW = 1024 * 1024 * 512;

/// Stream is an alternative of std.net.Stream with
/// length management and deadline configs.
pub const Stream = struct {
    const Self = @This();

    pub const ReadError = posix.ReadError || signal.SignalError || error{ InvalidLength, EndOfStream };
    pub const WriteError = posix.WriteError;

    reader: std.io.Reader(*Self, posix.ReadError, rawRead) = undefined,
    writer: std.io.Writer(*Self, posix.WriteError, rawWrite) = undefined,

    /// File descriptor for socket
    handle: posix.socket_t,

    /// Initializes Stream with posix file descriptor.
    pub fn init(allocator: std.mem.Allocator, handle: posix.socket_t) signal.SignalError!*Stream {
        var s = try allocator.create(Stream);
        s.* = Stream{ .handle = handle };
        s.reader = std.io.Reader(*Stream, posix.ReadError, rawRead){ .context = s };
        s.writer = std.io.Writer(*Stream, posix.WriteError, rawWrite){ .context = s };
        return s;
    }

    fn rawRead(self: *Self, buf: []u8) posix.ReadError!usize {
        return posix.read(self.handle, buf);
    }

    fn rawWrite(self: *Self, buf: []const u8) posix.WriteError!usize {
        return posix.write(self.handle, buf);
    }

    /// Reads from stream. The buf is discarded if
    /// its length is 0 or over MAXFLOW.
    pub fn read(self: *Self, allocator: std.mem.Allocator) ReadError![]u8 {
        var buflen: [8]u8 = undefined;
        const bufsize = try self.reader.readAll(&buflen);
        if (bufsize == 0) return error.ConnectionResetByPeer;
        if (bufsize != 8) return error.EndOfStream;

        var len = std.mem.readInt(u64, &buflen, .little);
        if (len == 0 or len > MAXFLOW)
            return error.InvalidLength;

        const buf: []u8 = try allocator.alloc(u8, len);
        // receive buf according to length
        len = try self.reader.readAll(buf);

        return buf[0..len];
    }

    /// Writes to stream.
    pub fn write(self: *Self, buf: []const u8) WriteError!void {
        if (buf.len == 0) return;

        // send length of buf
        try self.writer.writeInt(u64, buf.len, .little);
        // send buf
        try self.writer.writeAll(buf);
    }

    /// Checks if received buf has correspondences.
    pub fn hasRequest(self: *Self, allocator: std.mem.Allocator, request: []const u8) bool {
        const readed = self.read(allocator) catch return false;
        defer allocator.free(readed);

        return utils.advancedCompare(readed, request);
    }

    /// Disables Nagle's algorithm.
    /// Optimizes network performance.
    pub fn disableNagle(self: *Self) error{SocketConfig}!void {
        const val: u32 = 1;
        posix.setsockopt(
            self.handle,
            posix.IPPROTO.TCP,
            posix.TCP.NODELAY,
            @as([*]const u8, @ptrCast(&val))[0..4],
        ) catch return error.SocketConfig;
    }

    /// Sets the timeout for read function.
    /// Accepts milliseconds parameter.
    pub fn setReadDeadline(self: *Self, ms: u32) error{SocketConfig}!void {
        const opt = posix.timeval{
            .sec = @intCast(@divTrunc(ms, std.time.ms_per_s)),
            .usec = @intCast(@mod(ms, std.time.ms_per_s)),
        };

        posix.setsockopt(
            self.handle,
            posix.SOL.SOCKET,
            posix.SO.RCVTIMEO,
            std.mem.toBytes(opt)[0..],
        ) catch return error.SocketConfig;
    }

    /// Sets the timeout for write function.
    /// Accepts milliseconds parameter.
    pub fn setWriteDeadline(self: *Self, ms: u32) error{SocketConfig}!void {
        const opt = posix.timeval{
            .sec = @intCast(@divTrunc(ms, std.time.ms_per_s)),
            .usec = @intCast(@mod(ms, std.time.ms_per_s)),
        };

        posix.setsockopt(
            self.handle,
            posix.SOL.SOCKET,
            posix.SO.SNDTIMEO,
            std.mem.toBytes(opt)[0..],
        ) catch return error.SocketConfig;
    }

    /// Closes stream.
    pub fn close(self: Self) void {
        posix.close(self.handle);
    }
};

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}
