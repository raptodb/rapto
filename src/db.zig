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
const FieldType = Object.FieldType;

const Self = @This();

storage: *Storage,

/// Puts value on head of storage. This function
/// does not need swapping priority algorithm.
///
/// Arguments must be <key> <value>.
/// The types of values are `integer`, `decimal` and
/// `string`.
/// To set integer write the number as value without dot.
/// To set decimal write the number as value with dot.
/// To set string write the text encapsulated with "".
///
/// Examples:
/// `SET k 1010` for integers.
/// `SET k 50.12` for decimals.
/// `SET k "test"` for strings.
///
/// NOTE: if key exists, overwrites it.
/// Overwriting updates priority and metadata
/// and can change the type of value.
///
/// Complexity O(n)
pub fn SET(self: Self, args: []const u8) !void {
    @branchHint(.likely);

    const key, const value = try utils.kvFormat(args);

    // detects value type from syntax,
    // parses correlated value and put on store
    switch (try utils.valueTypeFromSerialized(value)) {
        .integer => _ = try self.storage.put(.integer, key, try utils.parseIntType(value)),
        .decimal => _ = try self.storage.put(.decimal, key, try utils.parseDecimalType(value)),
        .string => _ = try self.storage.put(.string, key, utils.parseStringType(value)),
    }
}

/// Increments/decrements `integer` or `decimal` value.
/// NOTE: `string` is not acceptable.
///
/// This function can not change type of value.
/// To sum value with inserted value write value with
/// + sign or without sign, to sub, you must write value
/// with - sign.
///
/// Type `integer` can be updated with `integer` or no rem `decimal`.
/// Type `decimal` can be updated with `integer` or `decimal`
/// If type is mismatched returns error.
///
/// Arguments must be <key> <value>.
/// Examples:
/// `UPDATE k 10` (k is integer) if k was 2, now is 12.
/// `UPDATE k 12.33' (k is decimal) if k was 3.2, now is 15.53.
/// `UPDATE k -3` (k is integer) if k is 5, now is 2.
///
/// Updates priority and metadata.
///
/// Complexity O(n)
pub fn UPDATE(self: Self, args: []const u8) !void {
    @branchHint(.likely);

    const key, const string_value = try utils.kvFormat(args);
    const value = try utils.parseDecimalType(string_value);

    const obj = self.storage.get(key) orelse return error.KeyNotFound;

    if (@mod(value, 1.0) == 0.0 and obj.type == .integer)
        obj.field.integer +|= @intFromFloat(value)
    else if (obj.type == .decimal)
        obj.field.decimal += value
    else
        return error.MismatchType;

    obj.metadata.update();
}

/// Renames a key.
///
/// Arguments must be <oldkey> <newkey>.
///
/// Examples:
/// `RENAME okey nkey` okey is renamed in nkey.
///
/// Updates priority and metadata of oldkey.
/// If newkey is found (is an error) priority
/// will be updated.
///
/// Complexity O(n+n)
pub fn RENAME(self: Self, args: []const u8) !void {
    const old_key, const new_key = try utils.kvFormat(args);

    var new_index: ?u64 = null;
    var old_index: ?u64 = null;

    var i: u64 = self.storage.store.items.len;
    while (i > 0) {
        i -= 1;

        const obj = &self.storage.store.items[i];
        if (utils.advancedCompare(obj.getKey(), new_key)) {
            new_index = i;
            if (old_index != null) break;
        } else if (utils.advancedCompare(obj.getKey(), old_key)) {
            old_index = i;
            if (new_index != null) break;
        }
    }

    // new key must does not exist
    if (new_index != null) return error.KeyReplacementExist;

    if (old_index) |index| {
        const obj = &self.storage.store.items[index];

        if (obj.len != new_key.len) {
            const key = try self.storage.allocator.realloc(obj.key[0..obj.len], new_key.len);
            obj.setKey(key.ptr, key.len);
        }

        @memcpy(obj.key, new_key);
        obj.metadata.update();
    } else return error.KeyNotFound;
}

/// Retrieves value from key.
///
/// Arguments must be <key>.
///
/// Examples:
/// `GET k`
/// `GET mykey`
///
/// Value type is detected from syntax:
/// If is `integer` has no dot.
/// If is `decimal` has dot
/// If is `string` is encapsulated with "".
///
/// Updates priority and metadata.
///
/// Complexity O(n)
pub inline fn GET(self: Self, key: []const u8) !struct { []const u8, bool } {
    @branchHint(.likely);

    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    obj.metadata.update();

    if (obj.type == .string) {
        const value = try std.fmt.allocPrint(self.storage.allocator, "\"{s}\"", .{obj.field.string.get()});
        return .{ value, true };
    }

    // preallocated buffer on stack
    // with max size for {i64, f64}
    // converted in u8 array
    var buf: [25]u8 = undefined;
    const slice = switch (obj.type) {
        .integer => std.fmt.bufPrint(&buf, "{d}", .{obj.field.integer}) catch unreachable,
        .decimal => blk: {
            break :blk if (@mod(obj.field.decimal, 1.0) == 0.0)
                std.fmt.bufPrint(&buf, "{d:.1}", .{obj.field.decimal}) catch unreachable
            else
                std.fmt.bufPrint(&buf, "{d}", .{obj.field.decimal}) catch unreachable;
        },

        // string already handled
        else => unreachable,
    };

    return .{ slice, false };
}

/// Returns type of value from key.
///
/// Arguments must be <key>.
///
/// Examples:
/// `TYPE k`
/// `TYPE mykey`
///
/// Returns `integer`, `decimal` or `string`.
///
/// Updates priority.
///
/// Complexity O(n)
pub inline fn TYPE(self: Self, key: []const u8) !struct { []const u8, bool } {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    return .{ @tagName(obj.type), false };
}

/// Checks if key exists.
///
/// Arguments must be <key>.
///
/// Examples:
/// `CHECK k`
/// `CHECK mykey`
///
/// Returns `0` if key not exists,
/// else returns `1` if key exists.
///
/// Updates priority.
///
/// Complexity O(n)
pub inline fn CHECK(self: Self, key: []const u8) struct { []const u8, bool } {
    return .{ if (self.storage.search(key) == null) "0" else "1", false };
}

/// Returns the quantity of keys
/// stored in the database.
///
/// This function has no arguments.
///
/// Complexity O(1)
pub inline fn COUNT(self: Self) !struct { []const u8, bool } {
    // use preallocated buffer on stack
    var buf: [20]u8 = undefined;
    return .{ std.fmt.bufPrint(&buf, "{d}", .{self.storage.store.items.len}) catch unreachable, false };
}

/// Returns list of keys stored
/// in the database.
///
/// This function has no arguments.
///
/// Complexity O(n)
pub fn LIST(self: Self) !struct { []const u8, bool } {
    const len = self.storage.store.items.len;
    if (len == 0) return error.NoKeysFound;

    var keys = try std.ArrayList([]const u8).initCapacity(self.storage.allocator, len);
    defer keys.deinit(self.storage.allocator);

    // in order of priority
    var i: u64 = len;
    while (i > 0) {
        i -= 1;
        keys.appendAssumeCapacity(self.storage.store.items[i].getKey());
    }

    return .{ try std.mem.join(self.storage.allocator, " ", keys.items), true };
}

/// Updates priority and metadata of key.
///
/// Arguments must be <key>.
///
/// Examples:
/// `TOUCH k`
/// `TOUCH mykey`
///
/// Complexity O(n)
pub inline fn TOUCH(self: Self, key: []const u8) !void {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    obj.metadata.update();
}

/// Updates priority moving key
/// to head with unordered swapping.
///
/// Arguments must be <key>.
///
/// Examples:
/// `HEAD k`
/// `HEAD mykey`
///
/// Complexity O(n)
pub fn HEAD(self: Self, key: []const u8) !void {
    const last_index = self.storage.store.items.len - 1;

    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    const head = &self.storage.store.items[last_index];

    std.mem.swap(Object, obj, head);
}

/// Updates priority moving key
/// to tail with unordered swapping.
///
/// Arguments must be <key>.
///
/// Examples:
/// `TAIL k`
/// `TAIL mykey`
///
/// Complexity O(n)
pub fn TAIL(self: Self, key: []const u8) !void {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    const head = &self.storage.store.items[0];

    std.mem.swap(Object, obj, head);
}

/// Updates priority moving key
/// to head with ordered method.
///
/// Arguments must be <key>.
///
/// Examples:
/// `SHEAD k`
/// `SHEAD mykey`
///
/// Complexity O(n)
pub fn SHEAD(self: Self, key: []const u8) !void {
    const index = self.storage.search(key) orelse return error.KeyNotFound;
    const obj = self.storage.store.orderedRemove(index);

    // move to head
    self.storage.store.insertAssumeCapacity(self.storage.store.items.len, obj);
}

/// Updates priority moving key
/// to tail with ordered method.
///
/// Arguments must be <key>.
///
/// Examples:
/// `STAIL k`
/// `STAIL mykey`
///
/// Complexity O(n)
pub fn STAIL(self: Self, key: []const u8) !void {
    const index = self.storage.search(key) orelse return error.KeyNotFound;
    const obj = self.storage.store.orderedRemove(index);

    // move to tail
    self.storage.store.insertAssumeCapacity(0, obj);
}

/// Sorts keys for last access
/// with insertion sorting.
///
/// This function has no arguments.
///
/// Complexity O(n²)
pub inline fn SORT(self: Self) void {
    self.storage.prefetch();
}

/// Gets or sets access times of a key.
///
/// If argument over key is not provided
/// returns FREQ of key (access times).
///
/// Example:
/// `FREQ key`
///
/// If argument <freq> over key is provided
/// sets key's FREQ with inserted value.
///
/// Example:
/// `FREQ key 40` access times of key is set to 40.
///
/// Updates priority.
///
/// Complexity O(n)
pub inline fn FREQ(self: Self, arg: []const u8) !struct { []const u8, bool } {
    var obj: *Object = undefined;

    // is freq is to set
    if (utils.kvFormat(arg)) |args| {
        const key, const string_value = args;

        obj = self.storage.get(key) orelse return error.KeyNotFound;
        obj.metadata.access_times = try utils.parseUintType(string_value);
    }
    // if freq is to get
    else |_| obj = self.storage.get(arg) orelse return error.KeyNotFound;

    // use preallocated buffer on stack
    var buf: [20]u8 = undefined;
    return .{ std.fmt.bufPrint(&buf, "{d}", .{obj.metadata.access_times}) catch unreachable, false };
}

/// Gets or sets last access of a key.
///
/// If argument over key is not provided
/// returns timestamp of last access
/// of key.
///
/// Example:
/// `LAST key`
///
/// If argument <timestamp> over key is provided
/// sets key's FREQ with inserted value as timestamp.
///
/// Example:
/// `LAST key 1752500000`
///
/// Updates priority.
///
/// Complexity O(n)
pub inline fn LAST(self: Self, arg: []const u8) !struct { []const u8, bool } {
    var obj: *Object = undefined;

    // if last access is to set
    if (utils.kvFormat(arg)) |args| {
        const key, const string_value = args;

        obj = self.storage.get(key) orelse return error.KeyNotFound;
        obj.metadata.last_access = try utils.parseIntType(string_value);
    }
    // if last access is to get
    else |_| obj = self.storage.get(arg) orelse return error.KeyNotFound;

    // use preallocated buffer on stack
    var buf: [20]u8 = undefined;
    return .{ std.fmt.bufPrint(&buf, "{d}", .{obj.metadata.last_access}) catch unreachable, false };
}

/// Returns the latency between
/// now and the last access.
///
/// Arguments must be <key>.
///
/// Examples:
/// `IDLE k`
/// `IDLE mykey`
///
/// Updates priority.
///
/// Complexity O(n)
pub inline fn IDLE(self: Self, key: []const u8) !struct { []const u8, bool } {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    const idle = std.math.sub(
        i64,
        std.time.microTimestamp(),
        obj.metadata.last_access,
    ) catch return error.InvalidMetadata;

    // use preallocated buffer on stack
    var buf: [20]u8 = undefined;
    return .{ std.fmt.bufPrint(&buf, "{d}", .{idle}) catch unreachable, false };
}

/// Returns how much memory
/// in bytes occupies field.
///
/// If type of field is `integer`
/// or `decimal` returns always 8.
///
/// Useful for get th length of `string`.
///
/// Arguments must be <key>.
///
/// Examples:
/// `LEN k`
/// `LEN mykey`
///
/// Updates priority.
///
/// Complexity O(n)
pub inline fn LEN(self: Self, key: []const u8) !struct { []const u8, bool } {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;
    const size = if (obj.type == .string) obj.field.string.len() else 8;

    // use preallocated buffer on stack
    var buf: [20]u8 = undefined;
    return .{ std.fmt.bufPrint(&buf, "{d}", .{size}) catch unreachable, false };
}

/// Returns how much memory
/// in bytes occupies object in RAM.
///
/// Occupied memory is composed
/// by 56 (min space of struct)
/// + key size + field size
///
/// Arguments must be <key>.
///
/// Examples:
/// `SIZE k`
/// `SIZE mykey`
///
/// Updates priority.
///
/// Complexity O(n)
pub inline fn SIZE(self: Self, key: []const u8) !struct { []const u8, bool } {
    const obj = self.storage.get(key) orelse return error.KeyNotFound;

    // use preallocated buffer on stack
    var buf: [20]u8 = undefined;
    return .{ std.fmt.bufPrint(&buf, "{d}", .{obj.getSize()}) catch unreachable, false };
}

/// Gets or sets memory profiling
/// info of heap.
///
/// Arguments must be <action>.
///
/// Actions (get):
/// live: gets live bytes.
/// peak: gets peak of bytes.
/// total: gets total bytes allocated.
/// alloc: gets alloc count.
/// free: gets dealloc count.
///
/// Actions (set):
/// reset-peak: reset peak bytes to 0.
/// reset-total: reset total bytes allocated to 0.
/// reset-count: reset count of allocations.
/// and deallocations to 0.
///
/// Complexity O(1)
pub inline fn MEM(self: Self, profiler: *Profiler, arg: []const u8) !struct { []const u8, bool } {
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
    return .{ std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable, false };
}

/// Gets database infos.
///
/// Arguments must be <action>.
///
/// Actions:
/// name: gets name of database.
/// size: gets how much memory keys occupy.
/// cap: gets the capacity of database,
/// if capacity is not set, returns ALLRAM.
///
/// Complexity O(n)
pub fn DB(self: Self, arg: []const u8) !struct { []const u8, bool } {
    return if (utils.advancedCompare(arg, "name"))
        .{ self.storage.conf.name.?, false }
    else
    // block for preallocated
    // buffer on stack
    blk: {
        // use preallocated buffer on stack
        var buf: [20]u8 = undefined;

        break :blk if (utils.advancedCompare(arg, "cap"))
            if (self.storage.conf.db_size) |size|
                .{ std.fmt.bufPrint(&buf, "{d}", .{size}) catch unreachable, false }
            else
                .{ "ALLRAM", false }
        else if (utils.advancedCompare(arg, "size"))
            .{ std.fmt.bufPrint(
                &buf,
                "{d}",
                .{if (self.storage.conf.db_size) |size| size - self.storage.store_cap else std.math.maxInt(u64) - self.storage.store_cap},
            ) catch unreachable, false }
        else
            error.UnknownArgument;
    };
}

/// Returns serialized key from
/// key in bytes format.
///
/// Arguments must be <key>.
///
/// Updates priority and metadata.
///
/// Complexity O(n)
pub fn DUMP(self: Self, key: []const u8) !struct { []const u8, bool } {
    var obj = self.storage.get(key) orelse return error.KeyNotFound;
    obj.metadata.update();
    return .{ try obj.serialize(self.storage.allocator), true };
}

/// Puts key into database from
/// serialized key.
///
/// Arguments must be <serialized>.
///
/// NOTE: if key exists, overwrites it.
/// Overwriting updates priority and metadata
/// and can change the type of value.
///
/// Complexity O(n)
pub fn RESTORE(self: Self, obj: []const u8) !void {
    const d = try Object.deserialize(self.storage.allocator, obj);

    const i = switch (d.type) {
        .integer => try self.storage.put(.integer, d.getKey(), d.field.integer),
        .decimal => try self.storage.put(.decimal, d.getKey(), d.field.decimal),
        .string => try self.storage.put(.string, d.getKey(), d.field.string.get()),
    };

    self.storage.store.items[i].metadata = d.metadata;
}

/// Removes all keys from database.
///
/// This function has no arguments.
///
/// Complexity O(n)
pub fn ERASE(self: Self) !void {
    var i: u64 = self.storage.store.items.len;
    while (i > 0) {
        i -= 1;
        try self.storage.removeAtIndex(i);
    }
}

/// Removes key from database.
///
/// Arguments must be <key>.
///
/// Examples:
/// `DEL k`
/// `DEL mykey`
///
/// Complexity O(n)
pub inline fn DEL(self: Self, key: []const u8) !void {
    @branchHint(.likely);

    const index = self.storage.search(key) orelse return error.KeyNotFound;
    try self.storage.removeAtIndex(index);
}

/// Saves a snapshot of database
/// in persistent file.
///
/// This function has no arguments.
///
/// Complexity O(n)
pub inline fn SAVE(self: Self, logger: *log.Logger) !void {
    try snap.snap(self.storage, logger, false);
}

/// Copies key to another key.
///
/// Arguments must be <srckey> and <dstkey>.
///
/// NOTE: if dst key exist, overwrites it.
///
/// Examples:
/// `COPY key key1`
///
/// Complexity O(n+n)
pub fn COPY(self: Self, args: []const u8) !void {
    const key, const dst = try utils.kvFormat(args);
    const rawkey, const heap_allocated = try self.DUMP(key);
    defer if (heap_allocated) self.storage.allocator.free(rawkey);

    var d = try Object.deserialize(self.storage.allocator, rawkey);
    {
        const dup_key = try self.storage.allocator.dupe(u8, dst);
        d.setKey(dup_key.ptr, dup_key.len);
    }

    const i = switch (d.type) {
        .integer => try self.storage.put(.integer, d.getKey(), d.field.integer),
        .decimal => try self.storage.put(.decimal, d.getKey(), d.field.decimal),
        .string => try self.storage.put(.string, d.getKey(), d.field.string.get()),
    };

    self.storage.store.items[i].metadata = d.metadata;
}

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}
