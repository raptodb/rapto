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

const Memory = @import("Memory.zig");
const Query = @import("Query.zig");
const Flags = Query.Flags;
const Value = @import("object.zig").Value;

/// The only errors that can be returned to execute function.
/// Others errors must be written on frames.
pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error;
pub const FatalError = error{
    // When command received from execute is DOWN
    Shutdown,
} || Error;

pub const Quota = struct {
    count: u64 = 0,
    quota: ?u64,

    pub fn init(quota: ?u64) Quota {
        return .{ .quota = quota };
    }

    pub fn exceeded(self: Quota) bool {
        return self.quota != null and self.count >= self.quota.?;
    }

    pub fn advance(self: *Quota) void {
        // Emissions can never overflow up to 2^64.
        @setRuntimeSafety(false);
        if (self.quota != null) self.count += 1;
    }
};

/// Executes query on this configuration. Fatal errors will be returned
/// directly, other errors will be written on frames directly.
pub fn execute(
    allocator: std.mem.Allocator,
    memory: *Memory, // Storage of state
    writer: *std.Io.Writer, // Output: maybe Allocating
    query: *const Query, // Input
) FatalError!void {
    const maybe_error = switch (query.command) {
        .del => del(allocator, memory, writer, query),
        .cdel => cdel(allocator, memory, writer, query),
        .pop => pop(allocator, memory, writer, query),
        .cpop => cpop(allocator, memory, writer, query),
        .set => set(allocator, memory, writer, query),
        .append => append(allocator, memory, writer, query),
        .insert => insert(allocator, memory, writer, query),
        .put => put(allocator, memory, writer, query),
        .rename => rename(allocator, memory, writer, query),
        .copy => copy(allocator, memory, writer, query),

        inline else => |read_command| err: {
            if (query.flags.limit.get() == 0) return;

            break :err switch (read_command) {
                .ping => ping(writer, query),
                .get => get(memory, writer, query),
                .cget => cget(memory, writer, query),
                .count => count(memory, writer, query),
                .ccount => ccount(memory, writer, query),
                .len => len(memory, writer, query),
                .type => @"type"(memory, writer, query),
                .ctype => ctype(memory, writer, query),
                .keys => keys(memory, writer, query),

                // Handled earlier.
                else => comptime unreachable,
            };
        },

        .down => error.Shutdown,
    };

    maybe_error catch |err| {
        @branchHint(.cold);
        return err;
    };
}

fn ping(writer: *std.Io.Writer, query: *const Query) Error!void {
    const limit: Quota = .init(query.flags.limit.get());
    assert(!limit.exceeded());

    const integer: Value.Integer = .fromValue(1);
    try reply.writeValue(writer, integer);
}

fn get(memory: *Memory, writer: *std.Io.Writer, query: *const Query) Error!void {
    var limit: Quota = .init(query.flags.limit.get());
    assert(!limit.exceeded());

    var serializer: reply.ListSerializer = try .begin(writer);
    defer serializer.end();

    var args = query.args.iterator();
    while (args.next()) |key| {
        var frame = try serializer.beginFrame();
        defer {
            frame.end();
            limit.advance();
        }

        const result = getOne(memory, writer, &limit, key);
        try writeOrThrow(writer, result);
    }
}

fn getOne(memory: *Memory, writer: *std.Io.Writer, limit: *Quota, key: []const u8) !void {
    const ref = memory.get(key) orelse return error.KeyNotFound;

    switch (ref.type()) {
        .list => {
            const list: Value.List = ref.value(.list);
            try serializeList(writer, limit, list.get());
        },
        .map => {
            const map: Value.Map = ref.value(.map);
            try serializeMap(writer, limit, map.get());
        },
        inline else => |value_type| {
            try reply.writeValue(writer, ref.value(value_type));
        },
    }
}

fn cget(memory: *Memory, writer: *std.Io.Writer, query: *const Query) Error!void {
    var limit: Quota = .init(query.flags.limit.get());
    assert(!limit.exceeded());

    var args = query.args.iterator();

    const result = cgetOne(memory, writer, &limit, &args);
    return writeOrThrow(writer, result);
}

fn cgetOne(
    memory: *Memory,
    writer: *std.Io.Writer,
    limit: *Quota,
    args: *frames.Iterator,
) !void {
    const key = args.next() orelse return error.MissingTokens;
    const ref = memory.get(key) orelse return error.KeyNotFound;

    const value_type = ref.type();
    if (value_type.group() == .scalar) return error.MismatchType;

    switch (value_type) {
        .list => {
            const list: Value.List = ref.value(.list);
            const list_len = list.count();

            const from, const to = try nextRange(args, list_len);
            const range = try list.getByRange(from, to);
            try serializeList(writer, limit, range);
        },
        .map => {
            const map: Value.Map = ref.value(.map);

            var serializer: reply.ListSerializer = try .begin(writer);
            defer serializer.end();

            while (args.next()) |map_key| {
                if (limit.exceeded()) return;

                var frame = try serializer.beginFrame();
                defer {
                    frame.end();
                    limit.advance();
                }

                if (map.getByKey(map_key)) |scalar| {
                    try scalar.serializeToWriter(writer);
                } else |_| {}
            }
        },
        // Handled earlier
        else => unreachable,
    }
}

fn del(
    allocator: std.mem.Allocator,
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
) Error!void {
    var limit: Quota = .init(query.flags.limit.get());

    var args = query.args.iterator();

    var total_deleted: i64 = 0;
    while (args.next()) |str| {
        switch (glob.classify(str)) {
            .any => {
                total_deleted = @intCast(memory.count());
                memory.free(allocator);
                break;
            },
            .literal => {
                const exist = memory.remove(allocator, str) != error.KeyNotFound;
                total_deleted += @intFromBool(exist);
            },
            .pattern => {
                var deleted: i64 = 0;
                var iterator = memory.iterator();
                while (iterator.next()) |ref| {
                    const key = ref.key();
                    if (glob.match(str, key)) {
                        memory.remove(allocator, key) catch continue;
                        deleted += 1;
                    }
                }
                total_deleted += deleted;
            },
        }
    }

    if (!limit.exceeded()) {
        const integer: Value.Integer = .fromValue(total_deleted);
        try reply.writeValue(writer, integer);
    }
}

fn cdel(
    allocator: std.mem.Allocator,
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
) Error!void {
    var limit: Quota = .init(query.flags.limit.get());

    var serializer: reply.ListSerializer = try .begin(writer);
    defer serializer.end();

    var args = query.args.iterator();
    while (args.next()) |key| {
        var frame = try serializer.beginFrame();
        defer {
            frame.end();
            limit.advance();
        }

        const result = cdelOne(allocator, memory, writer, &args, key);
        try writeOrThrow(writer, result);
    }
}

fn cdelOne(
    allocator: std.mem.Allocator,
    memory: *Memory,
    writer: *std.Io.Writer,
    args: *frames.Iterator,
    key: []const u8,
) !void {
    const ref = memory.get(key) orelse return error.KeyNotFound;
    const value_type = ref.type();
    if (value_type.group() != .collection) return error.MismatchType;

    const updated_len = switch (value_type) {
        .list => blk: {
            const list: Value.List = ref.value(.list);
            const list_len = list.count();

            const from, const to = try nextRange(args, list_len);
            try list.removeByRange(allocator, from, to);

            break :blk list.count();
        },
        .map => blk: {
            const map: Value.Map = ref.value(.map);

            var iterator = map.getKeys();
            while (iterator.next()) |map_key| {
                map.removeByKey(allocator, map_key.*) catch continue;
            }

            break :blk map.count();
        },
        // Handled earlier.
        else => unreachable,
    };

    const integer: Value.Integer = .fromValue(@intCast(updated_len));
    try reply.writeValue(writer, integer);
}

fn pop(
    allocator: std.mem.Allocator,
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
) Error!void {
    var limit: Quota = .init(query.flags.limit.get());
    assert(!limit.exceeded());

    var serializer: reply.ListSerializer = try .begin(writer);
    defer serializer.end();

    var args = query.args.iterator();
    while (args.next()) |key| {
        var frame = try serializer.beginFrame();
        defer {
            frame.end();
            limit.advance();
        }

        const result = popOne(allocator, memory, writer, &limit, key);
        try writeOrThrow(writer, result);
    }
}

fn popOne(
    allocator: std.mem.Allocator,
    memory: *Memory,
    writer: *std.Io.Writer,
    limit: *Quota,
    key: []const u8,
) !void {
    const ref = memory.get(key) orelse return error.KeyNotFound;

    switch (ref.type()) {
        inline .void, .integer, .decimal, .flag, .string, .point => |value_type| {
            try reply.writeValue(writer, ref.value(value_type));
        },
        .list => {
            const list: Value.List = ref.value(.list);
            try serializeList(writer, limit, list.get());
        },
        .map => {
            const map: Value.Map = ref.value(.map);
            try serializeMap(writer, limit, map.get());
        },
    }

    memory.remove(allocator, key) catch |err| switch (err) {
        error.KeyNotFound => unreachable,
    };
}

fn cpop(
    allocator: std.mem.Allocator,
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
) Error!void {
    var limit: Quota = .init(query.flags.limit.get());
    assert(!limit.exceeded());

    var args = query.args.iterator();

    const result = cpopOne(
        allocator,
        memory,
        writer,
        &limit,
        &args,
    );
    return writeOrThrow(writer, result);
}

fn cpopOne(
    allocator: std.mem.Allocator,
    memory: *Memory,
    writer: *std.Io.Writer,
    limit: *Quota,
    args: *frames.Iterator,
) !void {
    const key = args.next() orelse return error.MissingTokens;
    const ref = memory.get(key) orelse return error.KeyNotFound;

    const value_type = ref.type();
    if (value_type.group() != .collection) return error.MismatchType;

    switch (value_type) {
        .list => {
            const list: Value.List = ref.value(.list);

            const list_len = list.count();
            const from, const to = try nextRange(args, list_len);
            const range = try list.getByRange(from, to);

            var serializer: reply.ListSerializer = try .begin(writer);
            defer serializer.end();

            for (range, from..to + 1) |scalar, i| {
                if (limit.exceeded()) {
                    return list.removeByRange(
                        allocator,
                        i,
                        to,
                    ) catch |err| switch (err) {
                        error.RangeOverflow => unreachable,
                    };
                }

                var frame = try serializer.beginFrame();
                defer {
                    frame.end();
                    limit.advance();
                }

                try scalar.serializeToWriter(writer);
                list.removeByRange(
                    allocator,
                    from,
                    from,
                ) catch |err| switch (err) {
                    error.RangeOverflow => unreachable,
                };
            }
        },
        .map => {
            const map: Value.Map = ref.value(.map);

            var serializer: reply.ListSerializer = try .begin(writer);
            defer serializer.end();

            while (args.next()) |map_key| {
                if (limit.exceeded()) {
                    map.removeByKey(allocator, map_key) catch |err| {
                        try reply.writeError(writer, .fromError(err));
                    };
                    continue;
                }

                var frame = try serializer.beginFrame();
                defer {
                    frame.end();
                    limit.advance();
                }

                if (map.getByKey(map_key)) |scalar| {
                    try scalar.serializeToWriter(writer);
                    map.removeByKey(allocator, map_key) catch |err| switch (err) {
                        error.MapKeyNotFound => unreachable,
                    };
                } else |_| {}
            }
        },
        // Handled earlier.
        else => unreachable,
    }
}

fn count(memory: *Memory, writer: *std.Io.Writer, query: *const Query) Error!void {
    var limit: Quota = .init(query.flags.limit.get());
    assert(!limit.exceeded());

    var args = query.args.iterator();
    const str = args.next() orelse {
        return reply.writeError(writer, .missing_tokens);
    };

    const key_count: i64 = switch (glob.classify(str)) {
        .any => @intCast(memory.count()),
        .literal => @intFromBool(memory.get(str) != null),
        .pattern => blk: {
            var counted: i64 = 0;

            var iterator = memory.iterator();
            while (iterator.next()) |ref| {
                if (limit.exceeded()) break;
                defer limit.advance();

                if (glob.match(str, ref.key())) counted += 1;
            }
            break :blk counted;
        },
    };

    const integer: Value.Integer = .fromValue(key_count);
    try reply.writeValue(writer, integer);
}

fn ccount(memory: *Memory, writer: *std.Io.Writer, query: *const Query) Error!void {
    var limit: Quota = .init(query.flags.limit.get());
    assert(!limit.exceeded());

    var serializer: reply.ListSerializer = try .begin(writer);
    defer serializer.end();

    var args = query.args.iterator();
    while (args.next()) |key| {
        if (limit.exceeded()) return;

        var frame = try serializer.beginFrame();
        defer {
            frame.end();
            limit.advance();
        }

        const result = ccountOne(memory, writer, key);
        try writeOrThrow(writer, result);
    }
}

fn ccountOne(memory: *Memory, writer: *std.Io.Writer, key: []const u8) !void {
    const ref = memory.get(key) orelse return error.KeyNotFound;

    const value_type = ref.type();
    if (value_type.group() != .collection) return error.MismatchType;

    const c: i64 = switch (value_type) {
        .list => @intCast(ref.value(.list).count()),
        .map => @intCast(ref.value(.map).count()),
        // Handled earlier.
        else => unreachable,
    };

    const integer: Value.Integer = .fromValue(c);
    try reply.writeValue(writer, integer);
}

fn len(memory: *Memory, writer: *std.Io.Writer, query: *const Query) Error!void {
    var limit: Quota = .init(query.flags.limit.get());
    assert(!limit.exceeded());

    var serializer: reply.ListSerializer = try .begin(writer);
    defer serializer.end();

    var args = query.args.iterator();
    while (args.next()) |key| {
        if (limit.exceeded()) return;

        var frame = try serializer.beginFrame();
        defer {
            frame.end();
            limit.advance();
        }

        const result = lenOne(writer, &args, memory, key);
        try writeOrThrow(writer, result);
    }
}

fn lenOne(
    writer: *std.Io.Writer,
    args: *frames.Iterator,
    memory: *Memory,
    key: []const u8,
) !void {
    const ref = memory.get(key) orelse return error.KeyNotFound;

    const value_type = ref.type();
    if (value_type.group() != .collection) return error.MismatchType;

    const string_len: i64 = switch (ref.type()) {
        .string => @intCast(ref.value(.string).len()),
        .list => blk: {
            const list: Value.List = ref.value(.list);
            const list_len = list.count();

            const index = try nextIndex(args, list_len);
            const scalars = list.getByRange(index, index) catch unreachable;
            const scalar = scalars[0];

            if (scalar.type() != .string) return error.MismatchType;
            break :blk @intCast(scalar.string.len());
        },
        .map => blk: {
            const map: Value.Map = ref.value(.map);

            const map_key = args.next() orelse return error.MissingTokens;
            const scalar = try map.getByKey(map_key);

            if (scalar.type() != .string) return error.MismatchType;
            break :blk @intCast(scalar.string.len());
        },
        // Handled earlier.
        else => unreachable,
    };

    const integer: Value.Integer = .fromValue(string_len);
    try reply.writeValue(writer, integer);
}

fn set(
    allocator: std.mem.Allocator,
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
) Error!void {
    var args = query.args.iterator();

    while (args.next()) |key| {
        const result = setOne(
            allocator,
            memory,
            &args,
            key,
            query.flags.if_not_exists.get(),
        );
        try writeOrThrow(writer, result);
    }
}

fn setOne(
    allocator: std.mem.Allocator,
    memory: *Memory,
    args: *frames.Iterator,
    key: []const u8,
    if_not_exists: bool,
) !void {
    const serialized = args.next() orelse return error.MissingTokens;

    const value_type, const content = try Value.splitSerialized(serialized);
    if (value_type.group() == .collection) return error.MismatchType;

    if (if_not_exists) {
        _ = try memory.ensure(allocator, key, value_type, content);
    } else {
        _ = try memory.put(allocator, key, value_type, content);
    }
}

fn append(
    allocator: std.mem.Allocator,
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
) Error!void {
    var limit: Quota = .init(query.flags.limit.get());
    assert(!limit.exceeded());

    var serializer: reply.ListSerializer = try .begin(writer);
    defer serializer.end();

    var args = query.args.iterator();
    while (args.next()) |key| {
        if (limit.exceeded()) return;

        var frame = try serializer.beginFrame();
        defer {
            frame.end();
            limit.advance();
        }

        const result = appendOne(allocator, memory, &args, key);
        const updated_len: u64 = try valueOrThrow(writer, result) orelse continue;

        const integer: Value.Integer = .fromValue(@intCast(updated_len));
        try reply.writeValue(writer, integer);
    }
}

fn appendOne(
    allocator: std.mem.Allocator,
    memory: *Memory,
    args: *frames.Iterator,
    key: []const u8,
) !u64 {
    const er = try memory.ensure(allocator, key, .list, &.{});
    const ref = er.ref;
    defer if (!er.found_existing) memory.removeByRef(allocator, ref);

    if (ref.type() != .list) return error.MismatchType;

    const serialized = args.next() orelse return error.MissingTokens;
    const list: Value.List = ref.value(.list);
    try list.insert(allocator, list.count(), serialized);

    return list.count();
}

fn insert(
    allocator: std.mem.Allocator,
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
) Error!void {
    var limit: Quota = .init(query.flags.limit.get());
    assert(!limit.exceeded());

    var serializer: reply.ListSerializer = try .begin(writer);
    defer serializer.end();

    var args = query.args.iterator();
    while (args.next()) |key| {
        if (limit.exceeded()) return;

        var frame = try serializer.beginFrame();
        defer {
            frame.end();
            limit.advance();
        }

        const result = insertOne(
            allocator,
            memory,
            &args,
            key,
            query.flags.replace.get(),
        );
        const updated_len: u64 = try valueOrThrow(writer, result) orelse continue;

        const integer: Value.Integer = .fromValue(@intCast(updated_len));
        try reply.writeValue(writer, integer);
    }
}

fn insertOne(
    allocator: std.mem.Allocator,
    memory: *Memory,
    args: *frames.Iterator,
    key: []const u8,
    replace: bool,
) !u64 {
    const ref = memory.get(key) orelse return error.KeyNotFound;
    if (ref.type() != .list) return error.MismatchType;

    const list: Value.List = ref.value(.list);

    const list_len = list.count();
    const index = try nextIndex(args, list_len);
    const serialized = args.next() orelse return error.MissingTokens;

    if (replace) {
        try list.setByIndex(allocator, index, serialized);
    } else {
        try list.insert(allocator, index, serialized);
    }

    return list.count();
}

fn put(
    allocator: std.mem.Allocator,
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
) Error!void {
    var limit: Quota = .init(query.flags.limit.get());
    assert(!limit.exceeded());

    var serializer: reply.ListSerializer = try .begin(writer);
    defer serializer.end();

    var args = query.args.iterator();
    while (args.next()) |key| {
        if (limit.exceeded()) return;

        var frame = try serializer.beginFrame();
        defer {
            frame.end();
            limit.advance();
        }

        const result = putOne(
            allocator,
            memory,
            &args,
            key,
            query.flags.if_not_exists.get(),
        );
        const updated_len: u64 = try valueOrThrow(writer, result) orelse continue;

        const integer: Value.Integer = .fromValue(@intCast(updated_len));
        try reply.writeValue(writer, integer);
    }
}

fn putOne(
    allocator: std.mem.Allocator,
    memory: *Memory,
    args: *frames.Iterator,
    key: []const u8,
    if_not_exists: bool,
) !u64 {
    const er = try memory.ensure(allocator, key, .map, &.{});
    const ref = er.ref;
    defer if (!er.found_existing) memory.removeByRef(allocator, ref);

    if (ref.type() != .map) return error.MismatchType;

    const map_key = args.next() orelse return error.MissingTokens;
    const serialized = args.next() orelse return error.MissingTokens;

    const map: Value.Map = ref.value(.map);
    if (if_not_exists) {
        try map.ensure(allocator, map_key, serialized);
    } else {
        try map.put(allocator, map_key, serialized);
    }

    return map.count();
}

fn rename(
    allocator: std.mem.Allocator,
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
) Error!void {
    var args = query.args.iterator();

    const result = renameOne(
        allocator,
        memory,
        &args,
        query.flags.if_not_exists.get(),
    );
    return writeOrThrow(writer, result);
}

fn renameOne(
    allocator: std.mem.Allocator,
    memory: *Memory,
    args: *frames.Iterator,
    if_not_exists: bool,
) !void {
    const selected_key = args.next() orelse return error.MissingTokens;
    const new_key = args.next() orelse return error.MissingTokens;

    if (std.mem.eql(u8, selected_key, new_key)) return;

    const new_ref = memory.get(new_key);
    if (new_ref != null and if_not_exists) return error.DuplicatedKey;

    if (new_ref != null) memory.removeByRef(allocator, new_ref.?);
    const selected_ref = memory.get(selected_key) orelse return error.KeyNotFound;
    try selected_ref.setKey(allocator, new_key);
}

fn @"type"(memory: *Memory, writer: *std.Io.Writer, query: *const Query) Error!void {
    var limit: Quota = .init(query.flags.limit.get());
    assert(!limit.exceeded());

    var serializer: reply.ListSerializer = try .begin(writer);
    defer serializer.end();

    var args = query.args.iterator();
    while (args.next()) |key| {
        if (limit.exceeded()) return;

        var frame = try serializer.beginFrame();
        defer {
            frame.end();
            limit.advance();
        }

        const result = typeOne(writer, memory, key);
        try writeOrThrow(writer, result);
    }
}

fn typeOne(writer: *std.Io.Writer, memory: *Memory, key: []const u8) !void {
    const ref = memory.get(key) orelse return error.KeyNotFound;
    try reply.writeSerialized(writer, .string, @tagName(ref.type()));
}

fn ctype(memory: *Memory, writer: *std.Io.Writer, query: *const Query) Error!void {
    var limit: Quota = .init(query.flags.limit.get());
    assert(!limit.exceeded());

    var args = query.args.iterator();

    const result = ctypeOne(memory, writer, &limit, &args);
    return writeOrThrow(writer, result);
}

fn ctypeOne(memory: *Memory, writer: *std.Io.Writer, limit: *Quota, args: *frames.Iterator) !void {
    const key = args.next() orelse return error.MissingTokens;
    const ref = memory.get(key) orelse return error.KeyNotFound;

    const value_type = ref.type();
    if (value_type.group() != .collection) return error.MismatchType;

    switch (ref.type()) {
        .list => {
            const list: Value.List = ref.value(.list);

            const list_len = list.count();
            const from, const to = try nextRange(args, list_len);
            const range = try list.getByRange(from, to);

            var serializer: reply.ListSerializer = try .begin(writer);
            defer serializer.end();

            for (range) |scalar| {
                var frame = try serializer.beginFrame();
                defer {
                    frame.end();
                    limit.advance();
                }
                try reply.writeSerialized(writer, .string, @tagName(scalar.type()));
            }
        },
        .map => {
            const map: Value.Map = ref.value(.map);

            var serializer: reply.ListSerializer = try .begin(writer);
            defer serializer.end();

            while (args.next()) |map_key| {
                var frame = try serializer.beginFrame();
                defer {
                    frame.end();
                    limit.advance();
                }

                if (map.getByKey(map_key)) |scalar| {
                    try reply.writeSerialized(writer, .string, @tagName(scalar.type()));
                } else |_| {}
            }
        },
        // Handled earlier.
        else => unreachable,
    }
}

fn keys(memory: *Memory, writer: *std.Io.Writer, query: *const Query) Error!void {
    var limit: Quota = .init(query.flags.limit.get());
    assert(!limit.exceeded());

    var args = query.args.iterator();

    const result = keysOne(memory, writer, &limit, &args);
    return writeOrThrow(writer, result);
}

fn keysOne(memory: *Memory, writer: *std.Io.Writer, limit: *Quota, args: *frames.Iterator) !void {
    const pattern = args.next() orelse return error.MissingTokens;

    var serializer: reply.ListSerializer = try .begin(writer);
    defer serializer.end();

    var iterator = memory.iterator();
    while (iterator.next()) |ref| {
        if (limit.exceeded()) return;

        const key = ref.key();
        if (!glob.match(pattern, key)) continue;

        var frame = try serializer.beginFrame();
        defer {
            frame.end();
            limit.advance();
        }

        try reply.writeSerialized(writer, .string, key);
    }
}

fn copy(
    allocator: std.mem.Allocator,
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
) Error!void {
    var args = query.args.iterator();

    const result = copyOne(
        allocator,
        memory,
        &args,
        query.flags.if_not_exists.get(),
    );
    return writeOrThrow(writer, result);
}

fn copyOne(
    allocator: std.mem.Allocator,
    memory: *Memory,
    args: *frames.Iterator,
    if_not_exists: bool,
) !void {
    const src_key = args.next() orelse return error.MissingTokens;
    const dst_key = args.next() orelse return error.MissingTokens;

    return memory.copy(allocator, src_key, dst_key, if_not_exists);
}

fn valueOrThrow(
    writer: *std.Io.Writer,
    result: anytype,
) Error!?@typeInfo(@TypeOf(result)).error_union.payload {
    assert(@typeInfo(@TypeOf(result)) == .error_union);

    return result catch |err| if (err == error.OutOfMemory or err == error.WriteFailed)
        @errorCast(err)
    else {
        try reply.writeError(writer, .fromError(err));
        return null;
    };
}

fn writeOrThrow(writer: *std.Io.Writer, result: anytype) Error!void {
    assert(@typeInfo(@TypeOf(result)) == .error_union);

    return result catch |err| if (err == error.OutOfMemory or err == error.WriteFailed)
        @errorCast(err)
    else
        reply.writeError(writer, .fromError(err));
}

fn serializeMap(
    writer: *std.Io.Writer,
    limit: *Quota,
    map_iterator: Value.Map.PairIterator,
) Error!void {
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
    limit: *Quota,
    items: []const Value.Scalar,
) Error!void {
    var serializer: reply.ListSerializer = try .begin(writer);
    defer serializer.end();

    for (items) |scalar| {
        if (limit.exceeded()) return;

        var frame = try serializer.beginFrame();
        defer {
            frame.end();
            limit.advance();
        }

        try scalar.serializeToWriter(writer);
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
    return std.mem.bytesToValue(i64, content[0..@sizeOf(T)]);
}

fn resolveIndex(index: i64, length: u64) u64 {
    if (index >= 0) {
        const u_index: u64 = @intCast(index);
        return @min(u_index, length -| 1);
    }
    const signed_len: i64 = @intCast(length);
    const resolved: u64 = @intCast(signed_len + index);
    return @max(0, resolved);
}
