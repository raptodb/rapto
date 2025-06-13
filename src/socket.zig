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
//! with deadline implementation and TLS compatibility.

const std = @import("std");

const signal = @import("signal.zig");
const utils = @import("utils.zig");

const posix = std.posix;
const X25519 = std.crypto.dh.X25519;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

/// Limits of 512 MiB for READ
const MAXFLOW = 1024 * 1024 * 512;

/// Stream is an alternative of std.net.Stream with
/// length management, deadline configs and TLS compatibily.
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

/// The TLS handler for server and client.
/// Handles server-to-client handshaking and encryption.
pub const TLS = struct {
    const Self = @This();

    stream: *Stream,

    /// Shared-key is the key for cryptography
    /// generated by server.
    shared_key: [ChaCha20Poly1305.key_length]u8 = undefined,

    /// Nonce is a randomic parameter generated
    /// by server. For every writing increments it.
    nonce: [ChaCha20Poly1305.nonce_length]u8 = undefined,

    /// Initializes TLS as server. It creates randomic
    /// shared-key and nonce.
    pub fn init(stream: *Stream) Self {
        return Self{
            .stream = stream,

            // generates a randomic shared-key and nonce
            .shared_key = genRandomicBytes(ChaCha20Poly1305.key_length),
            .nonce = genRandomicBytes(ChaCha20Poly1305.nonce_length),
        };
    }

    /// Performs a handshake as client. If handshake success returns
    /// TLS struct with shared key, else return an error.
    /// 1. Server sends a request to receive public-key from CLIENT.
    /// 2. CLIENT replies with public-key.
    /// 3. Server encrypts shared-key with public-key and send it to CLIENT.
    /// 4. CLIENT decrypt shared-key with private-key.
    /// 5. Now server and CLIENT have shared-key.
    pub const HandshakeClientError = error{HandshakeFail} || signal.SignalError || Stream.WriteError || ReadError;
    pub fn handshakeClient(allocator: std.mem.Allocator, stream: *Stream) !Self {
        var self = Self{
            .stream = stream,

            // generates a randomic nonce
            .nonce = genRandomicBytes(ChaCha20Poly1305.nonce_length),
        };

        // if request is not send-pk handshake is failed
        if (!self.stream.hasRequest(allocator, "send-pk"))
            return error.HandshakeFail;

        // generates public-key and private-key
        const keys = X25519.KeyPair.generate();

        // send requested public-key
        try self.stream.write(&keys.public_key);

        // request shared-key
        try self.stream.write("send-sk");

        // set secret-key to decrypt shared-key
        @memcpy(&self.shared_key, &keys.secret_key);
        // set shared-key from server
        const shared_key = try self.read(allocator);
        defer allocator.free(shared_key);

        // copy received shared-key to original shared-key
        @memcpy(self.shared_key[0..], shared_key[0..]);

        // finalize assuring the server that
        // the shared-key has been received
        try self.stream.write("recvd-sk");

        return self;
    }

    /// Performs a handshake as server. If handshake fails return an error.
    /// 1. SERVER sends a request to receive public-key from client.
    /// 2. Client replies with public-key.
    /// 3. SERVER encrypts shared-key with public-key and send it to client.
    /// 4. Client decrypt shared-key with private-key.
    /// 5. Now SERVER and client have shared-key.
    pub const HandshakeServerError = error{HandshakeFail} || signal.SignalError || WriteError || Stream.ReadError;
    pub fn handshakeServer(self: *Self, allocator: std.mem.Allocator) HandshakeServerError!void {
        try self.stream.write("send-pk");

        const public_key = try self.stream.read(allocator);
        defer allocator.free(public_key);
        if (public_key.len != 32)
            return error.HandshakeFail;

        // if request is not send-sk handshake is failed
        if (!self.stream.hasRequest(allocator, "send-sk"))
            return error.HandshakeFail;

        // dave shared-key to tmp
        const shared_key = self.shared_key;

        // set public-key as shared key to encrypt original shared-key
        @memcpy(&self.shared_key, public_key);
        // send encrypted shared-key with public-key to client
        try self.write(allocator, &shared_key);

        // set shared-key to original shared-key
        self.shared_key = shared_key;

        // finalize assuring the client that
        // the shared-key has been sended
        if (!self.stream.hasRequest(allocator, "recvd-sk"))
            return error.HandshakeFail;
    }

    /// Reads a stream and decrypt content with shared-key.
    /// The output must be deallocated manually.
    pub const ReadError = error{DecryptionFail} || signal.SignalError || Stream.ReadError;
    pub fn read(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        // reads from stream
        const readed = try self.stream.read(allocator);

        // the readed message must be have nonce and tag,
        // therefore, the length must be greter than nonce and tag length
        if (readed.len <= ChaCha20Poly1305.nonce_length + ChaCha20Poly1305.tag_length)
            return error.DecryptionFail;

        var nonce: [ChaCha20Poly1305.nonce_length]u8 = undefined;
        var tag: [ChaCha20Poly1305.tag_length]u8 = undefined;

        // divide readed to nonce, tag, cipher text
        @memcpy(&nonce, readed[0..ChaCha20Poly1305.nonce_length]);
        @memcpy(&tag, readed[ChaCha20Poly1305.nonce_length .. ChaCha20Poly1305.nonce_length + ChaCha20Poly1305.tag_length]);
        const encr = readed[ChaCha20Poly1305.nonce_length + ChaCha20Poly1305.tag_length ..];

        // allocates plain text
        var plain: []u8 = try allocator.alloc(u8, encr.len);
        errdefer allocator.free(plain);

        // decrypt and save plain text to buf
        ChaCha20Poly1305.decrypt(
            plain[0..],
            encr[0..],
            tag,
            ""[0..],
            nonce,
            self.shared_key,
        ) catch return error.DecryptionFail;

        return plain;
    }

    /// Encrypts data with shared-key and send to a stream.
    pub const WriteError = signal.SignalError || Stream.WriteError;
    pub fn write(self: *Self, allocator: std.mem.Allocator, data: []const u8) WriteError!void {
        // update nonce with next nonce
        var nonce: [ChaCha20Poly1305.nonce_length]u8 = self.nextNonce();
        var tag: [ChaCha20Poly1305.tag_length]u8 = undefined;

        const nonce_tag_enc: []u8 = try allocator.alloc(u8, nonce.len + tag.len + data.len);
        defer allocator.free(nonce_tag_enc);

        // encrypt plain text to buf
        ChaCha20Poly1305.encrypt(
            nonce_tag_enc[nonce.len + tag.len ..],
            tag[0..],
            data,
            "",
            nonce,
            self.shared_key,
        );

        // copy nonce and tag to buf
        @memcpy(nonce_tag_enc[0..nonce.len], nonce[0..]);
        @memcpy(nonce_tag_enc[nonce.len .. nonce.len + tag.len], tag[0..]);

        // send buf to stream and deallocates it
        try self.stream.write(nonce_tag_enc);
    }

    /// Computes next nonce by incrementing buffer.
    fn nextNonce(self: *Self) [ChaCha20Poly1305.nonce_length]u8 {
        var i: usize = self.nonce.len - 1;

        while (i < self.nonce.len) : (i -%= 1) {
            self.nonce[i] +%= 1;
            if (self.nonce[i] != 0) break;
        }

        return self.nonce;
    }
};

/// Generates a randomic bytes with specified size.
pub fn genRandomicBytes(comptime size: usize) [size]u8 {
    var key: [size]u8 = undefined;
    std.crypto.random.bytes(&key);
    return key;
}
