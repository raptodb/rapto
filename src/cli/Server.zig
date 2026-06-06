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
/// Maximum database capacity in bytes.
/// This capacity will be allocated at disk.
memory_size: u64,
/// When this parameter is enabled, writes in AOF
/// in name.raptodb file.
aof: ?bool,
/// When this parameter is enabled, reads the AOF
/// file. When both `aof` and `aof_file` are enabled
/// writes on file as the same name of `aof_file`.
aof_file: ?[]const u8,
/// Writes every `aof_sync_seconds` to aof file.
/// When is 0, writes always after any query.
aof_sync_seconds: ?i32,
/// IP address of Server instance, default Rapto port is 7286.
address: ?std.Io.net.IpAddress,

pub fn parseServerCommand(args: *std.process.Args.Iterator) Server {
    var name: ?[]const u8 = null;
    var memory_size: ?u64 = null;
    var aof: ?bool = null;
    var aof_file: ?[]const u8 = null;
    var aof_sync_seconds: ?i32 = null;
    var address: ?std.Io.net.IpAddress = null;

    while (args.next()) |flag| {
        if (eql(u8, flag, "--name")) {
            name = args.next() orelse fatal("expected argument after flag", .{});
        } else if (eql(u8, flag, "--memory-size")) {
            const arg = args.next() orelse
                fatal("expected argument after flag", .{});
            memory_size = std.fmt.parseUnsigned(u64, arg, 10) catch
                fatal("specified argument for --memory-size has wrong conversion", .{});
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
    if (memory_size == null)
        fatal("missing required --memory-size flag", .{});

    return .{
        .name = name.?,
        .memory_size = memory_size.?,
        .aof = aof,
        .aof_file = aof_file,
        .aof_sync_seconds = aof_sync_seconds,
        .address = address,
    };
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.process.exit(1);
}
