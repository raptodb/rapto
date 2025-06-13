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
//! It contains the implementation of commands.

const std = @import("std");

const snap = @import("snap.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");

const Profiler = @import("zprof.zig").Profiler;
const Storage = @import("storage.zig").Storage;
const Object = @import("object.zig").Object;
const FieldType = @import("object.zig").FieldType;

/// Split a text with space separator.
inline fn kvFormat(args: []const u8) error{MissingTokens}!struct { []const u8, []const u8 } {
    const sep = std.mem.indexOfScalar(u8, args, ' ') orelse return error.MissingTokens;
    return .{ args[0..sep], args[sep + 1 ..] };
}

/// List of Rapto commands.
/// Sectioned by functionality.
pub const Commands = enum(u8) {
    PING,

    ISET,
    DSET,
    SSET,
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

    /// Quantity of commands possible.
    const qty: u8 = 30;

    /// Parses text command to enum.
    pub fn parse(noalias command: []const u8) ?Commands {
        var i: u8 = 0;
        while (i < qty) : (i += 1) {
            const tag = @as(Commands, @enumFromInt(i));
            if (utils.advancedCompare(command, @tagName(tag)))
                return tag;
        }

        return null;
    }
};

pub inline fn PING() []const u8 {
    return "pong";
}

pub fn ISET(storage: *Storage, args: []const u8) !void {
    const key, const value = try kvFormat(args);
    const int_value = std.fmt.parseInt(i64, value, 10) catch return error.MismatchType;

    _ = try storage.put(.integer, key, int_value);
}

pub fn DSET(storage: *Storage, args: []const u8) !void {
    const key, const value = try kvFormat(args);
    const float_value = std.fmt.parseFloat(f64, value) catch return error.MismatchType;

    _ = try storage.put(.decimal, key, float_value);
}

pub fn SSET(storage: *Storage, args: []const u8) !void {
    const key, const string_value = try kvFormat(args);

    // string have a size limit of 2^32 bytes
    if (string_value.len > std.math.maxInt(u32)) {
        @branchHint(.unlikely);
        return error.TypeOverflow;
    }

    _ = try storage.put(.string, key, string_value);
}

pub fn UPDATE(storage: *Storage, args: []const u8) !void {
    const key, const string_value = try kvFormat(args);
    const value = std.fmt.parseFloat(f64, string_value) catch return error.MismatchType;

    const obj = storage.get(key) orelse return error.KeyNotFound;

    if (obj.field == .string) return error.MismatchType;

    if (@mod(value, 1.0) == 0.0 and obj.field == .integer)
        obj.field.integer +|= @intFromFloat(value)
    else if (obj.field == .decimal)
        obj.field.decimal += value
    else
        return error.MismatchType;

    obj.metadata.update();
}

pub fn RENAME(storage: *Storage, args: []const u8) !void {
    const old_key, const new_key = try kvFormat(args);

    // new key must does not exist
    if (storage.search(new_key) != null) return error.KeyReplacementExist;

    if (storage.search(old_key)) |i| {
        const obj = &storage.store.items[i];

        if (obj.key.len != new_key.len)
            obj.key = try storage.allocator.realloc(obj.key, new_key.len);

        @memcpy(obj.key, new_key);
    } else return error.KeyNotFound;
}

pub fn GET(storage: *Storage, key: []const u8) ![]const u8 {
    const obj = storage.get(key) orelse return error.KeyNotFound;
    obj.metadata.update();

    const value = switch (obj.field) {
        .integer => |value| std.fmt.allocPrint(storage.allocator, "{d}", .{value}),
        .decimal => |value| blk: {
            break :blk if (@mod(value, 1.0) == 0.0)
                std.fmt.allocPrint(storage.allocator, "{d:.1}", .{value})
            else
                std.fmt.allocPrint(storage.allocator, "{d}", .{value});
        },
        // if field is string, encapsulates it with ""
        .string => |value| std.fmt.allocPrint(storage.allocator, "\"{s}\"", .{value}),
    };

    return value catch error.OutOfMemory;
}

pub fn TYPE(storage: *Storage, key: []const u8) ![]const u8 {
    const obj = storage.get(key) orelse return error.KeyNotFound;
    return @tagName(obj.field);
}

pub fn CHECK(storage: *Storage, key: []const u8) []const u8 {
    return if (storage.search(key) == null) "0" else "1";
}

pub fn COUNT(storage: *Storage) ![]const u8 {
    return try std.fmt.allocPrint(storage.allocator, "{d}", .{storage.store.items.len});
}

pub fn LIST(storage: *Storage) ![]const u8 {
    var keys = std.ArrayListUnmanaged([]const u8).initCapacity(storage.allocator, 0) catch unreachable;
    defer keys.deinit(storage.allocator);

    // in order of priority
    var i: u64 = storage.store.items.len;
    while (i > 0) {
        i -= 1;
        try keys.append(storage.allocator, storage.store.items[i].key);
    }

    return if (keys.items.len == 0)
        error.NoKeysFound
    else
        try std.mem.join(storage.allocator, " ", keys.items);
}

pub fn TOUCH(storage: *Storage, key: []const u8) !void {
    const i = storage.search(key) orelse return error.KeyNotFound;
    storage.store.items[i].metadata.update();
}

pub fn HEAD(storage: *Storage, key: []const u8) !void {
    const obj = storage.get(key) orelse return error.KeyNotFound;
    const head = &storage.store.items[storage.store.items.len - 1];

    std.mem.swap(Object, obj, head);
}

pub fn TAIL(storage: *Storage, key: []const u8) !void {
    const obj = storage.get(key) orelse return error.KeyNotFound;
    const head = &storage.store.items[0];

    std.mem.swap(Object, obj, head);
}

pub fn SHEAD(storage: *Storage, key: []const u8) !void {
    const index = storage.search(key) orelse return error.KeyNotFound;
    const obj = storage.store.orderedRemove(index);

    // move to head
    try storage.store.ensureTotalCapacityPrecise(storage.allocator, storage.store.items.len + 1);
    storage.store.insertAssumeCapacity(storage.store.items.len, obj);
}

pub fn STAIL(storage: *Storage, key: []const u8) !void {
    const index = storage.search(key) orelse return error.KeyNotFound;
    const obj = storage.store.orderedRemove(index);

    // move to tail
    try storage.store.ensureTotalCapacityPrecise(storage.allocator, storage.store.items.len + 1);
    storage.store.insertAssumeCapacity(0, obj);
}

pub fn SORT(storage: *Storage) void {
    storage.prefetch();
}

pub fn FREQ(storage: *Storage, arg: []const u8) ![]const u8 {
    var obj: *Object = undefined;

    if (kvFormat(arg)) |args| {
        const key, const string_value = args;

        obj = storage.get(key) orelse return error.KeyNotFound;

        const value = std.fmt.parseInt(i64, string_value, 10) catch return error.MismatchType;
        obj.metadata.access_times = value;
    } else |_| obj = storage.get(arg) orelse return error.KeyNotFound;

    return std.fmt.allocPrint(storage.allocator, "{d}", .{obj.metadata.access_times});
}

pub fn LAST(storage: *Storage, arg: []const u8) ![]const u8 {
    var obj: *Object = undefined;

    if (kvFormat(arg)) |args| {
        const key, const string_value = args;

        obj = storage.get(key) orelse return error.KeyNotFound;

        const value = std.fmt.parseInt(i64, string_value, 10) catch return error.MismatchType;
        obj.metadata.last_access = value;
    } else |_| obj = storage.get(arg) orelse return error.KeyNotFound;

    return std.fmt.allocPrint(storage.allocator, "{d}", .{obj.metadata.last_access});
}

pub fn IDLE(storage: *Storage, key: []const u8) ![]const u8 {
    const obj = storage.get(key) orelse return error.KeyNotFound;
    const idle = std.math.sub(
        i64,
        std.time.microTimestamp(),
        obj.metadata.last_access,
    ) catch return error.InvalidMetadata;
    return std.fmt.allocPrint(storage.allocator, "{d}", .{idle});
}

pub fn LEN(storage: *Storage, key: []const u8) ![]const u8 {
    const obj = storage.get(key) orelse return error.KeyNotFound;
    const size = if (obj.field == .string) obj.field.string.len else 8;

    return std.fmt.allocPrint(storage.allocator, "{d}", .{size});
}

pub fn SIZE(storage: *Storage, key: []const u8) ![]const u8 {
    const obj = storage.get(key) orelse return error.KeyNotFound;

    var size: u64 = 56;
    size += obj.key.len;
    size += if (obj.field == .string) obj.field.string.len else 8;

    return std.fmt.allocPrint(storage.allocator, "{d}", .{size});
}

pub fn MEM(allocator: std.mem.Allocator, profiler: *Profiler, lower_arg: []const u8) ![]const u8 {
    const arg = utils.upperString(@constCast(lower_arg));

    const value: u64 =
        if (utils.advancedCompare(arg, "LIVE"))
            profiler.live_bytes
        else if (utils.advancedCompare(arg, "PEAK"))
            profiler.live_peak
        else if (utils.advancedCompare(arg, "TOTAL"))
            profiler.allocated
        else if (utils.advancedCompare(arg, "ALLOC"))
            profiler.alloc_count
        else if (utils.advancedCompare(arg, "FREE"))
            profiler.free_count
        else blk: {
            if (utils.advancedCompare(arg, "RESET-PEAK"))
                profiler.live_peak = 0
            else if (utils.advancedCompare(arg, "RESET-TOTAL"))
                profiler.allocated = 0
            else if (utils.advancedCompare(arg, "RESET-COUNT")) {
                profiler.alloc_count = 0;
                profiler.free_count = 0;
            } else return error.UnknownArgument;

            break :blk 0;
        };

    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

pub fn DB(storage: *Storage, lower_arg: []const u8) !struct { []const u8, bool } {
    const arg = utils.upperString(@constCast(lower_arg));

    return if (utils.advancedCompare(arg, "NAME"))
        .{ storage.conf.name.?, false }
    else if (utils.advancedCompare(arg, "CAP"))
        .{ try std.fmt.allocPrint(storage.allocator, "{d}", .{storage.conf.db_cap.?}), true }
    else if (utils.advancedCompare(arg, "SIZE"))
        .{ try std.fmt.allocPrint(
            storage.allocator,
            "{d}",
            .{storage.conf.db_cap.? - storage.store_cap},
        ), true }
    else
        return error.UnknownArgument;
}

pub fn DUMP(storage: *Storage, key: []const u8) ![]const u8 {
    var obj = storage.get(key) orelse return error.KeyNotFound;
    obj.metadata.update();
    return obj.serialize(storage.allocator);
}

pub noinline fn RESTORE(storage: *Storage, obj: []const u8) !void {
    const d = Object.deserialize(storage.allocator, obj) catch return error.InvalidObject;

    const i = switch (d.field) {
        .integer => |value| try storage.put(.integer, d.key, value),
        .decimal => |value| try storage.put(.decimal, d.key, value),
        .string => |value| try storage.put(.string, d.key, value),
    };

    storage.store.items[i].metadata = d.metadata;
}

pub noinline fn ERASE(storage: *Storage) !void {
    var i: usize = storage.store.items.len;
    while (i > 0) {
        i -= 1;
        try storage.removeAtIndex(i);
    }
}

pub fn DEL(storage: *Storage, key: []const u8) !void {
    const index = storage.search(key) orelse return error.KeyNotFound;
    try storage.removeAtIndex(index);
}

pub noinline fn SAVE(storage: *Storage, logger: *log.Logger) !void {
    snap.snap(storage, logger, false) catch return error.SaveFailed;
}

pub fn COPY(storage: *Storage, args: []const u8) !void {
    const key, const dst = try kvFormat(args);
    const rawkey = try DUMP(storage, key);

    var d = Object.deserialize(storage.allocator, rawkey) catch return error.InvalidObject;
    d.key = try storage.allocator.dupe(u8, dst);

    const i = switch (d.field) {
        .integer => |value| try storage.put(.integer, d.key, value),
        .decimal => |value| try storage.put(.decimal, d.key, value),
        .string => |value| try storage.put(.string, d.key, value),
    };

    storage.store.items[i].metadata = d.metadata;
}
