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
//! It contains the implementation of server.

const RAPTO_VERSION = @import("rapto.zig").RAPTO_VERSION;

const DEADLINE_MS = 5000;

const std = @import("std");

const socket = @import("socket.zig");
const signal = @import("signal.zig");
const log = @import("log.zig");
const ree = @import("ree.zig");

const ThreadSafeQueue = @import("queue.zig").ThreadSafeQueue;
const Query = @import("Query.zig");
const Auth = @import("auth.zig").Auth;
const RaptoConfig = @import("rapto.zig").RaptoConfig;

/// Represents client with informations
/// and streams.
pub const Client = struct {
    /// Client unique ID.
    id: u64,
    /// Address of client
    address: std.net.Address,
    /// Name of client.
    name: ?[]const u8 = null,

    /// Stream of client
    stream: *socket.Stream,
    // TLS wrapper for stream
    tls_stream: ?socket.TLS = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.stream.close();

        if (self.name) |n|
            allocator.free(n);
        allocator.destroy(self.stream);

        self.* = undefined;
    }
};

pub const Server = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    logger: *log.Logger,

    server: std.net.Server,
    clients: std.ArrayListUnmanaged(*Client),
    queue: *ThreadSafeQueue(Query),

    conf: *RaptoConfig,

    /// Initializes and binds server.
    pub const BindError = signal.SignalError || error{BindError};
    pub fn bind(
        allocator: std.mem.Allocator,
        logger: *log.Logger,
        address: std.net.Ip4Address,
        queue: *ThreadSafeQueue(Query),
        conf: *RaptoConfig,
    ) BindError!Self {
        var at_addr = std.net.Address{ .in = address };
        const server = at_addr.listen(.{}) catch return error.BindError;

        return Self{
            .allocator = allocator,
            .logger = logger,
            .server = server,
            .clients = try .initCapacity(allocator, 0),
            .queue = queue,
            .conf = conf,
        };
    }

    /// Listen clients and accept clients.
    /// Supports TLS traffic and authentication.
    pub fn listen(self: *Self) void {
        var id: u64 = 0;

        while (true) {
            const conn = self.server.accept() catch continue;

            const client = self.allocator.create(Client) catch signal.OOM();
            errdefer self.allocator.destroy(client);

            // save client info
            client.* = .{
                .id = id,
                .stream = socket.Stream.init(self.allocator, conn.stream.handle) catch signal.OOM(),
                .address = conn.address,
            };

            // update incremental ID counter
            // for next client
            id += 1;

            const t = std.Thread.spawn(.{}, Server.handleClientWrapper, .{ self, client }) catch continue;
            t.detach();
        }
    }

    /// Wrapper for client handler.
    /// This function handles errors.
    fn handleClientWrapper(self: *Self, client: *Client) void {
        client.stream.setReadDeadline(DEADLINE_MS) catch return;
        client.stream.setWriteDeadline(DEADLINE_MS) catch return;

        self.handleClient(client) catch |err| {
            const msg = switch (err) {
                error.OutOfMemory => signal.OOM(),

                // already disconnected (likely deinit)
                error.NotOpenForReading, error.NotOpenForWriting => return,
                else => ree.expandClientError(err),
            };

            client.stream.write(msg) catch {};
        };

        self.logger.info("CLIENT [id={d};name={s};{}] Disconnected.", .{ client.id, client.name orelse "", client.address });
        self.destroyClient(client);
    }

    /// Client handler. Setups and reads queries.
    pub const ClientError = error{
        UnmatchVersion,
        HandshakeFail,
        UnmatchKey,
        DecryptionFail,
    } || socket.Stream.ReadError || socket.Stream.WriteError;
    fn handleClient(self: *Self, client: *Client) ClientError!void {
        // check if version matching with server version
        // and auth client with TLS and Auth. If they are enabled.
        // Next get the conventional name of client and add to
        // accepted clients.
        {
            // as first message, client send its version.
            // if version matching with server version is ok,
            // else throws error.
            const match_version = client.stream.hasRequest(self.allocator, RAPTO_VERSION);
            if (!match_version) return error.UnmatchVersion;

            // authentication block for TLS and Auth.
            // if TLS is enabled, starting TLS handshake
            if (self.conf.tls) {
                client.tls_stream = .init(client.stream);

                // try TLS handshake
                try client.tls_stream.?.handshakeServer(self.allocator);

                // if auth is enabled, requests password to
                // client for access
                if (self.conf.auth) |auth_pass| {
                    const auth = Auth.init(auth_pass, client.stream, &client.tls_stream.?);

                    // request authentication to client
                    try auth.handleAuth(self.allocator);
                }
            }

            // try to get name of client
            const name = try client.stream.read(self.allocator);
            client.name = if (name.len > 0) name else null;

            // grow memory 1 at a time
            try self.clients.ensureTotalCapacityPrecise(self.allocator, self.clients.items.len + 1);
            // add current client to list
            // of connected clients
            self.clients.appendAssumeCapacity(client);
        }

        self.logger.info("CLIENT [id={d};name={s};{}] Connected.", .{ client.id, client.name orelse "", client.address });

        // read query and add to queue
        while (true) {
            // receive query from client
            const recvd = if (client.tls_stream) |*tls|
                tls.read(self.allocator)
            else
                client.stream.read(self.allocator);

            if (recvd) |raw_query| {
                // parseQuery make no allocation,
                // free only if error is occurred
                errdefer self.allocator.free(raw_query);

                // adding query to queue associated with client.
                // useful to return the response.
                try self.queue.put(
                    self.allocator,
                    Query.parseQuery(client, raw_query) catch continue,
                );
            }

            // if error is EOF message is corrupted.
            // if error is WouldBlock read timeout is reached.
            // if error is InvalidLength message is corrupted.
            // if one of these errors are occurred, retry to next message from client.
            else |err| if (err != error.EndOfStream and err != error.WouldBlock and err != error.InvalidLength) return err;
        }
    }

    /// Removes and closes stream of a client.
    pub fn destroyClient(self: *Self, client: *Client) void {
        const i = std.mem.indexOfScalar(*Client, self.clients.items, client) orelse return;

        client.deinit(self.allocator);
        _ = self.clients.orderedRemove(i);
        self.allocator.destroy(client);
    }

    /// Closes and deinits clients.
    pub fn deinit(self: *Self) void {
        // close clients
        for (self.clients.items) |client| {
            self.logger.info("CLIENT [id={d};name={s};{}] Disconnected.", .{ client.id, client.name.?, client.address });
            self.destroyClient(client);
        }

        // deinit clients
        self.clients.deinit(self.allocator);
        self.server.deinit();

        self.* = undefined;
    }
};
