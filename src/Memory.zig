//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of memory.

/// Main data structure of Rapto that stores
/// the key-value pairs of the database. It
/// provides safe CRUD operations to access Ref.
const Memory = @This();

const std = @import("std");
const object = @import("Memory/object.zig");
const field = @import("field.zig");

allocator: std.mem.Allocator,
/// Hashmap of items. Internal API should not be used directly.
map: Map,

pub fn init(allocator: std.mem.Allocator) Memory {
    return .{ .allocator = allocator, .map = .empty };
}

pub fn deinit(self: *Memory) void {
    var iter = self.iterator();
    while (iter.next()) |ref| {
        deinitPair(self.allocator, ref.key_ptr.*, ref.value_ptr.*);
    }
    self.map.deinit(self.allocator);
}

pub const PutError = error{
    InvalidKey,
    InvalidFormat,
    MismatchType,
    UnknownType,
} || std.mem.Allocator.Error;

pub fn put(
    self: *Memory,
    key: []const u8,
    field_type: field.Type,
    content: []const u8,
) PutError!object.Ref {
    const entry = try self.map.getOrPutAdapted(
        self.allocator,
        key,
        SearchContext{},
    );

    const ref: object.Ref = .wrap(entry.key_ptr, entry.value_ptr);

    if (entry.found_existing) {
        try ref.setValue(self.allocator, field_type, content);
    } else {
        errdefer self.map.removeByPtr(entry.key_ptr);

        entry.key_ptr.*, entry.value_ptr.* = try initPair(
            self.allocator,
            key,
            field_type,
            content,
        );
    }

    return ref;
}

pub fn search(self: *Memory, key: []const u8) ?object.Ref {
    if (self.map.count() == 0) return null;

    const entry = self.map.getEntryAdapted(key, SearchContext{}) orelse return null;
    return .wrap(entry.key_ptr, entry.value_ptr);
}

/// Removes key from memory. Associated object.Ref will be invalidated.
pub fn remove(self: *Memory, key: []const u8) error{KeyNotFound}!void {
    const ref = self.search(key) orelse return error.KeyNotFound;
    self.map.removeByPtr(ref.key_ptr);
    deinitPair(self.allocator, ref.key_ptr.*, ref.value_ptr.*);
}

pub fn count(self: *const Memory) u64 {
    return self.map.count();
}

pub fn clear(self: *Memory) void {
    var iter = self.iterator();
    while (iter.next()) |ref| {
        deinitPair(self.allocator, ref.key_ptr.*, ref.value_ptr.*);
    }

    self.map.clearRetainingCapacity();
}

pub fn free(self: *Memory) void {
    var iter = self.iterator();
    while (iter.next()) |ref| {
        deinitPair(self.allocator, ref.key_ptr.*, ref.value_ptr.*);
    }

    self.map.clearAndFree(self.allocator);
}

pub const Iterator = struct {
    memory: *Memory,
    wrapped_iterator: Map.Iterator,

    pub fn init(memory: *Memory, wrapped_iterator: Map.Iterator) Iterator {
        return .{ .memory = memory, .wrapped_iterator = wrapped_iterator };
    }

    pub fn next(self: *Iterator) ?object.Ref {
        const entry = self.wrapped_iterator.next() orelse return null;
        return .wrap(entry.key_ptr, entry.value_ptr);
    }

    pub fn skip(self: *Iterator) void {
        _ = self.wrapped_iterator.next();
    }
};

pub fn iterator(self: *Memory) Iterator {
    return .init(self, self.map.iterator());
}

const SearchContext = struct {
    pub fn hash(_: @This(), s: []const u8) u64 {
        return std.hash.Wyhash.hash(0, s);
    }
    pub fn eql(_: @This(), a: []const u8, b: object.Key) bool {
        return b.isEqualTo(a);
    }
};

const PutContext = struct {
    pub fn hash(_: @This(), s: object.Key) u64 {
        return (SearchContext{}).hash(s.get());
    }
    pub fn eql(_: @This(), a: object.Key, b: object.Key) bool {
        const lhs = a.ptr.getPointer();
        const rhs = b.ptr.getPointer();

        var i: u64 = 0;
        while (lhs[i] == rhs[i] and lhs[i] != 0) i += 1;
        return lhs[i] == rhs[i];
    }
};

const Map = std.HashMapUnmanaged(
    object.Key,
    object.Field,
    PutContext,
    65,
);

fn initPair(
    allocator: std.mem.Allocator,
    key: []const u8,
    field_type: field.Type,
    content: []const u8,
) PutError!struct { object.Key, object.Field } {
    const pair_key: object.Key = try .init(allocator, key, field_type);
    errdefer pair_key.deinit(allocator);
    const pair_value: object.Field = try .init(allocator, field_type, content);

    return .{ pair_key, pair_value };
}

fn deinitPair(allocator: std.mem.Allocator, key: object.Key, value: object.Field) void {
    key.deinit(allocator);
    value.deinit(allocator, key.getFieldType());
}
