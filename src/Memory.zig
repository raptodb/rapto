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
const object = @import("object.zig");


/// Hashmap of items. Internal API
/// should not be used directly.
map: Map,

pub const init: Memory = .{ .map = .empty };

pub fn deinit(self: *Memory, allocator: std.mem.Allocator) void {
    _ = self.clear(allocator);
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
        entry.key_ptr.*, entry.value_ptr.* = try object.init(allocator, key, value_type, content);
    }

    return ref;
}

pub fn copy(
    self: *Memory,
    allocator: std.mem.Allocator,
    src_key: []const u8,
    dst_key: []const u8,
) error{ KeyNotFound, InvalidKey, OutOfMemory }!void {
    const src_entry = self.map.getEntryAdapted(src_key, SearchContext{}) orelse
        return error.KeyNotFound;
    const src_ref: object.Ref = .wrap(src_entry.key_ptr, src_entry.value_ptr);
    const src_type = src_ref.type();

    const dst_entry = try self.map.getOrPutAdapted(
        allocator,
        dst_key,
        SearchContext{},
    );

    if (dst_entry.found_existing) {
        dst_entry.key_ptr.setValueType(src_type);
        dst_entry.value_ptr.deinit(allocator, src_type);
    } else {
        dst_entry.key_ptr.* = try .init(allocator, dst_key, src_ref.type());
    }

    dst_entry.value_ptr.* = switch (src_ref.type()) {
        inline else => |t| @unionInit(
            object.Value,
            @tagName(t),
            try src_ref.dupeValue(allocator, t),
        ),
    };
}

pub fn search(self: *Memory, key: []const u8) ?object.Ref {
    const entry = self.map.getEntryAdapted(key, SearchContext{}) orelse return null;
    return .wrap(entry.key_ptr, entry.value_ptr);
}

/// Removes key from memory. Associated
/// object.Ref will be invalidated.
pub fn remove(
    self: *Memory,
    allocator: std.mem.Allocator,
    key: []const u8,
) error{KeyNotFound}!void {
    const ref = self.get(key) orelse return error.KeyNotFound;
    return self.removeByRef(allocator, ref);
}

/// Removes key from memory by ref.
/// Associated object.Ref will be invalidated.
pub fn removeByRef(self: *Memory, allocator: std.mem.Allocator, ref: object.Ref) void {
    object.deinit(allocator, ref.key_ptr.*, ref.value_ptr.*);
    self.map.removeByPtr(ref.key_ptr);
}

pub fn count(self: *const Memory) u64 {
    return self.map.count();
}

pub fn clear(self: *Memory, allocator: std.mem.Allocator) u64 {
    var iter = self.iterator();
    while (iter.next()) |ref| {
        deinitPair(allocator, ref.key_ptr.*, ref.value_ptr.*);
    }
    self.map.clearRetainingCapacity();
    return self.count();
}

pub fn free(self: *Memory, allocator: std.mem.Allocator) u64 {
    const i = self.clear(allocator);
    self.map.clearAndFree(allocator);
    return i;
}

pub fn iterator(self: *Memory) Iterator {
    return .{ .memory = self, .wrapped_iterator = self.map.iterator() };
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

