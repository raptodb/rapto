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

pub const object = @import("Memory/object.zig");

/// Hashmap of items. Internal API
/// should not be used directly.
map: Map,

pub const init: Memory = .{ .map = .empty };

pub fn deinit(self: *Memory, allocator: std.mem.Allocator) void {
    self.clear(allocator);
    self.map.deinit(allocator);
}

pub const PutError = error{
    InvalidKey,
    InvalidFormat,
    MismatchType,
    UnknownType,
} || std.mem.Allocator.Error;

pub fn put(
    self: *Memory,
    allocator: std.mem.Allocator,
    key: []const u8,
    value_type: object.value.Type,
    content: []const u8,
) PutError!object.Ref {
    const entry = try self.map.getOrPutAdapted(
        allocator,
        key,
        SearchContext{},
    );

    const ref: object.Ref = .wrap(entry.key_ptr, entry.value_ptr);

    if (entry.found_existing) {
        try ref.setValue(allocator, value_type, content);
    } else {
        errdefer self.map.removeByPtr(entry.key_ptr);

        entry.key_ptr.*, entry.value_ptr.* = try initPair(
            allocator,
            key,
            value_type,
            content,
        );
    }

    return ref;
}

pub fn search(self: *Memory, key: []const u8) ?object.Ref {
    const entry = self.map.getEntryAdapted(key, SearchContext{}) orelse return null;
    return .wrap(entry.key_ptr, entry.value_ptr);
}

/// Removes key from memory. Associated object.Ref will be invalidated.
pub fn remove(
    self: *Memory,
    allocator: std.mem.Allocator,
    key: []const u8,
) error{KeyNotFound}!void {
    const ref = self.search(key) orelse return error.KeyNotFound;
    self.map.removeByPtr(ref.key_ptr);
    deinitPair(allocator, ref.key_ptr.*, ref.value_ptr.*);
}

pub fn count(self: *const Memory) u64 {
    return self.map.count();
}

pub fn clear(self: *Memory, allocator: std.mem.Allocator) void {
    var iter = self.iterator();
    while (iter.next()) |ref|
        deinitPair(allocator, ref.key_ptr.*, ref.value_ptr.*);
    self.map.clearRetainingCapacity();
}

pub fn free(self: *Memory, allocator: std.mem.Allocator) void {
    self.clear(allocator);
    self.map.clearAndFree(allocator);
}

pub const Iterator = struct {
    memory: *Memory,
    wrapped_iterator: Map.Iterator,

    pub fn next(self: *Iterator) ?object.Ref {
        const entry = self.wrapped_iterator.next() orelse return null;
        return .wrap(entry.key_ptr, entry.value_ptr);
    }

    pub fn skip(self: *Iterator) void {
        _ = self.wrapped_iterator.next();
    }
};

pub fn iterator(self: *Memory) Iterator {
    return .{ .memory = self, .wrapped_iterator = self.map.iterator() };
}

const SearchContext = struct {
    pub fn hash(_: @This(), s: []const u8) u64 {
        return std.hash.Wyhash.hash(0, s);
    }
    pub fn eql(_: @This(), a: []const u8, b: object.Key) bool {
        return std.mem.eql(u8, a, b.get());
    }
};

const PutContext = struct {
    pub fn hash(_: @This(), s: object.Key) u64 {
        return (SearchContext{}).hash(s.get());
    }
    pub fn eql(_: @This(), a: object.Key, b: object.Key) bool {
        return (SearchContext{}).eql(a.get(), b);
    }
};

const Map = std.HashMapUnmanaged(
    object.Key,
    object.Value,
    PutContext,
    65,
);

fn initPair(
    allocator: std.mem.Allocator,
    key: []const u8,
    value_type: object.value.Type,
    content: []const u8,
) PutError!struct { object.Key, object.Value } {
    const pair_key: object.Key = try .init(allocator, key, value_type);
    errdefer pair_key.deinit(allocator);
    const pair_value: object.Value = try .init(allocator, value_type, content);

    return .{ pair_key, pair_value };
}

fn deinitPair(allocator: std.mem.Allocator, key: object.Key, value: object.Value) void {
    key.deinit(allocator);
    value.deinit(allocator, key.getValueType());
}
