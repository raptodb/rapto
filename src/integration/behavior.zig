//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of integration test
//! about behavior of commands.

const std = @import("std");
const assert = std.debug.assert;

const Client = @import("../Client.zig");

const value = Client.value;
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
        assert(batch.queued == 0);
        try testFunc(io, &batch);

        // Cleanup dataset after test.
        try batch.purge();
        _ = try batch.flushOneAs(io, .void);
    }
}

fn testSetGetRoundtrip(io: std.Io, batch: *Client.Batch) !void {
    {
        const key: Vec = .from("key1");
        const content: value.Scalar = .{ .string = "content for key1" };

        try batch.set(key, content, .{});
        try batch.get(&.{key}, .{});
        const replies = try batch.flush(io);

        // Check if set was successful.
        _ = try replies.peekAtAs(0, .void);

        const get_result = try replies.peekAtAs(1, .list);
        try std.testing.expect(get_result.count() == 1);

        try expectValue(.string, try get_result.peekAt(0), content.string);
    }
    {
        const key: Vec = .from("key100");
        const long_key: Vec = .from(&@as([255]u8, @splat('a')));
        const short_key: Vec = .from("a");

        const dummy_content: value.Scalar = .{ .string = "dummy content" };

        try batch.set(key, dummy_content, .{});
        try batch.set(long_key, dummy_content, .{});
        try batch.set(short_key, dummy_content, .{});
        var set_result = try batch.flush(io);
        // Check if sets were successful.
        while (try set_result.takeAs(.void)) |_| {}

        try batch.get(&.{ key, long_key, short_key }, .{});
        var get_result = try batch.flushOneAs(io, .list);

        try std.testing.expect(get_result.count() == 3);
        while (try get_result.take()) |v| {
            try expectValue(.string, v, dummy_content.string);
        }
    }
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
