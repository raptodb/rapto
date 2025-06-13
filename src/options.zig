//! BSD 3-Clause License
//!
//! Copyright (c) raptodb
//! Copyright (c) Andrea Vaccaro
//! All rights reserved.
//!
//! Redistribution and use in source and binary forms, with or without
//! modification, are permitted provided that the following conditions are met:
//!
//! 1. Redistributions of source code must retain the above copyright notice, this
//!    list of conditions and the following disclaimer.
//!
//! 2. Redistributions in binary form must reproduce the above copyright notice,
//!    this list of conditions and the following disclaimer in the documentation
//!    and/or other materials provided with the distribution.
//!
//! 3. Neither the name of the copyright holder nor the names of its
//!    contributors may be used to endorse or promote products derived from
//!    this software without specific prior written permission.
//!
//! THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//! AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//! IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//! DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
//! FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//! DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//! SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//! CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//! OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//! OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//!
//! This file is part of "Rapto".
//! It contains the implementation of cli options.

const std = @import("std");
const builtin = @import("builtin");

const signal = @import("signal.zig");

const RaptoConfig = @import("rapto.zig").RaptoConfig;

/// Errors that can appear when parsing options.
pub const OptionsError = error{
    InvalidOption,
    InvalidValue,
    InvalidMode,
    MissingMode,
    MissingName,
    MissingValue,
    InvalidDirectory,
    IncompleteAddr,
    CacheLarger,
} || signal.SignalError;

// Gets usage text.
pub inline fn usage() []const u8 {
    return 
    \\Usage: raptodb <mode> [options]
    \\
    \\MODES
    \\    server    Launch as server
    \\
    \\COMMON OPTIONS
    \\  --name <database name>
    \\      Specifies the name of the database.
    \\      *Required
    \\  
    \\  --addr <ip:port>
    \\      Specifies the network address for connections.
    \\      For server mode: the address to bind and listen on.
    \\      For client mode: the address to connect to.
    \\      Default: 127.0.0.1 with a random port between 10000-19999.
    \\  
    \\  --db-path <path>
    \\      Specifies the path for database storage file.
    \\      The path must exist and be accessible.
    \\      Default: current working directory.
    \\  
    \\  --verbose <level>
    \\      Sets the verbosity level for logging.
    \\      Values:
    \\          - silent (no output),
    \\          - warnings (only warnings and critical messages),
    \\          - noisy (all messages including informational logs).
    \\      Default: noisy.
    \\
    \\  --save <delay> <count>
    \\      Sets snapshot saving based on 2 variables:
    \\          - delay (how much time must pass in seconds)
    \\          - count (how many times the database must be answer to a query)
    \\      If these 2 variables are true, it goes to save the snapshot.
    \\      If it is not defined, auto-saving is disabled.
    \\      If count is 0, a min of 1 is selected.
    \\  
    \\  --tls
    \\      Enables encrypt server-client traffic with
    \\      Diffie-Hellman handshake. It works as TLS without certificates.
    \\      Enables default port to 8443.
    \\
    \\  --auth <password>
    \\      Protects access to the database with a password.
    \\      If it is activated with the server, authentication is required
    \\      by the client, otherwise if it is activated with the client,
    \\      it will be the password to access it.
    \\  
    \\SERVER-EXCLUSIVE OPTIONS
    \\  --db-size <size>
    \\      Sets the maximum database capacity in bytes.
    \\      This capacity will be applied at disk and RAM.
    \\
    ;
}

/// Parse arguments into RaptoConfig struct.
/// It can return parsing errors.
pub fn parseOptions(allocator: std.mem.Allocator, args: *std.process.ArgIterator) OptionsError!RaptoConfig {
    // skip executable path
    _ = args.skip();

    var opts = RaptoConfig{};

    var value = args.next() orelse return error.MissingMode;

    // first arguments must be mode
    opts.mode = if (std.mem.eql(u8, value, "server"))
        .server
    else
        return error.InvalidMode;

    // check flag with value
    while (args.next()) |flag| {
        // check for flags without values
        if (std.mem.eql(u8, flag, "--tls")) {
            opts.tls = true;
            continue;
        }

        value = args.next() orelse return error.MissingValue;

        // required parameters
        if (std.mem.eql(u8, flag, "--name")) {
            opts.name = try allocator.dupe(u8, value);
        }

        // server exclusive parameters
        else if (std.mem.eql(u8, flag, "--db-size") and opts.mode == .server)
            opts.db_cap = std.fmt.parseInt(u64, value, 10) catch return error.InvalidValue
        else if (std.mem.eql(u8, flag, "--db-dir") and opts.mode == .server) {
            // if directory exist, set to db_path
            if (std.fs.openDirAbsolute(value, .{})) |_|
                opts.db_path = try allocator.dupe(u8, value)
            else |_|
                return error.InvalidDirectory;
        }

        // optional parameters
        else if (std.mem.eql(u8, flag, "--addr")) {
            var addr = std.mem.splitScalar(u8, value, ':');

            // convert ip and port to valid values
            // check if port is valid
            const ip = addr.first();
            const port = std.fmt.parseInt(u16, addr.next() orelse return error.IncompleteAddr, 10) catch return error.InvalidValue;

            // set addr with parsed ipv4
            opts.addr = std.net.Ip4Address.parse(ip, port) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, flag, "--verbose")) {
            opts.verbose = if (std.mem.eql(u8, value, "silent"))
                .silent
            else if (std.mem.eql(u8, value, "warnings"))
                .warnings
            else if (std.mem.eql(u8, value, "noisy"))
                .noisy
            else
                return error.InvalidValue;
        } else if (std.mem.eql(u8, flag, "--save")) {
            // get delay and mod count
            const delay = std.fmt.parseInt(u64, value, 10) catch return error.InvalidValue;
            const count = std.fmt.parseInt(u64, args.next() orelse return error.MissingValue, 10) catch return error.InvalidValue;

            opts.save = .{ .delay = delay, .count = @max(count, 1) };
        } else if (std.mem.eql(u8, flag, "--auth"))
            opts.auth = try allocator.dupe(u8, value)
        else
            return error.InvalidOption;
    }

    // database name is a required parameter.
    // if it is not set return an error
    if (opts.name == null) return error.MissingName;

    // if addr is not set, generate localhost with
    // random port from 10000 to 19999. if TLS is
    // enabled default port is 8443
    if (opts.addr == null) {
        const port: u16 = if (opts.tls) 8443 else std.crypto.random.intRangeAtMost(u16, 10000, 19999);
        opts.addr = std.net.Ip4Address.parse("127.0.0.1", port) catch unreachable;
    }

    // auth can't work without TLS,
    // if TLS is disabled while auth is enabled,
    // enables TLS automatically
    if (!opts.tls and opts.auth != null)
        opts.tls = true;

    // if capacity is null, set to 0
    opts.db_cap = opts.db_cap orelse 0;

    // storage directory is server exclusive
    if (opts.mode == .server) {
        // if database directory is not present, set
        // with current absolute path
        const storage_dir = opts.db_path orelse std.fs.cwd().realpathAlloc(allocator, ".") catch unreachable;
        defer allocator.free(storage_dir);

        // for windows systems, path's backslashes
        // is replaced with slashes, as linux
        if (builtin.os.tag == .windows) {
            for (@constCast(storage_dir)) |*c| {
                if (c.* == '\\') c.* = '/';
            }
        }

        // set database directory with database storage file
        opts.db_path = try std.fmt.allocPrint(allocator, "{s}/{s}.raptodb", .{ storage_dir, opts.name.? });
    }

    return opts;
}
