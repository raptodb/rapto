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

pub const Context = struct {
    writer: *std.Io.Writer,
    query: *const Query,
};

memory: *Memory,

pub fn init(memory: *Memory) Module {
    return .{ .memory = memory };
}

pub fn ping(_: Module, ctx: Context) !void {
    if (!ctx.query.flags.noreply) {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &buf, 1, .little);
        const pong: field.Integer = .init(buf);
        try Types.serializeTypeToWriter(.integer, ctx.writer);
        try pong.serializeContentToWriter(ctx.writer);
        // 0 is ping, 1 is pong, 01010! oh, pong is not received!
    }
}

pub fn get(self: Module, ctx: Context) !void {
    const key = ctx.query.args.next() orelse return error.MissingTokens;
    const ref = self.memory.search(key) orelse return error.KeyNotFound;
    if (ctx.query.flags.noreply) return;

    const field_type = ref.type();

    switch (ctx.query.flags.by) {
        .any => {
            try field_type.serializeTypeToWriter(ctx.writer);
            try ref.serializeContentToWriter(ctx.writer);
        },
        .index => |index| switch (field_type) {
            .list => {
                const item = try ref.valuePtr(.list).getByIndex(index.get());
                try item.serializeToWriter(ctx.writer);
            },
            .point => {
                const item: field.Point.Axis = try ref.valuePtr(.point).get();
                try Types.serializeTypeToWriter(.decimal, ctx.writer);
                switch (index) {
                    0 => try item.x.serializeContentToWriter(ctx.writer),
                    1 => try item.y.serializeContentToWriter(ctx.writer),
                    2 => try item.z.serializeContentToWriter(ctx.writer),
                    else => return error.RangeOverflow,
                }
            },
            else => return error.MismatchFlag,
        },
        .range => |range| switch (field_type) {
            .list => {
                try Types.serializeTypeToWriter(.list, ctx.writer);
                try ref.valuePtr(.list).serializeContentInRangeToWriter(
                    ctx.writer,
                    range.from,
                    range.to,
                );
            },
            else => return error.MismatchFlag,
        },
        .key => |flag_key| switch (field_type) {
            .map => {
                const item = try ref.valuePtr(.map).getByKey(flag_key);
                try item.serializeToWriter(ctx.writer);
            },
            .point => {
                try Types.serializeTypeToWriter(.decimal, ctx.writer);
                const item: field.Point.Axis = try ref.valuePtr(.point).get();
                switch (flag_key[0]) {
                    'x' => try item.x.serializeContentToWriter(ctx.writer),
                    'y' => try item.y.serializeContentToWriter(ctx.writer),
                    'z' => try item.z.serializeContentToWriter(ctx.writer),
                    else => return error.RangeOverflow,
                }
            },
            else => return error.MismatchFlag,
        },
    }
}

pub fn set(self: Module, ctx: Context) !void {
    const key = ctx.query.args.next() orelse return error.MissingTokens;
    const serialized_value = ctx.query.args.next() orelse return error.MissingTokens;

    const field_type, const content = try field.splitSerialized(serialized_value);

    return switch (field_type) {
        inline else => |t| self.memory.put(t, key, content),
    };
}

pub fn update(self: Module, ctx: Context) !void {
    const key = ctx.query.args.next() orelse return error.MissingTokens;
    const serialized = ctx.query.args.next() orelse return error.MissingTokens;

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
            const value: field.Point = try .init(content);
            try ref.valuePtr(.point).translate(value.get());
        },

        // these types cannot be updated
        .void, .string, .flag, .list, .map => return error.MismatchType,
    }
}

pub fn rename(self: Module, ctx: Context) !void {
    const current_key = ctx.query.args.next() orelse return error.MissingTokens;
    const new_key = ctx.query.args.next() orelse return error.MissingTokens;
    const ref = self.memory.search(current_key) orelse return error.KeyNotFound;
    try ref.setKey(new_key);
}

pub fn count(self: Module, ctx: Context) !void {
    if (!ctx.query.flags.noreply) try ctx.writer.writeInt(u64, self.memory.count(), .little);
}

pub fn @"type"(self: Module, ctx: Context) !void {
    const key = ctx.query.args.next() orelse return error.MissingTokens;

    const ref = self.memory.search(key) orelse return error.KeyNotFound;
    if (ctx.query.flags.noreply) return;

    const field_type = ref.type();
    try field_type.serializeToWriter(ctx.writer);
}

pub fn list(self: Module, ctx: Context) !void {
    if (ctx.query.flags.noreply) return;
    var iterator = self.memory.iterator();
    var first = true;

    while (iterator.next()) |ref| {
        if (!first)
            try ctx.writer.writeByte(' ');
        first = false;

        try ctx.writer.writeAll(ref.key());
    }
}

pub fn exist(self: Module, ctx: Context) !void {
    const key = ctx.query.args.next() orelse return error.MissingTokens;
    if (ctx.query.flags.noreply) return;

    const key_exist = self.memory.search(key) != null;
    return ctx.writer.writeByte(if (key_exist) 1 else 0);
}

pub fn copy(self: Module, ctx: Context) !void {
    const src_key = ctx.query.args.next() orelse return error.MissingTokens;
    const dst_key = ctx.query.args.next() orelse return error.MissingTokens;

    const ref = self.memory.search(src_key) orelse return error.KeyNotFound;

    return switch (ref.type()) {
        inline else => |f| self.memory.put(f, dst_key, try ref.field(f)),
    };
}

pub fn del(self: Module, ctx: Context) !void {
    const key = ctx.query.args.next() orelse return error.MissingTokens;
    return self.memory.remove(key);
}

pub fn erase(self: Module, ctx: Context) void {
    switch (ctx.query.flags.free) {
        true => self.memory.free(),
        false => self.memory.clear(),
    }
}
