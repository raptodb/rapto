//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of query executor.

const std = @import("std");
const frames = @import("frames.zig");
const glob = @import("glob.zig");
const reply = @import("reply.zig");
const value = @import("value.zig");
const assert = std.debug.assert;

const Memory = @import("Memory.zig");
const Query = @import("Query.zig");
const Flags = Query.Flags;

/// The only errors that can be returned to execute function.
/// Others errors must be written on frames.
pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error;
pub const ExecuteError = std.mem.Allocator.Error || error{Shutdown};

pub const Quota = struct {
    count: u64 = 0,
    quota: u64,

    pub fn init(quota: u64) Quota {
        return .{ .quota = quota };
    }

    pub fn exceeded(self: Quota) bool {
        return self.count >= self.quota;
    }

    pub fn advance(self: *Quota) void {
        @setRuntimeSafety(false);
        // Too impossible overflow.
        assert(self.count != std.math.maxInt(u64));
        self.count += 1;
    }

    pub fn remaining(self: Quota) u64 {
        return self.quota -| self.count;
    }

    pub fn reset(self: *Quota) void {
        self.count = 0;
    }
};

const Context = struct {
    allocator: std.mem.Allocator,
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
};

/// Executes query on this configuration. Fatal errors will be returned
/// directly, other errors will be written on frames directly.
/// Writer is assumed to be derived from std.Io.Writer.Allocating.
pub fn execute(
    allocator: std.mem.Allocator,
    memory: *Memory, // Storage of state
    writer: *std.Io.Writer,
    query: *const Query, // Input
) ExecuteError!void {
    const HandlerType = *const fn (*const Context) Error!void;
    // Handler with the same name as the query command. The implementation of
    // each handler should be independent and distinct from the others, with
    // possible code and logic duplication by design.
    // This makes it explicit that each command has its own path flow, which can be
    // highly optimized according to the type of operation.
    const handler: HandlerType = switch (query.command) {
        .down => return error.Shutdown,
        inline else => |cmd| @field(@This(), @tagName(cmd)),
    };

    const ctx: Context = .{
        .allocator = allocator,
        .memory = memory,
        .writer = writer,
        .query = query,
    };

    handler(&ctx) catch |err| {
        @branchHint(.cold);
        return switch (err) {
            error.OutOfMemory,
            error.WriteFailed,
            => error.OutOfMemory,
        };
    };
}

fn ping(ctx: *const Context) Error!void {
    const integer: value.Union = .{ .integer = .from(1) };
    try reply.writeValue(ctx.writer, integer);
}

fn get(ctx: *const Context) Error!void {
    return writeOrThrowForEachKey(ctx, getOne);
}

fn getOne(ctx: *const Context, key: []const u8) !void {
    const ref = memoryGet(ctx, key) orelse return error.KeyNotFound;
    return writeValue(ctx, ref.value);
}

fn get_list(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, getListOne);
}

fn getListOne(ctx: *const Context) !void {
    const limit: Quota = .init(ctx.query.flags.limit.get());
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = memoryGet(ctx, key) orelse return error.KeyNotFound;
    if (ref.value != .list) return error.MismatchType;

    const list = ref.value.list;
    const from, const to = try nextRange(&args, list.count());
    const range = list.getRange(from, @min(to - from + 1, limit.remaining()));
    try reply.writeValue(ctx.writer, .{ .list = range });
}

fn del(ctx: *const Context) Error!void {
    var args = ctx.query.args.iterator();

    if (ctx.query.flags.get.get()) {
        return writeOrThrowForEachKey(ctx, getDelOne);
    }

    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var total_deleted: i64 = 0;
    while (args.next()) |key| {
        const ref = memoryGet(ctx, key) orelse continue;
        if (!assume_lock_ownership and ref.metadata.locked) continue;

        ctx.memory.remove(ctx.allocator, ref);
        total_deleted += 1;
    }

    const integer: value.Union = .{ .integer = .from(total_deleted) };
    try reply.writeValue(ctx.writer, integer);
}

fn getDelOne(ctx: *const Context, key: []const u8) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    const ref = memoryGet(ctx, key) orelse return error.KeyNotFound;
    if (!assume_lock_ownership and ref.metadata.locked) return error.Locked;

    try writeValue(ctx, ref.value);
    ctx.memory.remove(ctx.allocator, ref);
}

fn del_patterns(ctx: *const Context) Error!void {
    const cursor = ctx.query.flags.cursor.get();
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var limit: Quota = .init(ctx.query.flags.limit.get());

    const total_deleted: i64 = blk: {
        // true when patterns contains "*"
        var has_any_pattern: bool = false;
        var args = ctx.query.args.iterator();
        while (args.next()) |pattern| {
            if (glob.classify(pattern) != .any) continue;

            const total_keys = ctx.memory.count();
            if (cursor != 0 or !assume_lock_ownership or total_keys > limit.remaining()) {
                // We have to count/check keys one by one iterating.
                // We cant remove keys that are locked, before cursor
                // or that exceeds limit. This is an hint to avoid
                // matching withall available patterns.
                has_any_pattern = true;
                break;
            }
            // Assuming limit is greater than number of keys, if between
            // patterns there is any pattern `*` we can exploit fast
            // path and remove all keys from Memory.
            // Deleted keys are equal to previous live keys.
            ctx.memory.removeAll(ctx.allocator);
            break :blk @intCast(total_keys);
        }

        var deleted: i64 = 0;
        var iterator = ctx.memory.iterator();
        // Starts from last cursor.
        iterator.skip(cursor);
        while (iterator.next()) |entry| {
            if (limit.exceeded()) break;
            defer limit.advance();
            const key, const ref = .{ entry.key, entry.ref };

            if (!assume_lock_ownership and ref.metadata.locked) continue;

            var matches: bool = has_any_pattern;
            // If any pattern `*` is not detected, we should see
            // if there is a matching pattern with key.
            if (!matches) {
                // To avoid allocations we should
                // iterate patterns for each key.
                args.reset();
                while (args.next()) |pattern| {
                    if (glob.match(pattern, key)) {
                        // We found a matching pattern!
                        matches = true;
                        break;
                    }
                }
            }

            // Removes the key if any of selected patterns matches.
            if (matches) {
                ctx.memory.remove(ctx.allocator, ref);
                deleted += 1;
            }
        }

        break :blk deleted;
    };

    const integer: value.Union = .{ .integer = .from(total_deleted) };
    try reply.writeValue(ctx.writer, integer);
}

fn del_list(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, delListOne);
}

fn delListOne(ctx: *const Context) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    const limit: Quota = .init(ctx.query.flags.limit.get());
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = memoryGet(ctx, key) orelse return error.KeyNotFound;
    if (!assume_lock_ownership and ref.metadata.locked) return error.Locked;
    if (ref.value != .list) return error.MismatchType;

    const list = ref.value.list;
    const from, const to = try nextRange(&args, list.count());
    const removed = list.getRange(from, @min(to - from + 1, limit.remaining()));

    if (ctx.query.flags.get.get()) {
        try reply.writeValue(ctx.writer, .{ .list = removed });
    } else {
        const integer: value.Union = .{ .integer = .from(@intCast(removed.count())) };
        try reply.writeValue(ctx.writer, integer);
    }

    var allocating: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer allocating.deinit();
    try list.removeRangeToWriter(&allocating.writer, from, removed.count());
    try memoryPut(ctx, key, .{ .list = .fromOwnedSlice(allocating.written()) });
}

fn count_patterns(ctx: *const Context) Error!void {
    const cursor = ctx.query.flags.cursor.get();
    var limit: Quota = .init(ctx.query.flags.limit.get());

    const key_count: i64 = blk: {
        var args = ctx.query.args.iterator();
        while (args.next()) |pattern| {
            if (glob.classify(pattern) != .any) continue;

            const total_keys: i64 = @intCast(
                // Asserting that keys before cursor
                // will not counted.
                ctx.memory.count() -| cursor,
            );
            // With minimus we follow the same behaviour
            // if we had done iterations one by one to
            // check the pattern.
            // Total keys will always be within limit.
            break :blk @min(total_keys, limit.remaining());
        }

        var counted: i64 = 0;
        var iterator = ctx.memory.iterator();
        // Starts from last cursor.
        iterator.skip(cursor);
        while (iterator.next()) |entry| {
            if (limit.exceeded()) break;
            defer limit.advance();

            var matches: bool = false;
            // To avoid allocations we should
            // iterate patterns for each key.
            args.reset();
            while (args.next()) |pattern| {
                if (glob.match(pattern, entry.key)) {
                    // We found a matching pattern!
                    matches = true;
                    break;
                }
            }

            if (matches) counted += 1;
        }

        break :blk counted;
    };

    const integer: value.Union = .{ .integer = .from(key_count) };
    try reply.writeValue(ctx.writer, integer);
}

fn count_list(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, countListOne);
}

fn countListOne(ctx: *const Context) !void {
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = memoryGet(ctx, key) orelse return error.KeyNotFound;
    if (ref.value != .list) return error.MismatchType;

    // This cast is safe because a list that is too large is impossible.
    const list_count: i64 = @intCast(ref.value.list.count());
    const integer: value.Union = .{ .integer = .from(list_count) };
    try reply.writeValue(ctx.writer, integer);
}

fn exists(ctx: *const Context) Error!void {
    return writeOrThrowForEachKey(ctx, existsOne);
}

fn existsOne(ctx: *const Context, key: []const u8) !void {
    const key_exists = memoryGet(ctx, key) != null;
    const integer: value.Union = .{ .integer = .from(@intFromBool(key_exists)) };
    try reply.writeValue(ctx.writer, integer);
}

fn set(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, setOne);
}

fn setOne(ctx: *const Context) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const serialized = args.next() orelse return error.MissingTokens;
    const val: value.Union = try .deserialize(serialized);
    if (val == .list) return error.MismatchType;

    if (memoryGet(ctx, key)) |ref| {
        if (!assume_lock_ownership and ref.metadata.locked) return error.Locked;

        if (ctx.query.flags.get.get()) {
            try writeValue(ctx, ref.value);
        }

        if (ctx.query.flags.if_not_exists.get()) return error.KeyAlreadyExists;
    }

    _ = try memoryPut(ctx, key, val);
}

fn append_list(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, appendListOne);
}

fn appendListOne(ctx: *const Context) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const serialized = args.next() orelse return error.MissingTokens;
    const val: value.Union = try .deserialize(serialized);
    if (val == .list) return error.MismatchType;

    const list: value.List = blk: {
        const ref = memoryGet(ctx, key) orelse break :blk .empty;
        if (!assume_lock_ownership and ref.metadata.locked) return error.Locked;
        if (ref.value != .list) return error.MismatchType;
        break :blk ref.value.list;
    };
    const count = list.count();

    var allocating: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer allocating.deinit();
    try list.appendToWriter(&allocating.writer, val);
    try memoryPut(ctx, key, .{ .list = .fromOwnedSlice(allocating.written()) });

    const integer: value.Union = .{ .integer = .from(@intCast(count + 1)) };
    try reply.writeValue(ctx.writer, integer);
}

fn append_string(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, appendStringOne);
}

fn appendStringOne(ctx: *const Context) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const serialized = args.next() orelse return error.MissingTokens;
    const val: value.Union = try .deserialize(serialized);
    if (val != .string) return error.MismatchType;

    const string: value.String = blk: {
        const ref = memoryGet(ctx, key) orelse break :blk .from("");
        if (!assume_lock_ownership and ref.metadata.locked) return error.Locked;
        if (ref.value != .string) return error.MismatchType;
        break :blk ref.value.string;
    };

    var allocating: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer allocating.deinit();
    try string.appendToWriter(&allocating.writer, val.string);
    const result: value.String = .fromOwnedSlice(allocating.written());
    try memoryPut(ctx, key, .{ .string = result });

    const integer: value.Union = .{ .integer = .from(@intCast(result.len())) };
    try reply.writeValue(ctx.writer, integer);
}

fn insert_string(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, insertStringOne);
}

fn insertStringOne(ctx: *const Context) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = memoryGet(ctx, key) orelse return error.KeyNotFound;
    if (!assume_lock_ownership and ref.metadata.locked) return error.Locked;
    if (ref.value != .string) return error.MismatchType;

    const string = ref.value.string;
    const index = try nextIndex(&args, string.len());
    const serialized = args.next() orelse return error.MissingTokens;
    const val: value.Union = try .deserialize(serialized);
    if (val != .string) return error.MismatchType;

    var allocating: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer allocating.deinit();
    if (ctx.query.flags.replace.get()) {
        try string.replaceToWriter(&allocating.writer, val.string, index);
    } else {
        try string.insertToWriter(&allocating.writer, val.string, index);
    }

    if (ctx.query.flags.get.get()) {
        try reply.writeValue(ctx.writer, ref.value);
    }

    try memoryPut(ctx, key, .{ .string = .fromOwnedSlice(allocating.written()) });
}

fn insert_list(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, insertListOne);
}

fn insertListOne(ctx: *const Context) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = memoryGet(ctx, key) orelse return error.KeyNotFound;
    if (!assume_lock_ownership and ref.metadata.locked) return error.Locked;
    if (ref.value != .list) return error.MismatchType;

    const list = ref.value.list;
    const index = try nextIndex(&args, list.count());
    const serialized = args.next() orelse return error.MissingTokens;
    const val: value.Union = try .deserialize(serialized);
    if (val == .list) return error.MismatchType;

    var allocating: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer allocating.deinit();

    if (ctx.query.flags.replace.get()) {
        try list.replaceToWriter(&allocating.writer, val, index);
    } else {
        try list.insertToWriter(&allocating.writer, val, index);
    }

    if (ctx.query.flags.get.get()) {
        try reply.writeValue(ctx.writer, try list.get(index));
    }

    try memoryPut(ctx, key, .{ .list = .fromOwnedSlice(allocating.written()) });
}

fn add(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, addOrSub(.add));
}

fn sub(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, addOrSub(.sub));
}

fn addOrSub(comptime op: enum { add, sub }) *const fn (*const Context) anyerror!void {
    return struct {
        fn addOrSub(ctx: *const Context) !void {
            const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
            var args = ctx.query.args.iterator();

            const key = args.next() orelse return error.MissingTokens;
            const ref = memoryGet(ctx, key) orelse return error.KeyNotFound;
            if (!assume_lock_ownership and ref.metadata.locked) return error.Locked;

            const serialized = args.next() orelse return error.MissingTokens;
            const val: value.Union = try .deserialize(serialized);
            if (ref.value.type() != val.type()) return error.MismatchType;

            const result = switch (val) {
                inline .integer, .decimal => |_, t| res: {
                    const a = @field(ref.value, @tagName(t));
                    const b = @field(val, @tagName(t));
                    const res = switch (op) {
                        .add => try a.add(b),
                        .sub => try a.sub(b),
                    };
                    break :res @unionInit(value.Union, @tagName(t), res);
                },
                else => return error.MismatchType,
            };
            try memoryPut(ctx, key, result);
            try reply.writeValue(ctx.writer, result);
        }
    }.addOrSub;
}

fn rename(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, renameOneWrapper);
}

fn renameOneWrapper(ctx: *const Context) !void {
    const success = try renameOne(ctx);
    const integer: value.Union = .{ .integer = .from(@intFromBool(success)) };
    try reply.writeValue(ctx.writer, integer);
}

fn renameOne(ctx: *const Context) !bool {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const selected_key = args.next() orelse return error.MissingTokens;
    const new_key = args.next() orelse return error.MissingTokens;

    if (std.mem.eql(u8, selected_key, new_key)) return true;

    const new_ref = memoryGet(ctx, new_key);
    if (new_ref) |ref| {
        if (!assume_lock_ownership and ref.metadata.locked)
            return error.Locked;

        if (ctx.query.flags.if_not_exists.get()) return false;
    }

    const selected_ref = memoryGet(ctx, selected_key) orelse
        return error.KeyNotFound;
    if (!assume_lock_ownership and selected_ref.metadata.locked)
        return error.Locked;

    const lock_new_key = selected_ref.metadata.locked and
        (new_ref == null or !new_ref.?.metadata.locked);

    try memoryPut(ctx, new_key, selected_ref.value);

    // Inserting a key may invalidate references into the hashset.
    if (lock_new_key) assert(memoryGet(ctx, new_key).?.lock());
    ctx.memory.remove(ctx.allocator, memoryGet(ctx, selected_key).?);
    return true;
}

fn copy(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, copyOneWrapper);
}

fn copyOneWrapper(ctx: *const Context) !void {
    const success = try copyOne(ctx);
    if (ctx.query.flags.get.get()) return;

    const integer: value.Union = .{ .integer = .from(@intFromBool(success)) };
    try reply.writeValue(ctx.writer, integer);
}

fn copyOne(ctx: *const Context) !bool {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const src_key = args.next() orelse return error.MissingTokens;
    const dst_key = args.next() orelse return error.MissingTokens;

    if (memoryGet(ctx, dst_key)) |ref| {
        if (!assume_lock_ownership and ref.metadata.locked) return error.Locked;
        if (ctx.query.flags.if_not_exists.get()) return false;

        if (ctx.query.flags.get.get()) {
            try writeValue(ctx, ref.value);
        }
    }

    const src = memoryGet(ctx, src_key) orelse return error.KeyNotFound;
    if (std.mem.eql(u8, src_key, dst_key)) return true;

    try memoryPut(ctx, dst_key, src.value);

    return true;
}

fn @"type"(ctx: *const Context) Error!void {
    return writeOrThrowForEachKey(ctx, typeOne);
}

fn typeOne(ctx: *const Context, key: []const u8) !void {
    const ref = memoryGet(ctx, key) orelse return error.KeyNotFound;
    const string: value.Union = .{ .string = .from(@tagName(ref.value.type())) };
    try reply.writeValue(ctx.writer, string);
}

fn type_list(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, typeListOne);
}

fn typeListOne(ctx: *const Context) !void {
    const limit: Quota = .init(ctx.query.flags.limit.get());
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = memoryGet(ctx, key) orelse return error.KeyNotFound;
    if (ref.value != .list) return error.MismatchType;

    const list = ref.value.list;
    const from, const to = try nextRange(&args, list.count());
    const range = list.getRange(from, @min(to - from + 1, limit.remaining()));

    const serializer: value.List.Serializer = try .begin(ctx.writer);
    var items = range.iterator();
    while (try items.next()) |val| {
        const item = try serializer.beginItem();
        defer item.end();

        const string: value.Union = .{ .string = .from(@tagName(val.type())) };
        try reply.writeValue(ctx.writer, string);
    }
}

fn keys_patterns(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, keysPatternsOne);
}

fn keysPatternsOne(ctx: *const Context) !void {
    const cursor = ctx.query.flags.cursor.get();
    var limit: Quota = .init(ctx.query.flags.limit.get());

    // true when patterns contains "*"
    var has_any_pattern: bool = false;
    var args = ctx.query.args.iterator();
    while (args.next()) |pattern| {
        if (glob.classify(pattern) != .any) continue;
        // Hint to avoid matching with
        // all available patterns.
        has_any_pattern = true;
    }

    const serializer: value.List.Serializer = try .begin(ctx.writer);

    var iterator = ctx.memory.iterator();
    // Starts from last cursor.
    iterator.skip(cursor);
    while (iterator.next()) |entry| {
        if (limit.exceeded()) break;
        defer limit.advance();
        const key = entry.key;

        var matches: bool = has_any_pattern;
        // If any pattern `*` is not detected, we should see
        // if there is a matching pattern with key.
        if (!matches) {
            // To avoid allocations we should
            // iterate patterns for each key.
            args.reset();
            while (args.next()) |pattern| {
                if (glob.match(pattern, key)) {
                    // We found a matching pattern!
                    matches = true;
                    break;
                }
            }
        }

        if (matches) {
            const item = try serializer.beginItem();
            defer item.end();

            const string: value.Union = .{ .string = .from(key) };
            try reply.writeValue(ctx.writer, string);
        }
    }
}

fn purge(ctx: *const Context) !void {
    // implicit assume_lock_ownership = true
    return ctx.memory.clear(ctx.allocator);
}

fn lock(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, tryLock);
}

fn tryLock(ctx: *const Context) !void {
    var args = ctx.query.args.iterator();
    // First we have to check if any key is already locked.
    while (args.next()) |key| {
        const ref = memoryGet(ctx, key) orelse return error.KeyNotFound;
        if (ref.metadata.locked) return error.Locked;
    }
    args.reset();
    // Assuming all the keys aren't locked,
    // we can lock them all.
    while (args.next()) |key| {
        const ref = memoryGet(ctx, key) orelse return error.KeyNotFound;
        assert(ref.lock());
    }
}

fn unlock(ctx: *const Context) Error!void {
    // implicit assume_lock_ownership = true
    var args = ctx.query.args.iterator();
    // Unlocks all keys that exists.
    while (args.next()) |key| {
        // Maybe deleted key after lock?
        const ref = memoryGet(ctx, key) orelse continue;
        ref.unlock();
    }
}

fn lock_patterns(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, lockPatternsOne);
}

fn lockPatternsOne(ctx: *const Context) !void {
    // true when patterns contains "*"
    var has_any_pattern: bool = false;
    var args = ctx.query.args.iterator();
    while (args.next()) |pattern| {
        if (glob.classify(pattern) != .any) continue;
        // Hint to avoid matching with
        // all available patterns.
        // You are trying to lock the entire database???
        has_any_pattern = true;
    }

    var iterator = ctx.memory.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key;

        var matches: bool = has_any_pattern;
        // If any pattern `*` is not detected, we should see
        // if there is a matching pattern with key.
        if (!matches) {
            // To avoid allocations we should
            // iterate patterns for each key.
            args.reset();
            while (args.next()) |pattern| {
                if (glob.match(pattern, key)) {
                    // We found a matching pattern!
                    matches = true;
                    break;
                }
            }
        }

        if (matches and entry.ref.metadata.locked) return error.Locked;
    }

    iterator.reset();
    // We need another iteration to avoid allocations.
    while (iterator.next()) |entry| {
        const key, const ref = .{ entry.key, entry.ref };

        var matches: bool = has_any_pattern;
        // If any pattern `*` is not detected, we should see
        // if there is a matching pattern with key.
        if (!matches) {
            // To avoid allocations we should
            // iterate patterns for each key.
            args.reset();
            while (args.next()) |pattern| {
                if (glob.match(pattern, key)) {
                    // We found a matching pattern!
                    matches = true;
                    break;
                }
            }
        }

        // Assuming all selected keys are not locked, now
        // we can lock them as owner.
        if (matches) assert(ref.lock());
    }
}

fn unlock_patterns(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, unlockPatternsOne);
}

fn unlockPatternsOne(ctx: *const Context) !void {
    // implicit assume_lock_ownership = true

    // true when patterns contains "*"
    var has_any_pattern: bool = false;
    var args = ctx.query.args.iterator();
    while (args.next()) |pattern| {
        if (glob.classify(pattern) != .any) continue;
        // Hint to avoid matching with
        // all available patterns.
        has_any_pattern = true;
    }

    var iterator = ctx.memory.iterator();
    while (iterator.next()) |entry| {
        const key, const ref = .{ entry.key, entry.ref };

        var matches: bool = has_any_pattern;
        // If any pattern `*` is not detected, we should see
        // if there is a matching pattern with key.
        if (!matches) {
            // To avoid allocations we should
            // iterate patterns for each key.
            args.reset();
            while (args.next()) |pattern| {
                if (glob.match(pattern, key)) {
                    // We found a matching pattern!
                    matches = true;
                    break;
                }
            }
        }

        if (matches) ref.unlock();
    }
}

fn memoryGet(ctx: *const Context, key: []const u8) ?Memory.Ref {
    if (glob.classify(key) != .literal) return null;
    return ctx.memory.get(key);
}

fn memoryPut(ctx: *const Context, key: []const u8, val: value.Union) !void {
    if (glob.classify(key) != .literal) return error.InvalidKey;
    return ctx.memory.put(ctx.allocator, key, val);
}

fn writeOrThrowForEachKey(
    ctx: *const Context,
    callback: *const fn (*const Context, key: []const u8) anyerror!void,
) Error!void {
    const serializer: value.List.Serializer = try .begin(ctx.writer);

    var args = ctx.query.args.iterator();
    while (args.next()) |key| {
        const item = try serializer.beginItem();
        defer item.end();

        const offset = ctx.writer.end;
        callback(ctx, key) catch |err| switch (err) {
            inline error.OutOfMemory, error.WriteFailed => |e| return @errorCast(e),
            else => err: {
                ctx.writer.end = offset;
                break :err try reply.writeError(ctx.writer, .fromError(err));
            },
        };
    }
}

fn writeOrThrow(
    ctx: *const Context,
    callback: *const fn (*const Context) anyerror!void,
) Error!void {
    const offset = ctx.writer.end;
    callback(ctx) catch |err| return switch (err) {
        inline error.OutOfMemory, error.WriteFailed => |e| @errorCast(e),
        else => blk: {
            ctx.writer.end = offset;
            break :blk reply.writeError(ctx.writer, .fromError(err));
        },
    };
}

fn writeValue(ctx: *const Context, val: value.Union) !void {
    var limit: Quota = .init(ctx.query.flags.limit.get());

    switch (val) {
        .list => |list| {
            const range = list.getRange(0, limit.remaining());
            try reply.writeValue(ctx.writer, .{ .list = range });
        },
        else => {
            try reply.writeValue(ctx.writer, val);
        },
    }
}

fn nextRange(
    iterator: *frames.IteratorType(Query.Args.Header),
    length: u64,
) error{ MissingTokens, MismatchType, RangeOverflow }!struct { u64, u64 } {
    const from = try nextIndex(iterator, length);
    const to = try nextIndex(iterator, length);
    if (from > to) return error.RangeOverflow;
    return .{ from, to };
}

fn nextIndex(
    iterator: *frames.IteratorType(Query.Args.Header),
    length: u64,
) error{ MissingTokens, MismatchType }!u64 {
    const relative_index = try nextNumeric(iterator, i64);
    return resolveIndex(relative_index, length);
}

fn nextNumeric(
    iterator: *frames.IteratorType(Query.Args.Header),
    comptime T: type,
) error{ MissingTokens, MismatchType }!T {
    const content = iterator.next() orelse return error.MissingTokens;
    if (content.len != @sizeOf(T)) return error.MismatchType;
    return std.mem.readInt(T, content[0..@sizeOf(T)], .little);
}

fn resolveIndex(index: i64, len: u64) u64 {
    const signed_len: i64 = @intCast(len);

    var resolved: i64 = index;
    if (index < 0) {
        resolved = signed_len +| index;
    } else if (index >= signed_len) {
        resolved = signed_len - 1;
    }

    return @max(0, resolved);
}
