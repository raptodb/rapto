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

const signal = @import("signal.zig");
const utils = @import("utils.zig");
const log = @import("log.zig");
const ree = @import("ree.zig");

const ThreadSafeQueue = @import("queue.zig").ThreadSafeQueue;
const Query = @import("Query.zig");
const RaptoConfig = @import("options.zig").RaptoConfig;
const Client = @import("Client.zig");

pub const Server = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    logger: *log.Logger,

    server: std.net.Server,
    clients: std.ArrayList(*Client),
    queue: *ThreadSafeQueue(Query),

    conf: *RaptoConfig,

    pub const BindError = error{ BindError, OutOfMemory };
    pub const ClientError = Client.SendError || Client.RecvError || error{UnmatchVersion};

    /// Initializes and binds server.
    pub fn bind(
        allocator: std.mem.Allocator,
        logger: *log.Logger,
        queue: *ThreadSafeQueue(Query),
        conf: *RaptoConfig,
    ) BindError!Self {
        var at_addr = std.net.Address{ .in = conf.addr.? };
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
    pub fn listen(self: *Self) void {
        var id: u64 = 0;

        while (true) {
            const conn = self.server.accept() catch |err| {
                self.logger.warning("posix-accept: {s}.", .{@errorName(err)});
                continue;
            };

            const client = Client.initServerIO(self.allocator, id, &conn) catch signal.OOM();
            client.setupSockopt() catch |err| {
                client.log(self.logger, .warning, "posix-setsockopt: {s}.", .{@errorName(err)});
                client.close();
                client.deinit(self.allocator);
                continue;
            };
            // update incremental ID counter
            // for next client
            id += 1;

            const t = utils.spawn(Server.handleClientWrapper, .{ self, client }) catch continue;
            t.detach();
        }
    }

    /// Wrapper for client handler.
    /// This function handles errors.
    fn handleClientWrapper(self: *Self, client: *Client) void {
        self.handleClient(client) catch |err| if (err != error.NotOpenForReading) {
            @branchHint(.unlikely);

            const msg = switch (err) {
                error.OutOfMemory => signal.OOM(),
                // already disconnected (likely deinit)
                error.SocketNotConnected, error.AddressNotAvailable => return,
                else => ree.expandClientError(err, self.allocator) catch signal.OOM(),
            };

            client.send(msg) catch {};
        };

        self.destroyClient(client);
    }

    /// Client handler. Setups and reads queries.
    fn handleClient(self: *Self, client: *Client) ClientError!void {
        // check if version matching with server version.
        // Next get the conventional name of client and add to
        // accepted clients.
        {
            // as first message, client send its version.
            // if version matching with server version is ok,
            // else throws error.
            const match_version = blk: {
                const recv_version = client.recv(self.allocator) catch break :blk false;
                defer self.allocator.free(recv_version);
                break :blk utils.advancedCompare(recv_version, RAPTO_VERSION);
            };
            if (!match_version) return error.UnmatchVersion;
            try client.send("OK");

            // try to get name of client

            const name = try client.recv(self.allocator);
            client.name = if (name.len > 0) name else null;

            // add current client to list
            // of connected clients
            try utils.appendNoGrowing(*Client, self.allocator, &self.clients, client);
        }

        client.log(self.logger, .info, "Connected.", .{});

        // receive query from client
        // and add to queue
        while (true) while (client.recv(self.allocator)) |raw_query| {
            // very hot branch!!
            @branchHint(.likely);

            // parseQuery make no allocation,
            // free only if error is occurred
            errdefer self.allocator.free(raw_query);

            const query = Query.fromText(client, raw_query) catch |err| {
                @branchHint(.unlikely);

                // if query parsing fails, send
                // error to client and waits new query
                client.send(ree.expandQueryParsingError(err)) catch {};
                continue;
            };

            // adding query to queue associated with client.
            // useful to return the response.
            try self.queue.put(self.allocator, query);
        }
        // an error is occurred during
        // stream reading
        else |err| switch (err) {
            error.EndOfStream, // error of broken message
            error.WouldBlock, // error of read timeout
            error.InvalidLength, // error of corrupted message (similar to EOF)
            => {}, // retries to next message from client by returning error

            // else returns error and closes client connection
            else => return err,
        };
    }

    /// Removes and closes stream of a client.
    pub fn destroyClient(self: *Self, client: *Client) void {
        const i = std.mem.indexOfScalar(*Client, self.clients.items, client) orelse return;

        client.log(self.logger, .info, "Disconnected.", .{});

        client.deinit(self.allocator);
        _ = self.clients.orderedRemove(i);
    }

    /// Closes and deinits clients.
    pub fn deinit(self: *Self) void {
        // close clients
        for (self.clients.items) |client|
            // call exception in handler
            // trigging destroyClient
            client.close();

        // deinit clients
        self.clients.deinit(self.allocator);
        self.server.deinit();

        self.* = undefined;
    }
};

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}
