//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of module.

const std = @import("std");
const field = @import("../field.zig");

const Types = field.Types;
const Query = @import("../Task.zig").Query;
const Memory = @import("../Memory.zig");
const Module = @This();

memory: *Memory,
writer: *std.Io.Writer,

pub fn init(memory: *Memory, writer: *std.Io.Writer) Module {
    return .{ .memory = memory, .writer = writer };
}

pub fn ping(self: Module, query: *Query) !void {
    if (!query.flags.noreply) {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &buf, 1, .little);
        const pong: field.Integer = try .init(&buf);
        try Types.serializeTypeToWriter(.integer, self.writer);
        try pong.serializeContentToWriter(self.writer);
    }
}

pub fn get(self: Module, query: *Query) !void {
    const key = query.args.next() orelse return error.MissingTokens;
    const ref = self.memory.search(key) orelse return error.KeyNotFound;
    if (query.flags.noreply) return;

    const field_type = ref.type();

    switch (query.flags.by) {
        .any => {
            try field_type.serializeTypeToWriter(self.writer);
            try ref.serializeContentToWriter(self.writer);
        },
        .index => |index| switch (field_type) {
            .list => {
                const item = try ref.valuePtr(.list).getByIndex(index);
                try item.serializeToWriter(self.writer);
            },
            .point => {
                const item: field.Point.Axis = ref.valuePtr(.point).get();
                try Types.serializeTypeToWriter(.decimal, self.writer);
                switch (index) {
                    0 => try item.x.serializeContentToWriter(self.writer),
                    1 => try item.y.serializeContentToWriter(self.writer),
                    2 => try item.z.serializeContentToWriter(self.writer),
                    else => return error.RangeOverflow,
                }
            },
            else => return error.MismatchFlag,
        },
        .range => |range| switch (field_type) {
            .list => {
                try Types.serializeTypeToWriter(.list, self.writer);
                try ref.valuePtr(.list).serializeContentInRangeToWriter(
                    self.writer,
                    range.from,
                    range.to,
                );
            },
            else => return error.MismatchFlag,
        },
        .key => |flag_key| switch (field_type) {
            .map => {
                const item = try ref.valuePtr(.map).getByKey(flag_key);
                try item.serializeToWriter(self.writer);
            },
            .point => {
                try Types.serializeTypeToWriter(.decimal, self.writer);
                const item: field.Point.Axis = ref.valuePtr(.point).value.*;
                switch (flag_key[0]) {
                    'x' => try item.x.serializeContentToWriter(self.writer),
                    'y' => try item.y.serializeContentToWriter(self.writer),
                    'z' => try item.z.serializeContentToWriter(self.writer),
                    else => return error.RangeOverflow,
                }
            },
            else => return error.MismatchFlag,
        },
    }
}

pub fn set(self: Module, query: *Query) !void {
    const key = query.args.next() orelse return error.MissingTokens;
    const serialized_value = query.args.next() orelse return error.MissingTokens;

    const field_type, const content = try field.splitSerialized(serialized_value);

    _ = switch (field_type) {
        inline else => |t| try self.memory.put(key, t, content),
    };
}

pub fn update(self: Module, query: *Query) !void {
    const key = query.args.next() orelse return error.MissingTokens;
    const serialized = query.args.next() orelse return error.MissingTokens;

    const field_type, const content = try field.splitSerialized(serialized);
    const ref = self.memory.search(key) orelse return error.KeyNotFound;

    if (field_type != ref.type()) return error.MismatchType;

    switch (field_type) {
        .integer => {
            const value: field.Integer = try .init(content);
            try ref.valuePtr(.integer).add(value.get());
        },
        .decimal => {
            const value: field.Decimal = try .init(content);
            try ref.valuePtr(.decimal).add(value.get());
        },
        .point => {
            const value: field.Point = try .init(self.memory.allocator, content);
            try ref.valuePtr(.point).translate(value.get());
        },
        .void, .string, .flag, .list, .map => return error.MismatchType,
    }
}

pub fn rename(self: Module, query: *Query) !void {
    const current_key = query.args.next() orelse return error.MissingTokens;
    const new_key = query.args.next() orelse return error.MissingTokens;

    const ref = self.memory.search(current_key) orelse return error.KeyNotFound;
    try ref.setKey(self.memory.allocator, new_key);
}

pub fn count(self: Module, query: *Query) !void {
    if (!query.flags.noreply)
        try self.writer.writeInt(u64, self.memory.count(), .little);
}

pub fn @"type"(self: Module, query: *Query) !void {
    const key = query.args.next() orelse return error.MissingTokens;
    const ref = self.memory.search(key) orelse return error.KeyNotFound;
    if (query.flags.noreply) return;

    return ref.type().serialize_type_to_writer(self.writer);
}

pub fn list(self: Module, query: *Query) !void {
    if (query.flags.noreply) return;

    var iterator = self.memory.iterator();
    var first = true;

    while (iterator.next()) |ref| {
        if (!first)
            try self.writer.writeByte(' ');
        first = false;

        try self.writer.writeAll(ref.key());
    }
}

pub fn exist(self: Module, query: *Query) !void {
    const key = query.args.next() orelse return error.MissingTokens;
    if (query.flags.noreply) return;

    const key_exist = self.memory.search(key) != null;
    try self.writer.writeByte(if (key_exist) 1 else 0);
}

pub fn copy(self: Module, query: *Query) !void {
    const src_key = query.args.next() orelse return error.MissingTokens;
    const dst_key = query.args.next() orelse return error.MissingTokens;

    const ref = self.memory.search(src_key) orelse return error.KeyNotFound;

    _ = dst_key;
    _ = ref;
    @panic("unimplemented");
}

pub fn del(self: Module, query: *Query) !void {
    const key = query.args.next() orelse return error.MissingTokens;
    return self.memory.remove(key);
}

pub fn erase(self: Module, query: *Query) void {
    switch (query.flags.free) {
        true => self.memory.free(),
        false => self.memory.clear(),
    }
}
