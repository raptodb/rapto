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

test "command parsing" {
    try std.testing.expect(Commands.parse("GET") == .GET);
    try std.testing.expect(Commands.parse("TYPE") == .TYPE);
    try std.testing.expect(Commands.parse("COPY") == .COPY);
    try std.testing.expect(Commands.parse("STAIL") == .STAIL);

    try std.testing.expect(Commands.parse("Save") != .SAVE);
    try std.testing.expect(Commands.parse("touch") != .TOUCH);
    try std.testing.expect(Commands.parse("") == null);
    try std.testing.expect(Commands.parse("notacommand") == null);
}

const Self = @This();

storage: *Storage,

pub fn SET(self: Self, args: []const u8) !void {
    @branchHint(.likely);

    const key, const value = try kvFormat(args);
    const value_type: FieldType = blk: {
        // check if value is string if
        // it is encapsulated with ""
        if (std.mem.startsWith(u8, value, "\"") and std.mem.endsWith(u8, value, "\"")) {
            if (value.len > std.math.maxInt(u32)) {
                @branchHint(.cold);
                return error.TypeOverflow;
            }

            break :blk .string;
        }

        // check if value is decimal if
        // contains a dot
        else if (std.mem.indexOfScalar(u8, value, '.') != null) {
            break :blk .decimal;
        }

        // probably a integer
        break :blk .integer;
    };

    switch (value_type) {
        .integer => {
            const fvalue = std.fmt.parseInt(i64, value, 10) catch return error.MismatchType;
            _ = try self.storage.put(.integer, key, fvalue);
        },
        .decimal => {
            const fvalue = std.fmt.parseFloat(f64, value) catch return error.MismatchType;
            _ = try self.storage.put(.decimal, key, fvalue);
        },
        .string => _ = try self.storage.put(.string, key, value[1 .. value.len - 1]),
    }
}

pub fn UPDATE(self: Self, args: []const u8) !void {
    @branchHint(.likely);

    const key, const string_value = try kvFormat(args);
    const value = std.fmt.parseFloat(f64, string_value) catch return error.MismatchType;

    const obj = self.storage.get(key) orelse return error.KeyNotFound;

    if (obj.field == .string) return error.MismatchType;

    if (@mod(value, 1.0) == 0.0 and obj.field == .integer)
        obj.field.integer +|= @intFromFloat(value)
    else if (obj.field == .decimal)
        obj.field.decimal += value
    else
        return error.MismatchType;

    obj.metadata.update();
}

pub fn RENAME(self: Self, args: []const u8) !void {
    const old_key, const new_key = try kvFormat(args);

    // new key must does not exist
    if (self.storage.search(new_key) != null) return error.KeyReplacementExist;

    if (self.storage.search(old_key)) |i| {
        const obj = &self.storage.store.items[i];

        if (obj.key.len != new_key.len)
            obj.key = try self.storage.allocator.realloc(obj.key, new_key.len);

        @memcpy(obj.key, new_key);
    } else return error.KeyNotFound;
}

pub fn GET(self: Self, key: []const u8) !struct { []const u8, bool } {
    @branchHint(.likely);

    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    obj.metadata.update();

    const value = switch (obj.field) {
        .integer => |value| std.fmt.allocPrint(self.storage.allocator, "{d}", .{value}),
        .decimal => |value| blk: {
            break :blk if (@mod(value, 1.0) == 0.0)
                std.fmt.allocPrint(self.storage.allocator, "{d:.1}", .{value})
            else
                std.fmt.allocPrint(self.storage.allocator, "{d}", .{value});
        },
        // if field is string, encapsulates it with ""
        .string => |value| std.fmt.allocPrint(self.storage.allocator, "\"{s}\"", .{value}),
    };

    return .{ value catch return error.OutOfMemory, true };
}

pub fn TYPE(self: Self, key: []const u8) !struct { []const u8, bool } {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    return .{ @tagName(obj.field), false };
}

pub fn CHECK(self: Self, key: []const u8) struct { []const u8, bool } {
    return .{ if (self.storage.search(key) == null) "0" else "1", false };
}

pub fn COUNT(self: Self) !struct { []const u8, bool } {
    return .{ try std.fmt.allocPrint(self.storage.allocator, "{d}", .{self.storage.store.items.len}), true };
}

pub fn LIST(self: Self) !struct { []const u8, bool } {
    var keys = std.ArrayListUnmanaged([]const u8).initCapacity(self.storage.allocator, 0) catch unreachable;
    defer keys.deinit(self.storage.allocator);

    // in order of priority
    var i: u64 = self.storage.store.items.len;
    while (i > 0) {
        i -= 1;
        try keys.append(self.storage.allocator, self.storage.store.items[i].key);
    }

    return if (keys.items.len == 0)
        error.NoKeysFound
    else
        .{ try std.mem.join(self.storage.allocator, " ", keys.items), false };
}

pub fn TOUCH(self: Self, key: []const u8) !void {
    const i = self.storage.search(key) orelse return error.KeyNotFound;
    self.storage.store.items[i].metadata.update();
}

pub fn HEAD(self: Self, key: []const u8) !void {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    const head = &self.storage.store.items[self.storage.store.items.len - 1];

    std.mem.swap(Object, obj, head);
}

pub fn TAIL(self: Self, key: []const u8) !void {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    const head = &self.storage.store.items[0];

    std.mem.swap(Object, obj, head);
}

pub fn SHEAD(self: Self, key: []const u8) !void {
    const index = self.storage.search(key) orelse return error.KeyNotFound;
    const obj = self.storage.store.orderedRemove(index);

    // move to head
    try self.storage.store.ensureTotalCapacityPrecise(self.storage.allocator, self.storage.store.items.len + 1);
    self.storage.store.insertAssumeCapacity(self.storage.store.items.len, obj);
}

pub fn STAIL(self: Self, key: []const u8) !void {
    const index = self.storage.search(key) orelse return error.KeyNotFound;
    const obj = self.storage.store.orderedRemove(index);

    // move to tail
    try self.storage.store.ensureTotalCapacityPrecise(self.storage.allocator, self.storage.store.items.len + 1);
    self.storage.store.insertAssumeCapacity(0, obj);
}

pub fn SORT(self: Self) void {
    self.storage.prefetch();
}

pub fn FREQ(self: Self, arg: []const u8) !struct { []const u8, bool } {
    var obj: *Object = undefined;

    if (kvFormat(arg)) |args| {
        const key, const string_value = args;

        obj = self.storage.get(key) orelse return error.KeyNotFound;

        const value = std.fmt.parseInt(i64, string_value, 10) catch return error.MismatchType;
        obj.metadata.access_times = value;
    } else |_| obj = self.storage.get(arg) orelse return error.KeyNotFound;

    return .{ try std.fmt.allocPrint(self.storage.allocator, "{d}", .{obj.metadata.access_times}), true };
}

pub fn LAST(self: Self, arg: []const u8) !struct { []const u8, bool } {
    var obj: *Object = undefined;

    if (kvFormat(arg)) |args| {
        const key, const string_value = args;

        obj = self.storage.get(key) orelse return error.KeyNotFound;

        const value = std.fmt.parseInt(i64, string_value, 10) catch return error.MismatchType;
        obj.metadata.last_access = value;
    } else |_| obj = self.storage.get(arg) orelse return error.KeyNotFound;

    return .{ try std.fmt.allocPrint(self.storage.allocator, "{d}", .{obj.metadata.last_access}), true };
}

pub fn IDLE(self: Self, key: []const u8) !struct { []const u8, bool } {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    const idle = std.math.sub(
        i64,
        std.time.microTimestamp(),
        obj.metadata.last_access,
    ) catch return error.InvalidMetadata;

    return .{ try std.fmt.allocPrint(self.storage.allocator, "{d}", .{idle}), true };
}

pub fn LEN(self: Self, key: []const u8) !struct { []const u8, bool } {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    const size = if (obj.field == .string) obj.field.string.len else 8;

    return .{ try std.fmt.allocPrint(self.storage.allocator, "{d}", .{size}), true };
}

pub fn SIZE(self: Self, key: []const u8) !struct { []const u8, bool } {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;

    var size: u64 = 56; // min size for a object
    size += obj.key.len;
    size += if (obj.field == .string) obj.field.string.len else 8;

    return .{ try std.fmt.allocPrint(self.storage.allocator, "{d}", .{size}), true };
}

pub fn MEM(self: Self, allocator: std.mem.Allocator, profiler: *Profiler, arg: []const u8) !struct { []const u8, bool } {
    _ = self;

    const value: u64 =
        if (utils.advancedCompare(arg, "live"))
            profiler.live_bytes
        else if (utils.advancedCompare(arg, "peak"))
            profiler.live_peak
        else if (utils.advancedCompare(arg, "total"))
            profiler.allocated
        else if (utils.advancedCompare(arg, "alloc"))
            profiler.alloc_count
        else if (utils.advancedCompare(arg, "free"))
            profiler.free_count
        else blk: {
            if (utils.advancedCompare(arg, "reset-peak"))
                profiler.live_peak = 0
            else if (utils.advancedCompare(arg, "reset-total"))
                profiler.allocated = 0
            else if (utils.advancedCompare(arg, "reset-count")) {
                profiler.alloc_count = 0;
                profiler.free_count = 0;
            } else return error.UnknownArgument;

            break :blk 0;
        };

    return .{ try std.fmt.allocPrint(allocator, "{d}", .{value}), true };
}

pub fn DB(self: Self, arg: []const u8) !struct { []const u8, bool } {
    return if (utils.advancedCompare(arg, "name"))
        .{ self.storage.conf.name.?, false }
    else if (utils.advancedCompare(arg, "cap"))
        .{ try std.fmt.allocPrint(self.storage.allocator, "{d}", .{self.storage.conf.db_cap.?}), true }
    else if (utils.advancedCompare(arg, "size"))
        .{ try std.fmt.allocPrint(self.storage.allocator, "{d}", .{self.storage.conf.db_cap.? - self.storage.store_cap}), true }
    else
        return error.UnknownArgument;
}

pub fn DUMP(self: Self, key: []const u8) !struct { []const u8, bool } {
    var obj = self.storage.get(key) orelse return error.KeyNotFound;
    obj.metadata.update();
    return .{ try obj.serialize(self.storage.allocator), true };
}

pub noinline fn RESTORE(self: Self, obj: []const u8) !void {
    const d = Object.deserialize(self.storage.allocator, obj) catch return error.InvalidObject;

    const i = switch (d.field) {
        .integer => |value| try self.storage.put(.integer, d.key, value),
        .decimal => |value| try self.storage.put(.decimal, d.key, value),
        .string => |value| try self.storage.put(.string, d.key, value),
    };

    self.storage.store.items[i].metadata = d.metadata;
}

pub noinline fn ERASE(self: Self) !void {
    var i: usize = self.storage.store.items.len;
    while (i > 0) {
        i -= 1;
        try self.storage.removeAtIndex(i);
    }
}

pub fn DEL(self: Self, key: []const u8) !void {
    @branchHint(.likely);

    const index = self.storage.search(key) orelse return error.KeyNotFound;
    try self.storage.removeAtIndex(index);
}

pub noinline fn SAVE(self: Self, logger: *log.Logger) !void {
    snap.snap(self.storage, logger, false) catch return error.SaveFailed;
}

pub fn COPY(self: Self, args: []const u8) !void {
    const key, const dst = try kvFormat(args);
    const rawkey, const heap_allocated = try self.DUMP(key);
    defer if (heap_allocated) self.storage.allocator.free(rawkey);

    var d = Object.deserialize(self.storage.allocator, rawkey) catch return error.InvalidObject;
    d.key = try self.storage.allocator.dupe(u8, dst);

    const i = switch (d.field) {
        .integer => |value| try self.storage.put(.integer, d.key, value),
        .decimal => |value| try self.storage.put(.decimal, d.key, value),
        .string => |value| try self.storage.put(.string, d.key, value),
    };

    self.storage.store.items[i].metadata = d.metadata;
}

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}
