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

/// Client that make query.
client: ?*Client = null,

raw_query: []const u8 = undefined,
command: []const u8 = undefined,
args: []const u8 = undefined,

/// Parses raw query to valid query. It divide command with arguments.
pub fn parseQuery(client: *Client, raw_query: []const u8) error{EmptyQuery}!Self {
    const trimmed = std.mem.trim(u8, raw_query, " ");
    if (trimmed.len == 0) {
        @branchHint(.unlikely);
        return error.EmptyQuery;
    }
    const space_index = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;

    var q = Self{ .client = client };
    q.raw_query = raw_query;
    q.command = utils.upperString(@constCast(trimmed[0..space_index]));
    q.args = if (space_index < trimmed.len) trimmed[space_index + 1 ..] else "";

    return q;
}

/// Resolves query.
/// Returns response text and allocatedFromHeap bool.
pub const ResolveError = error{
    CommandNotFound,
    MissingTokens,
    TypeOverflow,
    KeyNotFound,
    KeyReplacementExist,
    MismatchType,
    SaveFailed,
    InvalidObject,
    InvalidMetadata,
    NoKeysFound,
    UnknownArgument,
    ExcedeedSpaceLimit,
} || signal.SignalError || Storage.PutError;
pub fn resolve(
    self: Self,
    storage: *Storage,
    logger: *log.Logger,
    profiler: *Profiler,
) ResolveError!struct { []const u8, bool } {
    const c = db.Commands.parse(self.command) orelse return error.CommandNotFound;

    switch (c) {
        // commands with string return type
        .PING => return .{ db.PING(), false },

        .GET => {
            @branchHint(.likely);
            return .{ try db.GET(storage, self.args), true };
        },
        .TYPE => return .{ try db.TYPE(storage, self.args), true },
        .CHECK => return .{ db.CHECK(storage, self.args), true },
        .COUNT => return .{ try db.COUNT(storage), true },
        .LIST => return .{ try db.LIST(storage), true },

        .FREQ => return .{ try db.FREQ(storage, self.args), true },
        .LAST => return .{ try db.LAST(storage, self.args), true },
        .IDLE => return .{ try db.IDLE(storage, self.args), true },
        .LEN => return .{ try db.LEN(storage, self.args), true },
        .SIZE => return .{ try db.SIZE(storage, self.args), true },
        .MEM => return .{ try db.MEM(storage.allocator, profiler, self.args), true },
        .DB => return try db.DB(storage, self.args),

        .DUMP => return .{ try db.DUMP(storage, self.args), true },

        // commands with void return type
        .ISET => {
            @branchHint(.likely);
            try db.ISET(storage, self.args);
        },
        .DSET => {
            @branchHint(.likely);
            try db.DSET(storage, self.args);
        },
        .SSET => {
            @branchHint(.likely);
            try db.SSET(storage, self.args);
        },
        .UPDATE => {
            @branchHint(.likely);
            try db.UPDATE(storage, self.args);
        },
        .RENAME => try db.RENAME(storage, self.args),

        .TOUCH => try db.TOUCH(storage, self.args),
        .HEAD => try db.HEAD(storage, self.args),
        .TAIL => try db.TAIL(storage, self.args),
        .SHEAD => try db.SHEAD(storage, self.args),
        .STAIL => try db.STAIL(storage, self.args),
        .SORT => db.SORT(storage),

        .RESTORE => try db.RESTORE(storage, self.args),
        .ERASE => try db.ERASE(storage),
        .DEL => {
            @branchHint(.likely);
            try db.DEL(storage, self.args);
        },
        .SAVE => try db.SAVE(storage, logger),
        .COPY => try db.COPY(storage, self.args),
    }

    return .{ "OK", false };
}

/// Deallocates query.
pub fn free(self: Self, allocator: std.mem.Allocator) void {
    allocator.free(self.raw_query);
}
