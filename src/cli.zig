//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of cli parsing.

const std = @import("std");
const log = std.log.scoped(.cli);
const assert = std.debug.assert;
const eql = std.mem.eql;

pub const Command = union(enum) {
    const Tag = std.meta.Tag(Command);

    pub const Server = @import("cli/Server.zig");
    pub const Benchmark = @import("cli/Benchmark.zig");

    server: Server,
    benchmark: Benchmark,
    inspect,

    version,
    help,

    pub fn parse(args: std.process.Args) Command {
        var iterator = args.iterate();
        // Skips executable name.
        assert(iterator.skip());

        const maybe_command = iterator.next() orelse
            fatal("command is missing", .{});
        const command: Tag = std.meta.stringToEnum(Tag, maybe_command) orelse
            fatal("unknown '{s}' command", .{maybe_command});

        return switch (command) {
            .server => .{ .server = .parse(&iterator) },
            .benchmark => .{ .benchmark = .parse(&iterator) },
            .inspect => fatal("inspect: unimplemented", .{}),
            .version => .version,
            .help => .help,
        };
    }

    pub const usage =
        \\Usage: raptodb [command] [flags]
        \\
        \\Available [command] are 'server', 'benchmark', 'inspect',
        \\                        'version' and 'help'
        \\Each [command] has its own flags as:
        \\
        \\server
        \\  --name <database name>
        \\      Specifies the name of the database.
        \\      *Required
        \\
        \\  --expected-keys <quantity>
        \\      Number of expected keys to exploit memory preallocation.
        \\      Default: 4096.
        \\
        \\  --io-preserved-size <bytes>
        \\      Preserved size for IO serialization buffer.
        \\      Maybe used when clients sends big queries or batches.
        \\      Default: 32768 (32KiB).
        \\  
        \\  --aof
        \\      When this parameter is enabled, writes in AOF
        \\      in <database name>.raptodb file.
        \\      Default: false.
        \\  
        \\  --aof-file <path>
        \\      Specifies the path for persistent storage file.
        \\      The path must exist and be accessible.
        \\      Default: current working directory.
        \\
        \\  --aof-sync-seconds <seconds>
        \\      Specifies how many seconds should pass between
        \\      each save.
        \\      Default: 1 second.
        \\
        \\  --aof-load-until <timestamp>
        \\      Loads AOF file until timestamp is reached.
        \\  
        \\  --address <ip:port>
        \\      Specifies the network address for binding.
        \\      Default: 127.0.0.1:7286
        \\
        \\benchmark
        \\  --address <ip:port>
        \\      Specifies the network address to connect to.
        \\      Default: 127.0.0.1:7286
        \\
        \\  --clients <quantity>
        \\      Number of parallel clients used for the benchmark.
        \\      Default: 1.
        \\
        \\  --batch-size <size>
        \\      Number of operations sent per batch/request.
        \\      Default: 1.
        \\
        \\  --test <command>
        \\      Specifies the command to benchmark.
        \\      Available command are: set, get. More commands coming soon.
        \\      *Required
        \\
        \\  --ops <quantity>
        \\      Total number of operations to run during the benchmark.
        \\      Default: 100000.
        \\
        \\  --dataset-keys <quantity>
        \\      Number of keys used to generate dataset before benchmarking.
        \\      Default: 100000.
        \\
        \\  --warmup-batches <quantity>
        \\      Number of batches run before measurements start.
        \\      Default: 512.
        \\
        \\  --key-size <bytes>
        \\      Size in bytes of each randomic-generated key.
        \\      Default: 3.
        \\
        \\  --value-size <bytes>
        \\      Size in bytes of each randomic-generated value.
        \\      Default: 3.
        \\
    ;
};

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.process.exit(1);
}
