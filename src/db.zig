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

const Self = @This();

storage: *Storage,

pub noinline fn SET(self: Self, args: []const u8) !void {
    @branchHint(.likely);

    const key, const value = try utils.kvFormat(args);

    switch (try utils.valueTypeFromSerialized(value)) {
        .integer => _ = try self.storage.put(.integer, key, try utils.parseIntegerType(value)),
        .decimal => _ = try self.storage.put(.decimal, key, try utils.parseDecimalType(value)),
        .string => _ = try self.storage.put(.string, key, utils.parseStringType(value)),
    }
}

pub noinline fn UPDATE(self: Self, args: []const u8) !void {
    @branchHint(.likely);

    const key, const string_value = try utils.kvFormat(args);
    const value = try utils.parseDecimalType(string_value);

    const obj = self.storage.get(key) orelse return error.KeyNotFound;

    if (@mod(value, 1.0) == 0.0 and obj.field == .integer)
        obj.field.integer +|= @intFromFloat(value)
    else if (obj.field == .decimal)
        obj.field.decimal += value
    else
        return error.MismatchType;

    obj.metadata.update();
}

pub noinline fn RENAME(self: Self, args: []const u8) !void {
    const old_key, const new_key = try utils.kvFormat(args);

    // new key must does not exist
    if (self.storage.search(new_key) != null) return error.KeyReplacementExist;

    if (self.storage.search(old_key)) |i| {
        const obj = &self.storage.store.items[i];

        if (obj.key.len != new_key.len)
            obj.key = try self.storage.allocator.realloc(obj.key, new_key.len);

        @memcpy(obj.key, new_key);
    } else return error.KeyNotFound;
}

pub noinline fn GET(self: Self, key: []const u8) !struct { []const u8, bool } {
    @branchHint(.likely);

    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    obj.metadata.update();

    if (obj.field == .string) {
        const value = std.fmt.allocPrint(self.storage.allocator, "\"{s}\"", .{obj.field.string});
        return .{ value catch return error.OutOfMemory, true };
    }

    // preallocated buffer on stack
    // with max size for {i64, f64}
    // converted in u8 array
    var buf: [25]u8 = undefined;
    const slice = switch (obj.field) {
        .integer => |value| std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable,
        .decimal => |value| blk: {
            break :blk if (@mod(value, 1.0) == 0.0)
                std.fmt.bufPrint(&buf, "{d:.1}", .{value}) catch unreachable
            else
                std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        },

        // string already handled
        else => unreachable,
    };

    return .{ slice, false };
}

pub inline fn TYPE(self: Self, key: []const u8) !struct { []const u8, bool } {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    return .{ @tagName(obj.field), false };
}

pub inline fn CHECK(self: Self, key: []const u8) struct { []const u8, bool } {
    return .{ if (self.storage.search(key) == null) "0" else "1", false };
}

pub inline fn COUNT(self: Self) !struct { []const u8, bool } {
    // use preallocated buffer on stack
    var buf: [20]u8 = undefined;
    return .{ std.fmt.bufPrint(&buf, "{d}", .{self.storage.store.items.len}) catch unreachable, true };
}

pub noinline fn LIST(self: Self) !struct { []const u8, bool } {
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

pub inline fn TOUCH(self: Self, key: []const u8) !void {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    obj.metadata.update();
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

pub inline fn SORT(self: Self) void {
    self.storage.prefetch();
}

pub noinline fn FREQ(self: Self, arg: []const u8) !struct { []const u8, bool } {
    var obj: *Object = undefined;

    // is freq is to set
    if (utils.kvFormat(arg)) |args| {
        const key, const string_value = args;

        obj = self.storage.get(key) orelse return error.KeyNotFound;
        obj.metadata.access_times = try utils.parseIntegerType(string_value);
    }
    // if freq is to get
    else |_| obj = self.storage.get(arg) orelse return error.KeyNotFound;

    // use preallocated buffer on stack
    var buf: [20]u8 = undefined;
    return .{ std.fmt.bufPrint(&buf, "{d}", .{obj.metadata.access_times}) catch unreachable, true };
}

pub noinline fn LAST(self: Self, arg: []const u8) !struct { []const u8, bool } {
    var obj: *Object = undefined;

    // if last access is to set
    if (utils.kvFormat(arg)) |args| {
        const key, const string_value = args;

        obj = self.storage.get(key) orelse return error.KeyNotFound;
        obj.metadata.last_access = try utils.parseIntegerType(string_value);
    }
    // if last access is to get
    else |_| obj = self.storage.get(arg) orelse return error.KeyNotFound;

    // use preallocated buffer on stack
    var buf: [20]u8 = undefined;
    return .{ std.fmt.bufPrint(&buf, "{d}", .{obj.metadata.last_access}) catch unreachable, true };
}

pub inline fn IDLE(self: Self, key: []const u8) !struct { []const u8, bool } {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    const idle = std.math.sub(
        i64,
        std.time.microTimestamp(),
        obj.metadata.last_access,
    ) catch return error.InvalidMetadata;

    // use preallocated buffer on stack
    var buf: [20]u8 = undefined;
    return .{ std.fmt.bufPrint(&buf, "{d}", .{idle}) catch unreachable, true };
}

pub inline fn LEN(self: Self, key: []const u8) !struct { []const u8, bool } {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    const size = if (obj.field == .string) obj.field.string.len else 8;

    // use preallocated buffer on stack
    var buf: [20]u8 = undefined;
    return .{ std.fmt.bufPrint(&buf, "{d}", .{size}) catch unreachable, true };
}

pub inline fn SIZE(self: Self, key: []const u8) !struct { []const u8, bool } {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;

    var size: u64 = 56; // min size for a object
    size += obj.key.len;
    size += if (obj.field == .string) obj.field.string.len else 8;

    // use preallocated buffer on stack
    var buf: [20]u8 = undefined;
    return .{ std.fmt.bufPrint(&buf, "{d}", .{size}) catch unreachable, true };
}

pub noinline fn MEM(self: Self, profiler: *Profiler, arg: []const u8) !struct { []const u8, bool } {
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

    // use preallocated buffer on stack
    var buf: [20]u8 = undefined;
    return .{ std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable, true };
}

pub noinline fn DB(self: Self, arg: []const u8) !struct { []const u8, bool } {
    return if (utils.advancedCompare(arg, "name")) blk: {
        break :blk .{ self.storage.conf.name.?, false };
    }
    // block for preallocated
    // buffer on stack
    else blk: {
        // use preallocated buffer on stack
        var buf: [20]u8 = undefined;

        break :blk if (utils.advancedCompare(arg, "cap"))
            .{ std.fmt.bufPrint(&buf, "{d}", .{self.storage.conf.db_cap.?}) catch unreachable, true }
        else if (utils.advancedCompare(arg, "size"))
            .{ std.fmt.bufPrint(&buf, "{d}", .{self.storage.conf.db_cap.? - self.storage.store_cap}) catch unreachable, true }
        else
            error.UnknownArgument;
    };
}

pub noinline fn DUMP(self: Self, key: []const u8) !struct { []const u8, bool } {
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

pub inline fn DEL(self: Self, key: []const u8) !void {
    @branchHint(.likely);

    const index = self.storage.search(key) orelse return error.KeyNotFound;
    try self.storage.removeAtIndex(index);
}

pub noinline fn SAVE(self: Self, logger: *log.Logger) !void {
    snap.snap(self.storage, logger, false) catch return error.SaveFailed;
}

pub noinline fn COPY(self: Self, args: []const u8) !void {
    const key, const dst = try utils.kvFormat(args);
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
