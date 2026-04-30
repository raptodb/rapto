//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of query executor.

/// Query executor on Memory instance.
const StateMachine = @This();

const std = @import("std");
const code = @import("code.zig");
const field = @import("field.zig");
const assert = std.debug.assert;

const Types = field.Types;
const Memory = @import("Memory.zig");
const Query = @import("Task.zig").Query;

memory: *Memory,

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

pub fn init(
    memory: *Memory, // Storage of state
) StateMachine {
    return .{ .memory = memory };
}

/// Executes query on this configuration. Fatal errors will be returned
/// directly instead of Dispatch errors, these will be written on writer.
/// If no error is occurred, writes OK code to output.
pub fn execute(
    self: StateMachine,
    writer: *std.Io.Writer, // Output: maybe Allocating
    query: *const Query, // Input
) FatalError!void {
    const start_offset = writer.end;

    // zig fmt: off
    const maybe_error: (FatalError || CommandError)!void = switch (query.command) {
        .PING   => self.ping(writer, query),

        // CRUD operations
        .SET    => self.set(query),
        .GET    => self.get(writer, query),
        .UPDATE => self.update(query),
        .DEL    => self.del(query),

        .COPY   => self.copy(query),
        .RENAME => self.rename(query),
        .COUNT  => self.count(writer, query),
        .TYPE   => self.type(writer, query),
        .LIST   => self.list(writer, query),
        .EXIST  => self.exist(writer, query),
        .ERASE  => self.erase(query),

        .DOWN   => error.Shutdown,
    };
    // zig fmt: on

    var status_code: code.Code = .OK;

    maybe_error catch |err| switch (err) {
        else => status_code = code.fromCommandError(@errorCast(err)),
        // Fatal errors are returned directly and handled outside.
        error.OutOfMemory,
        error.WriteFailed,
        error.Shutdown,
        => |e| {
            @branchHint(.cold);
            return e;
        },
    };

    // When response is written in buffer, it is an implicit OK.
    // While, when noreply is enabled, response is not written.
    if (writer.end == start_offset and !query.flags.noreply.get()) {
        return code.writeCode(writer, status_code);
    }
}

fn ping(_: StateMachine, writer: *std.Io.Writer, query: *const Query) !void {
    if (query.flags.noreply.get()) return;

    const item: field.Integer = .fromValue(1);
    const scalar: field.ScalarItem = .{ .integer = item };
    try scalar.serializeToWriter(writer);
}

fn get(self: StateMachine, writer: *std.Io.Writer, query: *const Query) !void {
    var args = query.args;

    if (query.flags.noreply.get()) return;

    const key = args.next() orelse return error.MissingTokens;
    const ref = self.memory.search(key) orelse return error.KeyNotFound;

    const field_type = ref.type();

    switch (query.flags.by.get()) {
        .any => try ref.serializeToWriter(writer),
        .index => |index| switch (field_type) {
            .list => {
                const item = try ref.valuePtr(.list).getByIndex(index.get());
                try item.serializeToWriter(writer);
            },
            .point => {
                const item: field.Point.Axis = ref.valuePtr(.point).get();
                const axis = switch (index.get()) {
                    0 => item.x,
                    1 => item.y,
                    2 => item.z,
                    else => return error.RangeOverflow,
                };
                const scalar: field.ScalarItem = .{ .decimal = axis };
                try scalar.serializeToWriter(writer);
            },
            else => return error.MismatchFlag,
        },
        .range => |range| switch (field_type) {
            .list => {
                try Types.serializeToWriter(.list, writer);
                try ref.valuePtr(.list).serializeContentInRangeToWriter(
                    writer,
                    range.from().get(),
                    range.to().get(),
                );
            },
            else => return error.MismatchFlag,
        },
        .key => |flag_key| switch (field_type) {
            .map => {
                const item = try ref.valuePtr(.map).getByKey(flag_key.get());
                try item.serializeToWriter(writer);
            },
            .point => {
                const item: field.Point.Axis = ref.valuePtr(.point).get();

                if (flag_key.get().len != 1) return error.MismatchFlag;
                const axis = switch (flag_key.get()[0]) {
                    'x' => item.x,
                    'y' => item.y,
                    'z' => item.z,
                    else => return error.RangeOverflow,
                };

                const scalar: field.ScalarItem = .{ .decimal = axis };
                try scalar.serializeToWriter(writer);
            },
            else => return error.MismatchFlag,
        },
    }
}

fn set(self: StateMachine, query: *const Query) !void {
    var args = query.args;

    const key = args.next() orelse return error.MissingTokens;
    const serialized_value = args.next() orelse return error.MissingTokens;

    const field_type, const content = try field.splitSerialized(serialized_value);

    _ = switch (field_type) {
        inline else => |t| try self.memory.put(key, t, content),
    };
}

fn update(self: StateMachine, query: *const Query) !void {
    var args = query.args;

    const key = args.next() orelse return error.MissingTokens;
    const serialized = args.next() orelse return error.MissingTokens;

    const field_type, const content = try field.splitSerialized(serialized);
    const ref = self.memory.search(key) orelse return error.KeyNotFound;

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
            const value: field.Point = try .fromContent(self.memory.allocator, content);
            try ref.valuePtr(.point).translate(value.get());
        },
        .void, .string, .flag, .list, .map => return error.MismatchType,
    }
}

fn rename(self: StateMachine, query: *const Query) !void {
    var args = query.args;

    const current_key = args.next() orelse return error.MissingTokens;
    const new_key = args.next() orelse return error.MissingTokens;

    const ref = self.memory.search(current_key) orelse return error.KeyNotFound;
    try ref.setKey(self.memory.allocator, new_key);
}

fn count(self: StateMachine, writer: *std.Io.Writer, query: *const Query) !void {
    if (query.flags.noreply.get()) return;

    // Keys will never be a number larger than the maximum range of i64.
    const key_count: i64 = @intCast(self.memory.count());
    const item: field.Integer = .fromValue(key_count);
    const scalar: field.ScalarItem = .{ .integer = item };
    try scalar.serializeToWriter(writer);
}

fn @"type"(self: StateMachine, writer: *std.Io.Writer, query: *const Query) !void {
    var args = query.args;

    if (query.flags.noreply.get()) return;

    const key = args.next() orelse return error.MissingTokens;
    const ref = self.memory.search(key) orelse return error.KeyNotFound;

    return ref.type().serializeToWriter(writer);
}

fn list(self: StateMachine, writer: *std.Io.Writer, query: *const Query) !void {
    if (query.flags.noreply.get()) return;

    var iterator = self.memory.iterator();
    while (iterator.next()) |ref| {
        const key = ref.key();
        // Since key is not a scalar/collection field, is written
        // manually with length header of 4 bytes.
        try writer.writeInt(u32, @truncate(key.len), .little);
        try writer.writeAll(key);
    }
}

fn exist(self: StateMachine, writer: *std.Io.Writer, query: *const Query) !void {
    var args = query.args;

    if (query.flags.noreply.get()) return;

    const key = args.next() orelse return error.MissingTokens;

    const key_exist = self.memory.search(key) != null;

    const item: field.Flag = if (key_exist) .fromValue(.true) else .fromValue(.false);
    const scalar: field.ScalarItem = .{ .flag = item };
    try scalar.serializeToWriter(writer);
}

fn copy(self: StateMachine, query: *const Query) !void {
    var args = query.args;

    const src_key = args.next() orelse return error.MissingTokens;
    const dst_key = args.next() orelse return error.MissingTokens;

    const ref = self.memory.search(src_key) orelse return error.KeyNotFound;
    const field_type = ref.type();

    var content_allocating: std.Io.Writer.Allocating = .init(self.memory.allocator);
    defer content_allocating.deinit();
    try ref.serializeContentToWriter(&content_allocating.writer);

    const content = content_allocating.written();

    _ = switch (field_type) {
        inline else => |t| try self.memory.put(dst_key, t, content),
    };
}

fn del(self: StateMachine, query: *const Query) !void {
    var args = query.args;

    const key = args.next() orelse return error.MissingTokens;
    return self.memory.remove(key);
}

fn erase(self: StateMachine, query: *const Query) void {
    switch (query.flags.free.get()) {
        true => self.memory.free(),
        false => self.memory.clear(),
    }
}
