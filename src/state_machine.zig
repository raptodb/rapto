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
const assert = std.debug.assert;

const Ref = @import("object.zig").Ref;
const Memory = @import("Memory.zig");
const Query = @import("Query.zig");
const Flags = Query.Flags;
const Value = @import("object.zig").Value;

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
    const integer: Value.Integer = .fromValue(1);
    try reply.writeValue(ctx.writer, integer);
}

fn get(ctx: *const Context) Error!void {
    return writeOrThrowForEachKey(ctx, getOne);
}

fn getOne(ctx: *const Context, key: []const u8) !void {
    const ref = try ctx.memory.get(key);
    return writeRef(ctx, ref);
}

fn get_list(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, getListOne);
}

fn getListOne(ctx: *const Context) !void {
    var limit: Quota = .init(ctx.query.flags.limit.get());
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = try ctx.memory.get(key);
    if (ref.type() != .list) return error.MismatchType;

    const list: Value.List = ref.value(.list);

    const from, const to = try nextRange(&args, list.count());
    const range_len = from + @min(to - from + 1, limit.remaining());
    const range = try list.getByRange(from, range_len);

    try serializeList(ctx.writer, range);
}

fn get_map(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, getMapOne);
}

fn getMapOne(ctx: *const Context) !void {
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = try ctx.memory.get(key);
    if (ref.type() != .map) return error.MismatchType;

    const map: Value.Map = ref.value(.map);

    var serializer: reply.ListSerializer = try .begin(ctx.writer);
    defer serializer.end();

    while (args.next()) |map_key| {
        var frame = try serializer.beginFrame();
        defer frame.end();

        const scalar = map.getByKey(map_key) catch continue;
        try reply.writeValue(ctx.writer, scalar);
    }
}

fn del(ctx: *const Context) Error!void {
    var args = ctx.query.args.iterator();

    if (ctx.query.flags.get.get()) {
        return writeOrThrowForEachKey(ctx, getDelOne);
    }

    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var total_deleted: i64 = 0;
    while (args.next()) |key| {
        const ref = ctx.memory.get(key) catch continue;
        if (!assume_lock_ownership and ref.isLocked()) continue;

        ctx.memory.removeByRef(ctx.allocator, ref);
        total_deleted += 1;
    }

    const integer: Value.Integer = .fromValue(total_deleted);
    try reply.writeValue(ctx.writer, integer);
}

fn getDelOne(ctx: *const Context, key: []const u8) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    const ref = try ctx.memory.get(key);
    if (!assume_lock_ownership and ref.isLocked()) return error.Locked;

    try writeRef(ctx, ref);
    ctx.memory.removeByRef(ctx.allocator, ref);
}

fn del_patterns(ctx: *const Context) Error!void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var limit: Quota = .init(ctx.query.flags.limit.get());

    const total_deleted: i64 = blk: {
        // true when patterns contains "*"
        var has_any_pattern: bool = false;
        var args = ctx.query.args.iterator();
        while (args.next()) |pattern| {
            if (glob.classify(pattern) != .any) continue;

            const total_keys = ctx.memory.count();
            if (!assume_lock_ownership or total_keys > limit.remaining()) {
                // We have to count/check keys one by one iterating.
                // We cant remove keys that are locked or that exceeds limit.
                // This is an hint to avoid matching with
                // all available patterns.
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
        while (iterator.next()) |ref| {
            if (limit.exceeded()) break;
            const key = ref.key();

            if (!assume_lock_ownership and ref.isLocked()) continue;

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
                ctx.memory.removeByRef(ctx.allocator, ref);
                deleted += 1;
                limit.advance();
            }
        }

        break :blk deleted;
    };

    const integer: Value.Integer = .fromValue(total_deleted);
    try reply.writeValue(ctx.writer, integer);
}

fn del_list(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, delListOne);
}

fn delListOne(ctx: *const Context) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var limit: Quota = .init(ctx.query.flags.limit.get());
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = try ctx.memory.get(key);
    if (!assume_lock_ownership and ref.isLocked()) return error.Locked;
    if (ref.type() != .list) return error.MismatchType;

    const list: Value.List = ref.value(.list);

    const from, const to = try nextRange(&args, list.count());
    const range_len = @min(to - from + 1, limit.remaining());
    const range = try list.getByRange(from, range_len);

    if (ctx.query.flags.get.get()) {
        try serializeList(ctx.writer, range);
    } else {
        const integer: Value.Integer = .fromValue(@intCast(list.count() - range_len));
        try reply.writeValue(ctx.writer, integer);
    }

    try list.removeByRange(ctx.allocator, from, range_len);
}

fn del_map(ctx: *const Context) Error!void {
    try writeOrThrow(ctx, delMapOne);
}

fn delMapOne(ctx: *const Context) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = try ctx.memory.get(key);
    if (!assume_lock_ownership and ref.isLocked()) return error.Locked;
    if (ref.type() != .map) return error.MismatchType;

    const map: Value.Map = ref.value(.map);

    if (ctx.query.flags.get.get()) {
        var serializer: reply.ListSerializer = try .begin(ctx.writer);
        defer serializer.end();

        while (args.next()) |map_key| {
            var frame = try serializer.beginFrame();
            defer frame.end();

            const scalar = map.popByKey(ctx.allocator, map_key) catch continue;
            defer scalar.deinit(ctx.allocator);
            try reply.writeValue(ctx.writer, scalar);
        }
    } else {
        while (args.next()) |map_key| {
            map.removeByKey(ctx.allocator, map_key) catch continue;
        }

        const integer: Value.Integer = .fromValue(@intCast(map.count()));
        try reply.writeValue(ctx.writer, integer);
    }
}

fn count_patterns(ctx: *const Context) Error!void {
    var limit: Quota = .init(ctx.query.flags.limit.get());

    const key_count: i64 = blk: {
        var args = ctx.query.args.iterator();
        while (args.next()) |pattern| {
            if (glob.classify(pattern) != .any) continue;

            const total_keys: i64 = @intCast(ctx.memory.count());
            // With minimus we follow the same behaviour
            // if we had done iterations one by one to
            // check the pattern.
            // Total keys will always be within limit.
            break :blk @min(total_keys, limit.remaining());
        }

        var counted: i64 = 0;
        var iterator = ctx.memory.iterator();
        // Starts from last cursor.
        iterator.skip(ctx.query.flags.cursor.get());
        while (iterator.next()) |ref| {
            if (limit.exceeded()) break;
            const key = ref.key();

            var matches: bool = false;
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

            if (matches) {
                counted += 1;
                limit.advance();
            }
        }

        break :blk counted;
    };

    const integer: Value.Integer = .fromValue(key_count);
    try reply.writeValue(ctx.writer, integer);
}

fn count_list(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, countListOne);
}

fn countListOne(ctx: *const Context) !void {
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = try ctx.memory.get(key);
    if (ref.type() != .list) return error.MismatchType;

    const list: Value.List = ref.value(.list);

    const integer: Value.Integer = .fromValue(@intCast(list.count()));
    try reply.writeValue(ctx.writer, integer);
}

fn count_map_patterns(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, countMapPatternsOne);
}

fn countMapPatternsOne(ctx: *const Context) !void {
    var limit: Quota = .init(ctx.query.flags.limit.get());
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = try ctx.memory.get(key);
    if (ref.type() != .map) return error.MismatchType;

    const map: Value.Map = ref.value(.map);

    const key_count: i64 = blk: {
        while (args.next()) |pattern| {
            if (glob.classify(pattern) != .any) continue;

            const total_keys: i64 = @intCast(ctx.memory.count());
            // With minimus we follow the same behaviour
            // if we had done iterations one by one to
            // check the pattern.
            // Total keys will always be within limit.
            break :blk @min(total_keys, limit.remaining());
        }

        var counted: i64 = 0;
        var iterator = map.getKeys();
        // Starts from last cursor.
        iterator.skip(ctx.query.flags.cursor.get());
        while (iterator.next()) |map_key| {
            if (limit.exceeded()) break;

            var matches: bool = false;
            // To avoid allocations we should
            // iterate patterns for each key.
            args.reset();
            // After iterator resetting, skips Memory key.
            // Next arguments should be patterns.
            args.skip(1);
            while (args.next()) |pattern| {
                if (glob.match(pattern, map_key)) {
                    // We found a matching pattern!
                    matches = true;
                    break;
                }
            }

            if (matches) {
                counted += 1;
                limit.advance();
            }
        }

        break :blk counted;
    };

    const integer: Value.Integer = .fromValue(key_count);
    try reply.writeValue(ctx.writer, integer);
}

fn exists(ctx: *const Context) Error!void {
    return writeOrThrowForEachKey(ctx, existsOne);
}

fn existsOne(ctx: *const Context, key: []const u8) !void {
    const key_exists = ctx.memory.get(key) != error.KeyNotFound;
    const integer: Value.Integer = .fromValue(@intFromBool(key_exists));
    try reply.writeValue(ctx.writer, integer);
}

fn exists_map(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, existsMapOne);
}

fn existsMapOne(ctx: *const Context) !void {
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = try ctx.memory.get(key);
    if (ref.type() != .map) return error.MismatchType;

    const map: Value.Map = ref.value(.map);

    var serializer: reply.ListSerializer = try .begin(ctx.writer);
    defer serializer.end();

    while (args.next()) |map_key| {
        var frame = try serializer.beginFrame();
        defer frame.end();

        const key_exists = map.getByKey(map_key) != error.MapKeyNotFound;
        const integer: Value.Integer = .fromValue(@intFromBool(key_exists));
        try reply.writeValue(ctx.writer, integer);
    }
}

fn set(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, setOne);
}

fn setOne(ctx: *const Context) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const serialized = args.next() orelse return error.MissingTokens;

    const value_type, const content = try Value.splitSerialized(serialized);
    if (value_type.group() == .collection) return error.MismatchType;

    const existing_ref: ?Ref = ctx.memory.get(key) catch null;

    if (existing_ref) |ref| {
        if (!assume_lock_ownership and ref.isLocked()) return error.Locked;

        if (ctx.query.flags.get.get()) {
            try writeRef(ctx, ref);
        }
        if (!ctx.query.flags.if_not_exists.get()) {
            try ref.setValueFromContent(ctx.allocator, value_type, content);
        }
    } else {
        _ = try ctx.memory.put(ctx.allocator, key, value_type, content);
    }
}

fn append_list(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, appendListOne);
}

fn appendListOne(ctx: *const Context) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const serialized = args.next() orelse return error.MissingTokens;

    const er = try ctx.memory.ensure(ctx.allocator, key, .list, &.{});
    const ref = er.ref;
    errdefer if (!er.found_existing) ctx.memory.removeByRef(ctx.allocator, ref);

    if (!assume_lock_ownership and ref.isLocked()) return error.Locked;
    if (ref.type() != .list) return error.MismatchType;

    const list: Value.List = ref.value(.list);
    try list.insert(ctx.allocator, list.count(), serialized);

    const integer: Value.Integer = .fromValue(@intCast(list.count()));
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
    const value_type, const content = try Value.splitSerialized(serialized);
    if (value_type != .string) return error.MismatchType;

    const er = try ctx.memory.ensure(ctx.allocator, key, .string, &.{});
    const ref = er.ref;
    errdefer if (!er.found_existing) ctx.memory.removeByRef(ctx.allocator, ref);

    if (!assume_lock_ownership and ref.isLocked()) return error.Locked;
    if (value_type != .string) return error.MismatchType;

    var string: Value.String = ref.value(.string);
    try string.insert(ctx.allocator, string.len(), content);
    ref.setValue(ctx.allocator, .{ .string = string });

    const integer: Value.Integer = .fromValue(@intCast(string.len()));
    try reply.writeValue(ctx.writer, integer);
}

fn insert_string(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, insertStringOne);
}

fn insertStringOne(ctx: *const Context) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = try ctx.memory.get(key);

    if (!assume_lock_ownership and ref.isLocked()) return error.Locked;
    if (ref.type() != .string) return error.MismatchType;

    var string: Value.String = ref.value(.string);

    const index = try nextIndex(&args, string.len());
    const serialized = args.next() orelse return error.MissingTokens;
    const value_type, const content = try Value.splitSerialized(serialized);
    if (value_type != .string) return error.MismatchType;

    if (ctx.query.flags.get.get()) {
        try reply.writeValue(ctx.writer, string);
    }

    if (ctx.query.flags.replace.get()) {
        try string.replace(@truncate(index), content);
    } else {
        try string.insert(ctx.allocator, @truncate(index), content);
    }

    ref.setValue(ctx.allocator, .{ .string = string });
}

fn insert_list(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, insertListOne);
}

fn insertListOne(ctx: *const Context) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = try ctx.memory.get(key);
    if (!assume_lock_ownership and ref.isLocked()) return error.Locked;
    if (ref.type() != .list) return error.MismatchType;

    const list: Value.List = ref.value(.list);

    const index = try nextIndex(&args, list.count());
    const serialized = args.next() orelse return error.MissingTokens;

    if (ctx.query.flags.get.get()) {
        const old_value = (try list.getByRange(index, 1))[0];
        try reply.writeValue(ctx.writer, old_value);
    }

    if (ctx.query.flags.replace.get()) {
        try list.setByIndex(ctx.allocator, index, serialized);
    } else {
        try list.insert(ctx.allocator, index, serialized);
    }
}

fn put(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, putOne);
}

fn putOne(ctx: *const Context) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const er = try ctx.memory.ensure(ctx.allocator, key, .map, &.{});
    const ref = er.ref;
    errdefer if (!er.found_existing) ctx.memory.removeByRef(ctx.allocator, ref);

    if (!assume_lock_ownership and ref.isLocked()) return error.Locked;
    if (ref.type() != .map) return error.MismatchType;

    const map_key = args.next() orelse return error.MissingTokens;
    const serialized = args.next() orelse return error.MissingTokens;

    const map: Value.Map = ref.value(.map);

    if (ctx.query.flags.get.get()) {
        const scalar: ?Value.Scalar = map.getByKey(map_key) catch null;
        if (scalar) |s| {
            try reply.writeValue(ctx.writer, s); // Fast path.
            if (ctx.query.flags.if_not_exists.get()) return;
        }
    }

    if (ctx.query.flags.if_not_exists.get()) {
        // Never replaces.
        _ = try map.ensure(ctx.allocator, map_key, serialized);
    } else {
        _ = try map.put(ctx.allocator, map_key, serialized);
    }
}

fn add(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, addOne);
}

fn addOne(ctx: *const Context) !void {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = try ctx.memory.get(key);

    if (!assume_lock_ownership and ref.isLocked()) return error.Locked;

    const is_add = try nextNumeric(&args, u8) == 1;

    const serialized = args.next() orelse return error.MissingTokens;
    const value_type, const content = try Value.splitSerialized(serialized);
    if (value_type != ref.type()) return error.MismatchType;

    switch (value_type) {
        inline .integer, .decimal => |vt| {
            var result: Value.UnionType(vt) = try .fromContent(content);
            const value = ref.value(vt).get();
            if (is_add) try result.add(value) else try result.sub(value);
            ref.setValue(
                ctx.allocator,
                @unionInit(Value, @tagName(vt), result),
            );

            try reply.writeValue(ctx.writer, result);
        },
        else => return error.MismatchType,
    }
}

fn rename(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, renameOneWrapper);
}

fn renameOneWrapper(ctx: *const Context) !void {
    const success = try renameOne(ctx);
    const integer: Value.Integer = .fromValue(@intCast(@intFromBool(success)));
    try reply.writeValue(ctx.writer, integer);
}

fn renameOne(ctx: *const Context) !bool {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const selected_key = args.next() orelse return error.MissingTokens;
    const new_key = args.next() orelse return error.MissingTokens;

    if (std.mem.eql(u8, selected_key, new_key)) return true;

    const new_ref = ctx.memory.get(new_key);
    if (new_ref != error.KeyNotFound) {
        if (new_ref) |ref| {
            if (!assume_lock_ownership and ref.isLocked()) return error.Locked;
        } else |_| {}
    }

    if (new_ref != error.KeyNotFound and ctx.query.flags.if_not_exists.get()) return false;

    if (new_ref != error.KeyNotFound) ctx.memory.removeByRef(
        ctx.allocator,
        new_ref catch unreachable,
    );
    const selected_ref = try ctx.memory.get(selected_key);
    if (!assume_lock_ownership and selected_ref.isLocked()) return error.Locked;

    try selected_ref.setKey(ctx.allocator, new_key);
    return true;
}

fn copy(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, copyOneWrapper);
}

fn copyOneWrapper(ctx: *const Context) !void {
    const success = try copyOne(ctx);
    const integer: Value.Integer = .fromValue(@intCast(@intFromBool(success)));
    try reply.writeValue(ctx.writer, integer);
}

fn copyOne(ctx: *const Context) !bool {
    const assume_lock_ownership = ctx.query.flags.assume_lock_ownership.get();
    var args = ctx.query.args.iterator();

    const src_key = args.next() orelse return error.MissingTokens;
    const dst_key = args.next() orelse return error.MissingTokens;

    const dst = try ctx.memory.ensure(ctx.allocator, dst_key, .void, &.{});
    errdefer if (!dst.found_existing) ctx.memory.removeByRef(ctx.allocator, dst.ref);
    if (!assume_lock_ownership and dst.ref.isLocked()) return error.Locked;

    if (dst.found_existing and ctx.query.flags.if_not_exists.get()) return false;

    if (ctx.query.flags.get.get() and dst.found_existing) {
        try writeRef(ctx, dst.ref);
    }

    try ctx.memory.copy(ctx.allocator, src_key, dst.ref);
    return true;
}

fn @"type"(ctx: *const Context) Error!void {
    return writeOrThrowForEachKey(ctx, typeOne);
}

fn typeOne(ctx: *const Context, key: []const u8) !void {
    const ref = try ctx.memory.get(key);
    try reply.writeSerialized(ctx.writer, .string, @tagName(ref.type()));
}

fn type_list(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, typeListOne);
}

fn typeListOne(ctx: *const Context) !void {
    var limit: Quota = .init(ctx.query.flags.limit.get());
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = try ctx.memory.get(key);

    if (ref.type() != .list) return error.MismatchType;

    const list: Value.List = ref.value(.list);

    const from, const to = try nextRange(&args, list.count());
    const range_len = @min(to - from + 1, limit.remaining());
    const range = try list.getByRange(from, range_len);

    var serializer: reply.ListSerializer = try .begin(ctx.writer);
    defer serializer.end();

    for (range) |scalar| {
        var frame = try serializer.beginFrame();
        defer frame.end();

        try reply.writeSerialized(ctx.writer, .string, @tagName(scalar.type()));
    }
}

fn type_map(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, typeMapOne);
}

fn typeMapOne(ctx: *const Context) !void {
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = try ctx.memory.get(key);
    if (ref.type() != .map) return error.MismatchType;

    const map: Value.Map = ref.value(.map);

    var serializer: reply.ListSerializer = try .begin(ctx.writer);
    defer serializer.end();

    while (args.next()) |map_key| {
        var frame = try serializer.beginFrame();
        defer frame.end();

        const scalar = map.getByKey(map_key) catch continue;
        try reply.writeSerialized(ctx.writer, .string, @tagName(scalar.type()));
    }
}

fn keys_patterns(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, keysPatternsOne);
}

fn keysPatternsOne(ctx: *const Context) !void {
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

    var serializer: reply.ListSerializer = try .begin(ctx.writer);
    defer serializer.end();

    var iterator = ctx.memory.iterator();
    // Starts from last cursor.
    iterator.skip(ctx.query.flags.cursor.get());
    while (iterator.next()) |ref| {
        if (limit.exceeded()) return;
        const key = ref.key();

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
            var frame = try serializer.beginFrame();
            defer {
                frame.end();
                limit.advance();
            }

            try reply.writeSerialized(ctx.writer, .string, key);
        }
    }
}

fn entries_patterns(ctx: *const Context) Error!void {
    return writeOrThrow(ctx, entriesPatternsOne);
}

fn entriesPatternsOne(ctx: *const Context) !void {
    var limit: Quota = .init(ctx.query.flags.limit.get());
    var args = ctx.query.args.iterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = try ctx.memory.get(key);
    if (ref.type() != .map) return error.MismatchType;

    const map: Value.Map = ref.value(.map);

    // true when patterns contains "*"
    var has_any_pattern: bool = false;
    while (args.next()) |pattern| {
        if (glob.classify(pattern) != .any) continue;

        // Hint to avoid matching with
        // all available patterns.
        has_any_pattern = true;
    }

    var serializer: reply.ListSerializer = try .begin(ctx.writer);
    defer serializer.end();

    var iterator = map.getKeys();
    // Starts from last cursor.
    iterator.skip(ctx.query.flags.cursor.get());
    while (iterator.next()) |map_key| {
        if (limit.exceeded()) return;

        var matches: bool = has_any_pattern;
        // If any pattern `*` is not detected, we should see
        // if there is a matching pattern with key.
        if (!matches) {
            // To avoid allocations we should
            // iterate patterns for each key.
            args.reset();
            // After iterator resetting, skips Memory key.
            // Next arguments should be patterns.
            args.skip(1);
            while (args.next()) |pattern| {
                if (glob.match(pattern, map_key)) {
                    // We found a matching pattern!
                    matches = true;
                    break;
                }
            }
        }

        if (matches) {
            var frame = try serializer.beginFrame();
            defer {
                frame.end();
                limit.advance();
            }

            try reply.writeSerialized(ctx.writer, .string, map_key);
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
        const ref = try ctx.memory.get(key);
        if (ref.isLocked()) return error.Locked;
    }
    args.reset();
    // Assuming all the keys aren't locked,
    // we can lock them all.
    while (args.next()) |key| {
        const ref = try ctx.memory.get(key);
        ref.lock();
    }
}

fn unlock(ctx: *const Context) Error!void {
    // implicit assume_lock_ownership = true

    var args = ctx.query.args.iterator();
    // Unlocks all keys that exists.
    while (args.next()) |key| {
        // Maybe deleted key after lock?
        const ref = ctx.memory.get(key) catch continue;
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
    while (iterator.next()) |ref| {
        const key = ref.key();

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

        if (matches and ref.isLocked()) return error.Locked;
    }

    iterator.reset();
    // We need another iteration to avoid allocations.
    while (iterator.next()) |ref| {
        const key = ref.key();

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
        if (matches) ref.lock();
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
        if (glob.classify(pattern) == .any) continue;
        // Hint to avoid matching with
        // all available patterns.
        has_any_pattern = true;
    }

    var iterator = ctx.memory.iterator();
    while (iterator.next()) |ref| {
        const key = ref.key();

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

fn writeOrThrowForEachKey(
    ctx: *const Context,
    callback: *const fn (*const Context, key: []const u8) anyerror!void,
) Error!void {
    var serializer: reply.ListSerializer = try .begin(ctx.writer);
    defer serializer.end();

    var args = ctx.query.args.iterator();
    while (args.next()) |key| {
        var frame = try serializer.beginFrame();
        defer frame.end();

        callback(ctx, key) catch |err| return switch (err) {
            inline error.OutOfMemory, error.WriteFailed => |e| @errorCast(e),
            else => reply.writeError(ctx.writer, .fromError(err)),
        };
    }
}

fn writeOrThrow(
    ctx: *const Context,
    callback: *const fn (*const Context) anyerror!void,
) Error!void {
    callback(ctx) catch |err| return switch (err) {
        inline error.OutOfMemory, error.WriteFailed => |e| @errorCast(e),
        else => reply.writeError(ctx.writer, .fromError(err)),
    };
}

fn serializeMap(
    writer: *std.Io.Writer,
    quota_limit: u64,
    map_iterator: Value.Map.PairIterator,
) Error!void {
    var limit: Quota = .init(quota_limit);

    var map_serializer: reply.MapSerializer = try .begin(writer);
    defer map_serializer.end();

    var iterator = map_iterator;
    while (iterator.next()) |pair| {
        if (limit.exceeded()) break;

        defer limit.advance();
        try map_serializer.append(pair);
    }
}

fn serializeList(
    writer: *std.Io.Writer,
    items: []const Value.Scalar,
) Error!void {
    var serializer: reply.ListSerializer = try .begin(writer);
    defer serializer.end();

    for (items) |scalar| {
        var frame = try serializer.beginFrame();
        defer frame.end();

        try reply.writeValue(writer, scalar);
    }
}

fn writeRef(ctx: *const Context, ref: Ref) !void {
    var limit: Quota = .init(ctx.query.flags.limit.get());

    switch (ref.type()) {
        .list => {
            const list: Value.List = ref.value(.list);
            const range = list.get();
            const fixed_range = range[0..@min(range.len, limit.remaining())];
            try serializeList(ctx.writer, fixed_range);
        },
        .map => {
            const map: Value.Map = ref.value(.map);
            try serializeMap(ctx.writer, limit.remaining(), map.get());
        },
        inline else => |value_type| {
            try reply.writeValue(ctx.writer, ref.value(value_type));
        },
    }
}

fn nextRange(
    iterator: *frames.Iterator,
    length: u64,
) error{ MissingTokens, MismatchType }!struct { u64, u64 } {
    const from = try nextIndex(iterator, length);
    const to = try nextIndex(iterator, length);
    return .{ from, to };
}

fn nextIndex(iterator: *frames.Iterator, length: u64) error{ MissingTokens, MismatchType }!u64 {
    const relative_index = try nextNumeric(iterator, i64);
    return resolveIndex(relative_index, length);
}

fn nextNumeric(
    iterator: *frames.Iterator,
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
