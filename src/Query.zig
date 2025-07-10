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
//! It contains the implementation of queries queue management.

const std = @import("std");

const signal = @import("signal.zig");
const db = @import("db.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");

const Profiler = @import("zprof.zig").Profiler;
const Storage = @import("storage.zig").Storage;
const Client = @import("server.zig").Client;

const Self = @This();

/// List of Rapto commands.
/// Sectioned by functionality.
pub const Command = enum(u8) {
    PING,

    SET,
    UPDATE,
    RENAME,

    GET,
    TYPE,
    CHECK,
    COUNT,
    LIST,

    TOUCH,
    HEAD,
    TAIL,
    SHEAD,
    STAIL,
    SORT,

    FREQ,
    LAST,
    IDLE,
    LEN,
    SIZE,
    MEM,
    DB,

    DUMP,
    RESTORE,
    ERASE,
    DEL,
    SAVE,
    COPY,

    DOWN,

    /// Quantity of commands possible.
    const qty: u8 = 29;

    /// Parses text command to enum.
    pub fn parse(noalias command: []const u8) ?Command {
        var i: u8 = 0;
        while (i < qty) : (i += 1) {
            const tag = @as(Command, @enumFromInt(i));
            if (utils.advancedCompare(command, @tagName(tag)))
                return tag;
        }

        return null;
    }
};

/// Client that make query.
client: ?*Client = null,

raw_query: []const u8 = undefined,
command: Command = undefined,
args: []const u8 = undefined,

pub const ParseQueryError = error{ EmptyQuery, CommandNotFound };

/// Parses raw query to valid query. Divides the
/// query in command and arguments, associated to
/// client that make request.
pub fn parseQuery(client: *Client, raw_query: []const u8) ParseQueryError!Self {
    const trimmed = std.mem.trim(u8, raw_query, " ");
    if (trimmed.len == 0) {
        @branchHint(.unlikely);
        return error.EmptyQuery;
    }
    const space_index = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;

    var q = Self{ .client = client };
    q.raw_query = raw_query;
    q.command = Command.parse(trimmed[0..space_index]) orelse return error.CommandNotFound;
    q.args = if (space_index < trimmed.len) trimmed[space_index + 1 ..] else "";

    return q;
}

test "command parsing" {
    try std.testing.expect(Command.parse("GET") == .GET);
    try std.testing.expect(Command.parse("TYPE") == .TYPE);
    try std.testing.expect(Command.parse("COPY") == .COPY);
    try std.testing.expect(Command.parse("STAIL") == .STAIL);

    try std.testing.expect(Command.parse("Save") != .SAVE);
    try std.testing.expect(Command.parse("touch") != .TOUCH);
    try std.testing.expect(Command.parse("") == null);
    try std.testing.expect(Command.parse("notacommand") == null);
}

test "parse query" {
    const q = try parseQuery(undefined, "PING abc def");

    try std.testing.expect(q.command == .PING);
    try std.testing.expectEqualSlices(u8, "abc def", q.args);
    try std.testing.expectEqualSlices(u8, "PING abc def", q.raw_query);
}

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}
