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
//! It contains the implementation of logger.

const std = @import("std");

const ctime = @cImport(@cInclude("time.h"));
const signal = @import("signal.zig");

const RaptoConfig = @import("rapto.zig").RaptoConfig;

const server_footer: []const u8 = "Session [SERVER db={s};addr={};pass={s}] Press q: quit, s: save.\n";

/// Level of verbosity when print log,
/// warnings or critical messages.
pub const Level = enum {
    /// Suppresses all messages.
    silent,

    /// Shows only warnings and critical messages.
    warnings,

    /// Shows all messages (logs, warnings, critical).
    noisy,
};

/// Logger with 3 levels of verbosity:
///  - silent: suppresses all messages,
///  - warnings: shows warnings and critical messages,
///  - noisy: shows all messages.
pub const Logger = struct {
    const Self = @This();

    stdout: std.fs.File.Writer = undefined,
    stderr: std.fs.File.Writer  = undefined,

    allocator: std.mem.Allocator  = undefined,

    level: Level = .noisy,

    conf: ?*RaptoConfig = null,

    /// Initializes logger with stdout and stderr streams
    pub fn init(allocator: std.mem.Allocator, level: Level) Self {
        return Self{
            .stdout = std.io.getStdOut().writer(),
            .stderr = std.io.getStdErr().writer(),
            .allocator = allocator,
            .level = level,
        };
    }

    /// Generic log function implementation with footer.
    /// Prints log with date and time.
    pub fn log(self: *Self, logtype: enum { info, warning, critical, critical_msg }, msg: []const u8) void {
        // set prefix with date and name
        var prefix: [27]u8 = undefined;
        _ = std.fmt.bufPrint(&prefix, "{s} [Rapto]", .{getFormattedTime()}) catch unreachable;

        if (self.conf != null) {
            self.stdout.writeAll("\x1b[F") catch unreachable;
            self.stdout.writeAll("\x1b[K") catch unreachable;
        }

        if (logtype == .critical)
            self.stderr.print("\r{s} CRITICAL: {s}\n", .{ prefix, msg }) catch unreachable;

        // by logtype, print info from stdout or warning and critical from stderr
        switch (logtype) {
            .info => self.stdout.print("{s} info: {s}\n", .{ prefix, msg }) catch unreachable,
            .warning => self.stderr.print("{s} warning: {s}\n", .{ prefix, msg }) catch unreachable,
            .critical_msg => self.stderr.print("{s} CRITICAL: {s}\n", .{ prefix, msg }) catch unreachable,
            else => {},
        }

        if (self.conf) |conf| {
            self.stdout.print(server_footer, .{
                conf.name.?,
                conf.addr.?,
                conf.auth orelse "",
            }) catch unreachable;
        }
    }

    /// Prints info message.
    pub fn info(self: *Self, comptime format: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, format, args) catch signal.OOM();
        defer self.allocator.free(msg);

        // print info when log level is noisy
        if (self.level == .noisy)
            self.log(.info, msg);
    }

    /// Prints warning message.
    pub fn warning(self: *Self, comptime format: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, format, args) catch signal.OOM();
        defer self.allocator.free(msg);

        // print info when log level is noisy or warnings
        if (self.level != .silent)
            self.log(.warning, msg);
    }

    /// Prints critical message without terminating.
    pub fn critical_msg(self: *Self, comptime format: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, format, args) catch signal.OOM();
        defer self.allocator.free(msg);

        // print info when log level is noisy or warnings
        if (self.level != .silent)
            self.log(.critical_msg, msg);
    }

    /// Prints critical message and terminate program with exit code 1.
    pub fn critical(self: *Self, comptime format: []const u8, args: anytype) noreturn {
        const msg = std.fmt.allocPrint(self.allocator, format, args) catch signal.OOM();
        defer {
            self.allocator.free(msg);
            defer std.process.exit(1);
        }

        // print info when log level is noisy or warnings
        if (self.level != .silent)
            self.log(.critical, msg);
    }
};

/// Convert timestamp to format date.
pub fn getFormattedTime() [19]u8 {
    const c_time: c_longlong = @intCast(std.time.timestamp());
    const time_info = ctime.localtime(&c_time);

    var buf: [64]u8 = undefined;

    _ = ctime.strftime(&buf[0], buf.len, "%F %T", time_info);

    return buf[0..19].*;
}
