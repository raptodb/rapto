//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of query executor.

const std = @import("std");
const code = @import("code.zig");
const frames = @import("frames.zig");
const field = Memory.field;
const object = Memory.object;
const assert = std.debug.assert;

const Memory = @import("Memory.zig");
const Query = @import("Task.zig").Query;
const Flags = Query.Flags;

pub const FatalError = error{
    // When command received from execute is DOWN
    Shutdown,
} || std.mem.Allocator.Error || std.Io.Writer.Error;

/// Union of all errors can be returned from any
/// functions of commands. Fatal errors as Shutdown
/// or OutOfMemory (as WriteFailed assuming writer
/// is from Allocating) are excluded.
pub const CommandError = error{
    KeyNotFound,
    InvalidKey,
    InvalidFormat,
    MissingTokens,
    MismatchType,
    UnknownType,
    MismatchFlag,
    MathOverflow,
    RangeOverflow,
    MapKeyNotFound,
};

/// Executes query on this configuration. Fatal errors will be returned
/// directly instead of Dispatch errors, these will be written on writer.
/// If no error is occurred, writes OK code to output.
pub fn execute(
    allocator: std.mem.Allocator,
    memory: *Memory, // Storage of state
    writer: *std.Io.Writer, // Output: maybe Allocating
    query: *const Query, // Input
) FatalError!void {
    const start_offset = writer.end;

    // zig fmt: off
    const maybe_error = switch (query.command) {
        .set    => set(allocator, memory, query),
        .update => update(memory, query),
        .del    => del(allocator, memory, query),
        .copy   => copy(allocator, memory, query),
        .rename => rename(allocator, memory, query),
        .erase  => erase(allocator, memory, query),
        
        inline else => |write_command| err: {
            if (query.flags.noreply.get()) return;

            break :err switch (write_command) {
                .ping  => ping(writer, query),
                .get   => get(memory, writer, query),
                .count => count(memory, writer, query),
                .type  => @"type"(memory, writer, query),
                .list  => list(memory, writer, query),
                .exist => exist(memory, writer, query),

                // Handled earlier.
                else => unreachable,
            };
        },

        .down => error.Shutdown,
    };
    // zig fmt: on

    var status_code: code.Code = .OK;
    maybe_error catch |err| {
        @branchHint(.cold);
        switch (err) {
            // Fatal errors are returned directly and handled outside.
            error.OutOfMemory,
            error.WriteFailed,
            error.Shutdown,
            => |e| return e,
            else => {
                status_code = code.fromCommandError(@errorCast(err));
            },
        }
    };

    // When response is written in buffer, it is an implicit OK.
    // While, when noreply is enabled, response is not written.
    if (writer.end == start_offset and !query.flags.noreply.get()) {
        return code.writeCode(writer, status_code);
    }
}

fn ping(
    writer: *std.Io.Writer,
    query: *const Query,
) !void {
    assert(!query.flags.noreply.get());

    const integer: field.Integer = .fromValue(1);
    try field.Type.serializeToWriter(.integer, writer);
    try integer.serializeContentToWriter(writer);
}

fn get(
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
) !void {
    assert(!query.flags.noreply.get());

    var args = query.argsIterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = memory.search(key) orelse return error.KeyNotFound;

    return switch (query.flags.by.get()) {
        .any => ref.serializeToWriter(writer),
        .index => |index| getByIndex(ref, writer, index),
        .range => |range| getByRange(ref, writer, range),
        .key => |flag_key| getByKey(ref, writer, flag_key),
    };
}

fn getByIndex(ref: object.Ref, writer: *std.Io.Writer, index: Flags.Unsigned) !void {
    return switch (ref.type()) {
        .list => {
            const item = try ref.valuePtr(.list).getByIndex(index.get());
            try item.serializeToWriter(writer);
        },
        .point => {
            const axis = ref.valuePtr(.point).get();
            const decimal = switch (index.get()) {
                0 => axis.x,
                1 => axis.y,
                2 => axis.z,
                else => return error.RangeOverflow,
            };
            try field.Type.serializeToWriter(.decimal, writer);
            try decimal.serializeContentToWriter(writer);
        },
        else => error.MismatchFlag,
    };
}

fn getByRange(ref: object.Ref, writer: *std.Io.Writer, range: Flags.Range) !void {
    return switch (ref.type()) {
        .list => {
            try field.Type.serializeToWriter(.list, writer);
            try ref.valuePtr(.list).serializeContentInRangeToWriter(
                writer,
                range.from().get(),
                range.to().get(),
            );
        },
        else => error.MismatchFlag,
    };
}

fn getByKey(ref: object.Ref, writer: *std.Io.Writer, key: Flags.String) !void {
    return switch (ref.type()) {
        .map => {
            const item = try ref.valuePtr(.map).getByKey(key.get());
            try item.serializeToWriter(writer);
        },
        .point => {
            const axis = ref.valuePtr(.point).get();
            if (key.get().len != 1) return error.MismatchFlag;
            const decimal = switch (key.get()[0]) {
                'x' => axis.x,
                'y' => axis.y,
                'z' => axis.z,
                else => return error.RangeOverflow,
            };
            try field.Type.serializeToWriter(.decimal, writer);
            try decimal.serializeContentToWriter(writer);
        },
        else => error.MismatchFlag,
    };
}

fn set(
    allocator: std.mem.Allocator,
    memory: *Memory,
    query: *const Query,
) !void {
    var args = query.argsIterator();

    const key = args.next() orelse return error.MissingTokens;
    const serialized_value = args.next() orelse return error.MissingTokens;

    const field_type, const content = try field.splitSerialized(serialized_value);

    _ = try memory.put(allocator, key, field_type, content);
}

fn update(
    memory: *Memory,
    query: *const Query,
) !void {
    var args = query.argsIterator();

    const key = args.next() orelse return error.MissingTokens;
    const serialized = args.next() orelse return error.MissingTokens;

    const field_type, const content = try field.splitSerialized(serialized);
    const ref = memory.search(key) orelse return error.KeyNotFound;

    if (field_type != ref.type()) return error.MismatchType;

    switch (field_type) {
        .integer => {
            const value: field.Integer = try .fromContent(content);
            try ref.valuePtr(.integer).add(value.get());
        },
        .decimal => {
            const value: field.Decimal = try .fromContent(content);
            try ref.valuePtr(.decimal).add(value.get());
        },
        .point => {
            const value: field.Point.Axis = try .parse(content);
            try ref.valuePtr(.point).translate(value);
        },
        .void, .string, .flag, .list, .map => return error.MismatchType,
    }
}

fn rename(
    allocator: std.mem.Allocator,
    memory: *Memory,
    query: *const Query,
) !void {
    var args = query.argsIterator();

    const current_key = args.next() orelse return error.MissingTokens;
    const new_key = args.next() orelse return error.MissingTokens;

    const ref = memory.search(current_key) orelse return error.KeyNotFound;
    try ref.setKey(allocator, new_key);
}

fn count(
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
) !void {
    assert(!query.flags.noreply.get());

    // Keys will never be a number larger than the maximum range of i64.
    const key_count: i64 = @intCast(memory.count());
    const integer: field.Integer = .fromValue(key_count);
    try field.Type.serializeToWriter(.integer, writer);
    try integer.serializeContentToWriter(writer);
}

fn @"type"(
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
) !void {
    assert(!query.flags.noreply.get());

    var args = query.argsIterator();

    const key = args.next() orelse return error.MissingTokens;
    const ref = memory.search(key) orelse return error.KeyNotFound;

    return ref.type().serializeToWriter(writer);
}

fn list(
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
) !void {
    assert(!query.flags.noreply.get());

    var iterator = memory.iterator();
    while (iterator.next()) |ref| {
        var builder: frames.Builder = try .begin(writer);
        defer builder.end();
        try writer.writeAll(ref.key());
    }
}

fn exist(
    memory: *Memory,
    writer: *std.Io.Writer,
    query: *const Query,
) !void {
    assert(!query.flags.noreply.get());

    var args = query.argsIterator();

    const key = args.next() orelse return error.MissingTokens;
    const key_exist = memory.search(key) != null;

    const flag: field.Flag = if (key_exist) .fromValue(.true) else .fromValue(.false);
    try field.Type.serializeToWriter(.flag, writer);
    try flag.serializeContentToWriter(writer);
}

fn copy(
    allocator: std.mem.Allocator,
    memory: *Memory,
    query: *const Query,
) !void {
    var args = query.argsIterator();

    const src_key = args.next() orelse return error.MissingTokens;
    const dst_key = args.next() orelse return error.MissingTokens;

    const ref = memory.search(src_key) orelse return error.KeyNotFound;
    const field_type = ref.type();

    var content_allocating: std.Io.Writer.Allocating = .init(allocator);
    defer content_allocating.deinit();
    try ref.serializeContentToWriter(&content_allocating.writer);

    const content = content_allocating.written();

    _ = try memory.put(allocator, dst_key, field_type, content);
}

fn del(
    allocator: std.mem.Allocator,
    memory: *Memory,
    query: *const Query,
) !void {
    var args = query.argsIterator();

    const key = args.next() orelse return error.MissingTokens;
    return memory.remove(allocator, key);
}

fn erase(
    allocator: std.mem.Allocator,
    memory: *Memory,
    query: *const Query,
) void {
    switch (query.flags.free.get()) {
        true => memory.free(allocator),
        false => memory.clear(allocator),
    }
}
