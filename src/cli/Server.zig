//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of server command arguments.

const Server = @This();

const std = @import("std");
const log = std.log.scoped(.cli);
const eql = std.mem.eql;

/// Name of Server instance.
name: []const u8,
/// When this parameter is enabled, writes in AOF
/// in name.raptodb file.
aof: bool,
/// When this parameter is enabled, reads the AOF
/// file. When both `aof` and `aof_file` are enabled
/// writes on file as the same name of `aof_file`.
aof_file: ?[]const u8,
/// Writes every `aof_sync_seconds` to aof file.
/// When is 0, writes always after any query.
aof_sync_seconds: i32,
/// IP address of Server instance, default: 127.0.0.1:7286.
address: std.Io.net.IpAddress,
/// Number of expected keys to exploit Memory preallocation.
expected_keys: u32,
/// Preserved size for IO serialization buffer.
/// Maybe used when clients sends big queries or batches.
io_preserved_size: u64,

pub fn parseServerCommand(args: *std.process.Args.Iterator) Server {
    var name: ?[]const u8 = null;
    var aof: bool = false;
    var aof_file: ?[]const u8 = null;
    var aof_sync_seconds: i32 = 1;
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(7286) };
    var expected_keys: u32 = 4 * 1024;
    var io_preserved_size: u64 = 16 * 1024;

    while (args.next()) |flag| {
        if (eql(u8, flag, "--name")) {
            name = args.next() orelse fatal("expected argument after flag", .{});
        } else if (eql(u8, flag, "--expected-keys")) {
            const arg = args.next() orelse
                fatal("expected argument after flag", .{});
            expected_keys = std.fmt.parseUnsigned(u32, arg, 10) catch
                fatal("specified argument for --expected-keys has wrong conversion", .{});
        } else if (eql(u8, flag, "--io-preserved-size")) {
            const arg = args.next() orelse
                fatal("expected argument after flag", .{});
            io_preserved_size = std.fmt.parseUnsigned(u64, arg, 10) catch
                fatal("specified argument for --io-preserved-size has wrong conversion", .{});
        } else if (eql(u8, flag, "--aof")) {
            aof = true;
        } else if (eql(u8, flag, "--aof-sync-seconds")) {
            const arg = args.next() orelse
                fatal("expected argument after flag", .{});
            aof_sync_seconds = std.fmt.parseUnsigned(i32, arg, 10) catch
                fatal("specified argument for --aof-sync-seconds has wrong conversion", .{});
        } else if (eql(u8, flag, "--aof-file")) {
            aof_file = args.next() orelse fatal("expected argument after flag", .{});
        } else if (eql(u8, flag, "--address")) {
            const arg = args.next() orelse
                fatal("expected argument after flag", .{});
            address = std.Io.net.IpAddress.parseLiteral(arg) catch |err| switch (err) {
                error.InvalidAddress => fatal("specified address is invalid", .{}),
                error.InvalidPort => fatal("specified port is invalid", .{}),
            };
        } else {
            fatal("unknown {s} flag", .{flag});
        }
    }

    if (name == null)
        fatal("missing required --name flag", .{});

    return .{
        .name = name.?,
        .aof = aof,
        .aof_file = aof_file,
        .aof_sync_seconds = aof_sync_seconds,
        .address = address,
        .expected_keys = expected_keys,
        .io_preserved_size = io_preserved_size,
    };
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.process.exit(1);
}
