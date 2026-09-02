//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of main.

const std = @import("std");
const cli = @import("cli.zig");
const zprof = @import("zprof");
const builtin = @import("builtin");
const log = std.log.scoped(.rapto);
const assert = std.debug.assert;

const Mimalloc = @import("Mimalloc.zig");
const Server = @import("Server.zig");

pub const version = std.SemanticVersion.parse("0.1.0") catch unreachable;

const debug_log_zprof = false;
const zprof_config = if (debug_log_zprof) std.mem.zeroInit(
    zprof.Config,
    .{ .allocated = true, .freed = true, .writerFn = zprofWriterFn },
) else std.mem.zeroInit(
    zprof.Config,
    .{ .allocated = true, .freed = true },
);

fn zprofWriterFn(_: *std.Io.Writer, is_alloc: bool, size: usize) void {
    const text = if (is_alloc) "ALLOCATED" else "DEALLOCATED";
    std.debug.print("{s}={d}\n", .{ text, size });
}

pub fn main(init: std.process.Init.Minimal) u8 {
    if (builtin.os.tag != .linux) @panic("bad os: linux is required\n");

    const command: cli.Command = .parse(init.args);

    // `version` command is handled after to be printed through stdout.
    if (command == .server)
        log.info("Raptodb version {f}", .{version});

    const mimalloc: Mimalloc = .{ .config = .{
        .arena_purge_mult = 10000,
        .page_full_retain = 1,
    } };
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();

    handleCommand(mimalloc.allocator(), threaded.io(), command) catch |err| {
        log.err("occurred fatal error={t}", .{err});
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        return 1;
    };

    return 0;
}

fn handleCommand(gpa: std.mem.Allocator, io: std.Io, command: cli.Command) !void {
    return switch (command) {
        .server => |*args| commandServer(gpa, io, args),

        inline .version, .help => |comptime_command| blk: {
            const stdout: std.Io.File = .stdout();
            var stdout_writer = stdout.writer(io, &.{});
            const writer = &stdout_writer.interface;

            break :blk switch (comptime_command) {
                .version => commandVersion(writer),
                .help => commandHelp(writer),
                else => comptime unreachable,
            };
        },

        else => @panic("unimplemented"),
    };
}

fn commandServer(
    gpa: std.mem.Allocator,
    io: std.Io,
    args: *const cli.Command.Server,
) std.mem.Allocator.Error!void {
    const pid = std.os.linux.getpid();
    log.info("server name={s} pid={d} addr={f}", .{ args.name, pid, args.address });

    var zprof_instance: zprof.Zprof(zprof_config) = .init(gpa, undefined);
    defer if (zprof_instance.profiler.hasLeaks()) {
        @branchHint(.cold);
        const allocated = zprof_instance.profiler.allocated.get();
        const freed = zprof_instance.profiler.freed.get();
        if (std.math.sub(u64, allocated, freed)) |unfreed| {
            log.warn("zprof: memory leak occurred with unfreed={d} bytes", .{unfreed});
        } else |_| {
            log.err("zprof: occurred error=Overflow while calculating unfreed bytes.", .{});
        }
    };
    const allocator = zprof_instance.allocator();

    var context = Server.Context.init(allocator, io, args) catch |err|
        return log.err("occurred error={t} while init server context", .{err});
    defer context.deinit(allocator, io);

    if (context.aof != null) {
        var start: std.Io.Timestamp = .now(io, .awake);
        context.loadAof(allocator, io, args.aof_load_until) catch |err|
            return log.err("occurred error={t} while loading AOF", .{err});
        log.info("loaded AOF file in {f}", .{start.untilNow(io, .awake)});
    }

    const allocated_on_init = zprof_instance.profiler.allocated.get();
    log.info("startup: allocated {d}KB during server init", .{bytesToKiB(allocated_on_init)});

    log.info("server is LISTENING...", .{});
    const server = context.server();
    return server.run(allocator, io);
}

fn commandVersion(stdout: *std.Io.Writer) std.Io.Writer.Error!void {
    return stdout.print("Raptodb version {f}\n", .{version});
}

fn commandHelp(stdout: *std.Io.Writer) std.Io.Writer.Error!void {
    return stdout.writeAll(cli.Command.usage);
}

fn bytesToKiB(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / @as(f64, 1024);
}
