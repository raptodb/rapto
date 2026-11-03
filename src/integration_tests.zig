//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of integration test entry point.

const std = @import("std");
const cli = @import("cli.zig");
const assert = std.debug.assert;
const integration = .{
    .commands = @import("integration/commands.zig"),
};

const Server = @import("Server.zig");

test "integration" {
    const allocator, const io = .{ std.testing.allocator, std.testing.io };

    const server_config: cli.Command.Server = .default;
    var context: Server.Context = try .init(allocator, io, &server_config);
    defer context.deinit(allocator, io);
    const server = context.server();

    assert(server.config.aof_sync_seconds > 0);
    var future = try io.concurrent(Server.run, .{ server, allocator, io });
    defer _ = future.cancel(io) catch {};

    // All integration tests.
    try integration.commands.run(allocator, io, server_config.address);
}
