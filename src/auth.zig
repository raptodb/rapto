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
//! It contains the implementation of authentication under TLS.

const std = @import("std");

const socket = @import("socket.zig");

/// Auth system for client and server.
/// Initialized with password.
pub const Auth = struct {
    const Self = @This();

    stream: *socket.Stream,
    tls: *socket.TLS,

    passwd: []const u8,

    /// Initializes Auth with password.
    pub fn init(passwd: []const u8, stream: *socket.Stream, tls: *socket.TLS) Self {
        return Self{ .passwd = passwd, .stream = stream, .tls = tls };
    }

    /// Makes authentication as client with password.
    pub const ClientAuthError = error{ UnmatchKey, AuthNotRequested } || socket.TLS.WriteError;
    pub fn auth(self: Self, allocator: std.mem.Allocator) !void {
        // check if received request for auth password
        if (!self.stream.hasRequest(allocator, "send-authpass"))
            return error.AuthNotRequested;

        // send auth password
        try self.tls.write(allocator, self.passwd);

        if (!self.stream.hasRequest(allocator, "recvd-authpass:OK"))
            return error.UnmatchKey;
    }

    /// Handles client authentication as server.
    /// This is protected with password.
    pub const ServerAuthError = error{UnmatchKey} || socket.TLS.WriteError;
    pub fn handleAuth(self: Self, allocator: std.mem.Allocator) !void {
        // send a request for auth password
        try self.tls.write(allocator, "send-authpass");

        // check if received password match with server password
        if (!self.stream.hasRequest(allocator, self.passwd)) {
            // send bad message
            try self.tls.write(allocator, "recvd-authpass:NO");
            return error.UnmatchKey;
        }

        // send good message
        try self.tls.write(allocator, "recvd-authpass:OK");
    }
};
