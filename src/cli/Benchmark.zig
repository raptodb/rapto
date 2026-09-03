//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of benchmark command arguments.

const Server = @This();

const std = @import("std");
const log = std.log.scoped(.cli);
const eql = std.mem.eql;

/// IP address of Server, default: 127.0.0.1:7286.
address: std.Io.net.IpAddress,
/// Number of concurrent clients.
clients: u32,
/// Number of operations per batch.
batch_size: u32,
/// Test command to benchmark.
@"test": []const u8,
/// Total number of operations.
ops: u64,
/// Number of preloaded dataset keys.
dataset_keys: u32,
/// Number of batches used as warmup.
warmup_batches: u32,
/// Key size in bytes.
key_size: u32,
/// Value size in bytes.
value_size: u32,

pub fn parse(args: *std.process.Args.Iterator) Server {
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(7286) };
    var clients: u32 = 1;
    var batch_size: u32 = 1;
    var @"test": ?[]const u8 = null;
    var ops: u64 = 100_000;
    var dataset_keys: u32 = 100_000;
    var key_size: u32 = 3;
    var value_size: u32 = 3;
    var warmup_batches: u32 = 512;

    while (args.next()) |flag| {
        if (eql(u8, flag, "--address")) {
            const arg = args.next() orelse
                fatal("expected argument after flag", .{});
            address = std.Io.net.IpAddress.parseLiteral(arg) catch |err| switch (err) {
                error.InvalidAddress => fatal("specified address is invalid", .{}),
                error.InvalidPort => fatal("specified port is invalid", .{}),
            };
        } else if (eql(u8, flag, "--clients")) {
            const arg = args.next() orelse
                fatal("expected argument after flag", .{});
            clients = std.fmt.parseUnsigned(u32, arg, 10) catch
                fatal("specified argument for --clients has wrong conversion", .{});
        } else if (eql(u8, flag, "--warmup-batches")) {
            const arg = args.next() orelse
                fatal("expected argument after flag", .{});
            warmup_batches = std.fmt.parseUnsigned(u32, arg, 10) catch
                fatal("specified argument for --warmup-batches has wrong conversion", .{});
        } else if (eql(u8, flag, "--ops")) {
            const arg = args.next() orelse
                fatal("expected argument after flag", .{});
            ops = std.fmt.parseUnsigned(u64, arg, 10) catch
                fatal("specified argument for --ops has wrong conversion", .{});
        } else if (eql(u8, flag, "--dataset-keys")) {
            const arg = args.next() orelse
                fatal("expected argument after flag", .{});
            dataset_keys = std.fmt.parseUnsigned(u32, arg, 10) catch
                fatal("specified argument for --dataset-keys has wrong conversion", .{});
        } else if (eql(u8, flag, "--key-size")) {
            const arg = args.next() orelse
                fatal("expected argument after flag", .{});
            key_size = std.fmt.parseUnsigned(u32, arg, 10) catch
                fatal("specified argument for --key-size has wrong conversion", .{});
        } else if (eql(u8, flag, "--value-size")) {
            const arg = args.next() orelse
                fatal("expected argument after flag", .{});
            value_size = std.fmt.parseUnsigned(u32, arg, 10) catch
                fatal("specified argument for --value-size has wrong conversion", .{});
        } else if (eql(u8, flag, "--batch-size")) {
            const arg = args.next() orelse
                fatal("expected argument after flag", .{});
            batch_size = std.fmt.parseUnsigned(u32, arg, 10) catch
                fatal("specified argument for --batch-size has wrong conversion", .{});
        } else if (eql(u8, flag, "--test")) {
            @"test" = args.next() orelse fatal("expected argument after flag", .{});
        } else {
            fatal("unknown {s} flag", .{flag});
        }
    }

    if (@"test" == null)
        fatal("missing required --test flag", .{});

    return .{
        .address = address,
        .clients = clients,
        .batch_size = batch_size,
        .@"test" = @"test".?,
        .ops = ops,
        .dataset_keys = dataset_keys,
        .key_size = key_size,
        .value_size = value_size,
        .warmup_batches = warmup_batches,
    };
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.process.exit(1);
}
