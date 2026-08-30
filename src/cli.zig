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

    server: Server,
    inspect,
    benchmark,

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
            .inspect => fatal("inspect: unimplemented", .{}),
            .benchmark => fatal("benchmark: unimplemented", .{}),
            .version => .version,
            .help => .help,
        };
    }

    pub const usage =
        \\Usage: raptodb [command] [flags]
        \\
        \\Available [command] are 'server', 'inspect', 'benchmark'
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
        \\      Default: 32768 (32KB).
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
        \\      specifies how many seconds should pass between
        \\      each save.
        \\      Default: 1 second.
        \\  
        \\  --address <ip:port>
        \\      Specifies the network address for connection.
        \\      Default: 127.0.0.1:7286
        \\
    ;
};

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.process.exit(1);
}
