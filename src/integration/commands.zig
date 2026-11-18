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
const Vec = Client.Batch.Vec;

pub fn run(allocator: std.mem.Allocator, io: std.Io, address: std.Io.net.IpAddress) !void {
    const client_config: Client.Config = .{ .address = address };
    var client: Client = try .open(io, client_config);
    defer client.close(io);

    var batch = try client.batch(allocator, .{});
    defer batch.deinit();

    const TestFn = *const fn (io: std.Io, batch: *Client.Batch) anyerror!void;
    const test_functions: []const TestFn = &.{
        testSetGetRoundtrip,
    };
    for (test_functions) |testFunc| {
        assert(batch.pending == 0);
        try testFunc(io, &batch);
    }
}

fn testSetGetRoundtrip(io: std.Io, batch: *Client.Batch) !void {
    const key: Vec = .from("key1");

    try batch.set(key, .{ .string = "some text" }, .{});
    try batch.get(&.{key}, .{});

    const replies = try batch.flush(io);
    const r1 = try replies.peekAt(0);
    const r2 = try replies.peekAt(1);

    try std.testing.expect(r1 == .none);
    try std.testing.expect(r2 == .list);
    try std.testing.expect(r2.list.count() == 1);

    const r2_item1 = try r2.list.peekAt(0);

    try expectValue(.string, r2_item1, "some text");
}

fn expectValue(
    comptime value_type: Client.value.Type,
    actual_value: Client.reply.Value,
    expected: anytype,
) !void {
    const actual_type = actual_value.type() orelse return error.TestExpectedEqual;
    try std.testing.expect(actual_type == value_type);
    const value_field = @field(actual_value, @tagName(value_type));
    try std.testing.expectEqualStrings(value_field, expected);
}
