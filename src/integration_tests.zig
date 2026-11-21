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
const Client = @import("Client.zig");

test "integration" {
    const allocator, const io = .{ std.testing.allocator, std.testing.io };

    const server_config: cli.Command.Server = .default;
    var context: Server.Context = try .init(allocator, io, &server_config);
    defer context.deinit(allocator, io);
    const server = context.server();

    var future = try io.concurrent(Server.run, .{ server, allocator, io });
    defer _ = future.cancel(io) catch unreachable;

    errdefer if (@errorReturnTrace()) |trace| {
        // The test runner hides part of the error trace,
        // so we print full stack trace before cleanup.
        std.debug.dumpErrorReturnTrace(trace);
    };

    // All integration tests.
    try integration.commands.run(allocator, io, server_config.address);

    {
        const client_config: Client.Config = .{ .address = server_config.address };
        var client: Client = try .open(io, client_config);
        defer client.close(io);

        var batch = try client.batch(allocator, .{ .pipeline_preserved_size = 64 });
        defer batch.deinit();

        // Procedure to shutdown server.
        try batch.down();
        _ = try batch.flushOneAs(io, .void);
    }
}
