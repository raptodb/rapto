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
    if (query.flags.noreply.get()) return;

    const item: field.Integer = .initFromValue(1);
    try field.serializeToWriter(self.writer, .integer, item.getContent());
}

pub fn get(self: Module, query: *Query) !void {
    if (query.flags.noreply.get()) return;

    const key = query.args.next() orelse return error.MissingTokens;
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
                try Types.serializeTypeToWriter(.decimal, self.writer);
                const item: field.Point.Axis = ref.valuePtr(.point).value.*;
                if (flag_key.get().len != 1) return error.MismatchFlag;
                switch (flag_key.get()[0]) {
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
    if (query.flags.noreply.get()) return;

    const item: field.Integer = .initFromValue(self.memory.count());
    try field.serializeToWriter(self.writer, .integer, item.getContent());
}

pub fn @"type"(self: Module, query: *Query) !void {
    if (query.flags.noreply.get()) return;

    const key = query.args.next() orelse return error.MissingTokens;
    const ref = self.memory.search(key) orelse return error.KeyNotFound;

    return ref.type().serializeToWriter(self.writer);
}

pub fn list(self: Module, query: *Query) !void {
    if (query.flags.noreply.get()) return;

    var iterator = self.memory.iterator();
    while (iterator.next()) |ref| {
        const key = ref.key();
        // Since key is not a scalar/collection field, is written
        // manually with length header of 4 bytes.
        try self.writer.writeInt(u32, key.len, .little);
        try self.writer.writeAll(key);
    }
}

pub fn exist(self: Module, query: *Query) !void {
    if (query.flags.noreply.get()) return;

    const key = query.args.next() orelse return error.MissingTokens;

    const key_exist = self.memory.search(key) != null;

    const item: field.Flag = if (key_exist) .initFromValue(.true) else .initFromValue(.false);
    try field.serializeToWriter(self.writer, .integer, item.getContent());
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
    switch (query.flags.free.get()) {
        true => self.memory.free(),
        false => self.memory.clear(),
    }
}
