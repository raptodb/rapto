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
writer: *std.Io.Writer,

/// Union of all errors can be returned
/// from any functions of commands.
pub const Error = error{
    KeyNotFound,
    InvalidKey,
    InvalidFormat,
    MissingTokens,
    MismatchType,
    UnknownType,
    MismatchFlag,
    MathOverflow,
    RangeOverflow,
};

pub fn init(
    memory: *Memory, // Storage of state
    writer: *std.Io.Writer, // Output: maybe Allocating
) StateMachine {
    return .{ .memory = memory, .writer = writer };
}

/// Executes query on this configuration. Fatal errors will be returned
/// directly instead of Dispatch errors, these will be written on writer.
/// If no error is occurred, writes OK code to output.
pub fn execute(
    self: StateMachine,
    query: *const Query, // Input
) error{ OutOfMemory, Shutdown, WriteFailed }!void {
    const start_offset = self.writer.end;

    // zig fmt: off
    const maybe_error = switch (query.command) {
        .PING   => self.ping(query),

        // CRUD operations
        .SET    => self.set(query),
        .GET    => self.get(query),
        .UPDATE => self.update(query),
        .DEL    => self.del(query),

        .COPY   => self.copy(query),
        .RENAME => self.rename(query),
        .COUNT  => self.count(query),
        .TYPE   => self.type(query),
        .LIST   => self.list(query),
        .EXIST  => self.exist(query),
        .ERASE  => self.erase(query),

        .DOWN   => error.Shutdown,
    };
    // zig fmt: on

    var status_code: code.Code = .OK;

    maybe_error catch |err| switch (err) {
        else => status_code = code.fromExecuteError(@errorCast(err)),
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
    if (self.writer.end == start_offset and !query.flags.noreply.get()) {
        return code.writeCode(self.writer, status_code);
    }
}

fn ping(self: StateMachine, query: *const Query) !void {
    if (query.flags.noreply.get()) return;

    const item: field.Integer = .initFromValue(1);
    try field.serializeToWriter(self.writer, .integer, item.getContent());
}

fn get(self: StateMachine, query: *const Query) !void {
    var args = query.args;

    if (query.flags.noreply.get()) return;

    const key = args.next() orelse return error.MissingTokens;
    const ref = self.memory.search(key) orelse return error.KeyNotFound;

    const field_type = ref.type();

    switch (query.flags.by.get()) {
        .any => try ref.serializeToWriter(self.writer),
        .index => |index| switch (field_type) {
            .list => {
                const item = try ref.valuePtr(.list).getByIndex(index.get());
                try item.serializeToWriter(self.writer);
            },
            .point => {
                const item: field.Point.Axis = ref.valuePtr(.point).get();
                const content = switch (index.get()) {
                    0 => item.x.getContent(),
                    1 => item.y.getContent(),
                    2 => item.z.getContent(),
                    else => return error.RangeOverflow,
                };

                try field.serializeToWriter(self.writer, field_type, content);
            },
            else => return error.MismatchFlag,
        },
        .range => |range| switch (field_type) {
            .list => {
                try Types.serializeToWriter(.list, self.writer);
                try ref.valuePtr(.list).serializeContentInRangeToWriter(
                    self.writer,
                    range.from().get(),
                    range.to().get(),
                );
            },
            else => return error.MismatchFlag,
        },
        .key => |flag_key| switch (field_type) {
            .map => {
                const item = try ref.valuePtr(.map).getByKey(flag_key.get());
                try item.serializeToWriter(self.writer);
            },
            .point => {
                const item: field.Point.Axis = ref.valuePtr(.point).get();

                if (flag_key.get().len != 1) return error.MismatchFlag;
                const content = switch (flag_key.get()[0]) {
                    'x' => item.x.getContent(),
                    'y' => item.y.getContent(),
                    'z' => item.z.getContent(),
                    else => return error.RangeOverflow,
                };

                try field.serializeToWriter(self.writer, field_type, content);
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
            const value: field.Integer = try .initFromContent(content);
            try ref.valuePtr(.integer).add(value.get());
        },
        .decimal => {
            const value: field.Decimal = try .initFromContent(content);
            try ref.valuePtr(.decimal).add(value.get());
        },
        .point => {
            const value: field.Point = try .initFromContent(self.memory.allocator, content);
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

fn count(self: StateMachine, query: *const Query) !void {
    if (query.flags.noreply.get()) return;

    // Keys will never be a number larger than the maximum range of i64.
    const key_count: i64 = @intCast(self.memory.count());
    const item: field.Integer = .initFromValue(key_count);
    try field.serializeToWriter(self.writer, .integer, item.getContent());
}

fn @"type"(self: StateMachine, query: *const Query) !void {
    var args = query.args;

    if (query.flags.noreply.get()) return;

    const key = args.next() orelse return error.MissingTokens;
    const ref = self.memory.search(key) orelse return error.KeyNotFound;

    return ref.type().serializeToWriter(self.writer);
}

fn list(self: StateMachine, query: *const Query) !void {
    if (query.flags.noreply.get()) return;

    var iterator = self.memory.iterator();
    while (iterator.next()) |ref| {
        const key = ref.key();
        // Since key is not a scalar/collection field, is written
        // manually with length header of 4 bytes.
        try self.writer.writeInt(u32, @truncate(key.len), .little);
        try self.writer.writeAll(key);
    }
}

fn exist(self: StateMachine, query: *const Query) !void {
    var args = query.args;

    if (query.flags.noreply.get()) return;

    const key = args.next() orelse return error.MissingTokens;

    const key_exist = self.memory.search(key) != null;

    const item: field.Flag = if (key_exist) .initFromValue(.true) else .initFromValue(.false);
    try field.serializeToWriter(self.writer, .integer, item.getContent());
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
