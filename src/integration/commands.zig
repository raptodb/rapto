//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of integration test
//! about basic commands.

const std = @import("std");
const assert = std.debug.assert;

const Client = @import("../Client.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, address: std.Io.net.IpAddress) !void {
    const client_config: Client.Config = .{ .address = address };
    var client: Client = try .open(io, client_config);
    defer client.close(io);

    var batch = try client.batch(allocator, .{});
    defer batch.deinit();

    try basicSetGet(io, &batch);
}

pub fn basicSetGet(io: std.Io, batch: *Client.Batch) !void {
    assert(batch.pending == 0);

    try batch.set(.from("key1"), .{ .string = "some text" }, .{});
    try batch.get(&.{.from("key1")}, .{});

    const replies = try batch.flush(io);
    const r1 = try replies.at(0);
    const r2 = try replies.at(1);

    try std.testing.expect(r1 == .none);
    try std.testing.expect(r2 == .list);
    try std.testing.expect(r2.list.count() == 1);

    const r2_item1 = try r2.list.at(0);

    try std.testing.expect(r2_item1 == .string);
    try std.testing.expectEqualStrings(r2_item1.string, "some text");
}
