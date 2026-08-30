//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of object.

const std = @import("std");
const frames = @import("frames.zig");
const glob = @import("glob.zig");
const assert = std.debug.assert;

const TaggedPtr = @import("object/tagged_ptr.zig").TaggedPtr;

comptime {
    // Ensures fixed size of {key, value} pair have
    // a size of 2 pointers on ReleaseFast mode.
    const mode = @import("builtin").mode;
    if (mode == .ReleaseFast or mode == .ReleaseSafe) {
        assert(@sizeOf(Key) == @sizeOf(usize));
        assert(@sizeOf(Value) == @sizeOf(usize));
    }

    // for this implementation
    assert(@sizeOf(u64) == @sizeOf(usize));
}

pub const InitError = std.mem.Allocator.Error || error{
    InvalidKey,
    InvalidFormat,
    MismatchType,
    UnknownType,
};

pub fn init(
    allocator: std.mem.Allocator,
    key: []const u8,
    value_type: Value.Type,
    content: []const u8,
) InitError!struct { Key, Value } {
    const pair_key: Key = try .init(allocator, key, value_type);
    errdefer pair_key.deinit(allocator);
    const pair_value: Value = try .init(allocator, value_type, content);
    return .{ pair_key, pair_value };
}

pub fn deinit(allocator: std.mem.Allocator, key: Key, value: Value) void {
    key.deinit(allocator);
    value.deinit(allocator, key.getValueType());
}

pub const Key = struct {
    pub const Error = std.mem.Allocator.Error || error{InvalidKey};

    /// Pointer alignment of current architecture.
    /// Defined for clarity and conventional purposes.
    const ptr_alignment: std.mem.Alignment = .of(usize);

    /// Representation of first two bytes of key.
    /// Used to store metadata such as length and
    /// other utilities.
    pub const Metadata = packed struct(u16) {
        len: u8,
        locked: bool = false,

        // Reserved for incoming features.
        _: u7 = undefined,
    };

    /// Tagged pointer to a length-prefixed key. The length is stored in the
    /// first byte, limiting keys to 255 bytes. Like Memcached, this limit
    /// works for most use cases and provides better performance.
    /// The tag stores the value type in the 3 least significant bits.
    ptr: TaggedPtr([*]align(ptr_alignment.toByteUnits()) u8) = undefined,

    /// Initializes key by duplicating it.
    /// After creation, key is marked as unlocked.
    pub fn init(allocator: std.mem.Allocator, key: []const u8, value_type: Value.Type) Error!Key {
        if (!isValidKey(key)) return error.InvalidKey;

        const slice = try allocator.alignedAlloc(
            u8,
            ptr_alignment,
            @sizeOf(Metadata) + key.len,
        );

        assert(key.len <= std.math.maxInt(u8));
        const m: Metadata = .{ .len = @truncate(key.len) };

        @memcpy(slice[0..@sizeOf(Metadata)], std.mem.asBytes(&m));
        @memcpy(slice[@sizeOf(Metadata)..], key);

        return .{ .ptr = .init(slice.ptr, @intFromEnum(value_type)) };
    }

    /// Deallocates key string with included length.
    pub fn deinit(self: Key, allocator: std.mem.Allocator) void {
        allocator.free(self.content());
    }

    /// Efficiently replaces current key with a new key. Reallocates if necessary.
    pub fn set(self: *Key, allocator: std.mem.Allocator, new_key: []const u8) Error!void {
        if (!isValidKey(new_key)) return error.InvalidKey;

        const length_new_key: u8 = @truncate(new_key.len);
        const length_old_key = self.metadata().len;

        var ptr = self.ptr.getPointer();

        if (length_old_key != length_new_key) {
            const slice = try allocator.realloc(
                self.content(),
                @sizeOf(Metadata) + length_new_key,
            );

            ptr = slice.ptr;
            self.ptr.setPointer(ptr);
            // Update string length.
            const m = self.metadata();
            m.len = length_new_key;
        }

        @memcpy(ptr[@sizeOf(Metadata)..][0..length_new_key], new_key);
    }

    pub fn get(self: Key) []const u8 {
        return self.content()[@sizeOf(Metadata)..];
    }

    /// Returns entire buffer with length and key.
    fn content(self: Key) []align(ptr_alignment.toByteUnits()) u8 {
        const ptr = self.ptr.getPointer();
        const m = self.metadata();
        return ptr[0 .. @sizeOf(Metadata) + m.len];
    }

    fn metadata(self: Key) *Metadata {
        const ptr = self.ptr.getPointer();
        return @ptrCast(ptr);
    }

    pub fn isLocked(self: Key) bool {
        const m = self.metadata();
        return m.locked;
    }

    pub fn lock(self: Key) void {
        const m = self.metadata();
        m.locked = true;
    }

    pub fn unlock(self: Key) void {
        const m = self.metadata();
        m.locked = false;
    }

    pub fn getValueType(self: Key) Value.Type {
        const tag = self.ptr.getTag();
        return Value.Type.fromInt(tag) catch unreachable;
    }

    pub fn setValueType(self: *Key, value_type: Value.Type) void {
        self.ptr.setTag(@intFromEnum(value_type));
    }

    pub fn isValidKey(key: []const u8) bool {
        return hasValidLength(key) and glob.classify(key) == .literal;
    }

    pub fn hasValidLength(key: []const u8) bool {
        return key.len != 0 and key.len <= std.math.maxInt(u8);
    }
};

pub const Value = union {
    pub const Scalar = @import("object/scalar.zig").Scalar;

    pub const Void = @import("object/scalar.zig").Void;
    pub const Integer = @import("object/scalar.zig").Integer;
    pub const Decimal = @import("object/scalar.zig").Decimal;
    pub const Flag = @import("object/scalar.zig").Flag;
    pub const String = @import("object/scalar.zig").String;
    pub const Point = @import("object/scalar.zig").Point;

    pub const List = @import("object/collection.zig").List;
    pub const Map = @import("object/collection.zig").Map;

    /// Splits serialized into [value_type:u8][content].
    /// Instead, see `Type.serializeToWriter` to build [serialized].
    pub fn splitSerialized(
        serialized: []const u8,
    ) error{ InvalidFormat, UnknownType }!struct { Type, []const u8 } {
        assert(serialized.len != 0);

        if (serialized.len < @sizeOf(u8)) return error.InvalidFormat;
        const value_type: Type = try .fromInt(serialized[0]);
        const content = if (serialized.len > 1) serialized[1..] else &.{};

        return .{ value_type, content };
    }

    /// Serializes value to writer as [serialized]. Only scalars
    /// that have `serializeContentToWriter` method can be serialized.
    pub fn serializeToWriter(
        writer: *std.Io.Writer,
        value: anytype,
    ) std.Io.Writer.Error!void {
        const value_type: Type = .of(value);
        assert(value_type.group() == .scalar);

        try value_type.serializeToWriter(writer);
        return value.serializeContentToWriter(writer);
    }

    /// Enumeration of all value types. The quantity of value types
    /// must be equal or under 8: the value type is saved on 3 LSB
    /// bits of tagged pointer.
    pub const Type = enum(u3) {
        // Scalar types
        void = 0,
        integer,
        decimal,
        flag,
        string,
        point,

        // Collection types
        list,
        map,

        pub fn fromInt(integer: anytype) error{UnknownType}!Type {
            return std.enums.fromInt(Type, integer) orelse error.UnknownType;
        }

        pub fn of(value: anytype) Type {
            return switch (@TypeOf(value)) {
                Value.Void => .void,
                Value.Integer => .integer,
                Value.Decimal => .decimal,
                Value.Flag => .flag,
                Value.String => .string,
                Value.Point => .point,
                Value.List => .list,
                Value.Map => .map,
                else => unreachable,
            };
        }

        pub fn group(self: Type) enum { scalar, collection } {
            return switch (self) {
                .void, .integer, .decimal, .flag, .string, .point => .scalar,
                .list, .map => .collection,
            };
        }

        pub fn serializeToWriter(self: Type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeByte(@intFromEnum(self));
        }
    };

    pub fn UnionType(comptime value_type: Type) type {
        return switch (value_type) {
            .void => Value.Void,
            .integer => Value.Integer,
            .decimal => Value.Decimal,
            .flag => Value.Flag,
            .string => Value.String,
            .point => Value.Point,
            .list => Value.List,
            .map => Value.Map,
        };
    }

    // Scalar types
    void: Void,
    integer: Integer,
    decimal: Decimal,
    flag: Flag,
    string: String,
    point: Point,

    // Collection types
    list: List,
    map: Map,

    pub fn init(
        allocator: std.mem.Allocator,
        value_type: Type,
        content: []const u8,
    ) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType })!Value {
        return switch (value_type) {
            inline .void => |vt| @unionInit(
                Value,
                @tagName(vt),
                .fromContent(),
            ),
            inline .integer, .decimal, .flag => |vt| @unionInit(
                Value,
                @tagName(vt),
                try .fromContent(content),
            ),
            inline .string, .point => |vt| @unionInit(
                Value,
                @tagName(vt),
                try .initFromContent(allocator, content),
            ),
            inline .list, .map => |vt| @unionInit(
                Value,
                @tagName(vt),
                try .init(allocator),
            ),
        };
    }

    pub fn deinit(self: Value, allocator: std.mem.Allocator, value_type: Type) void {
        switch (value_type) {
            .void, .integer, .decimal, .flag => {},
            inline else => |vt| @field(self, @tagName(vt)).deinit(allocator),
        }
    }

    pub fn dupe(
        self: Value,
        allocator: std.mem.Allocator,
        comptime value_type: Type,
    ) std.mem.Allocator.Error!UnionType(value_type) {
        return switch (value_type) {
            inline .point, .string, .list, .map => |t| @field(
                self,
                @tagName(t),
            ).dupe(allocator),
            inline else => |t| @field(self, @tagName(t)).dupe(),
        };
    }

    pub fn set(
        self: *Value,
        allocator: std.mem.Allocator,
        value_type: Type,
        content: []const u8,
    ) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType })!void {
        assert(value_type.group() != .collection);

        switch (value_type) {
            .void => self.void.set(),
            inline .integer, .decimal, .flag, .point => |vt| {
                try @field(self, @tagName(vt)).set(content);
            },
            inline .string => |vt| {
                try @field(self, @tagName(vt)).set(allocator, content);
            },
            // Handled earlier.
            .list, .map => unreachable,
        }
    }
};

/// Safe reference adapter to key-value.
/// This allows safe operations on key or
/// value while keeping the values separate.
pub const Ref = struct {
    key_ptr: *Key,
    value_ptr: *Value,

    /// Wraps pointers from Key and Value into Ref. Does not take ownership.
    pub fn wrap(key_ptr: *Key, value_ptr: *Value) Ref {
        return .{ .key_ptr = key_ptr, .value_ptr = value_ptr };
    }

    pub fn key(self: Ref) []const u8 {
        return self.key_ptr.get();
    }

    /// Returns the reference of value_ptr.{value_type}.
    pub fn value(self: Ref, comptime value_type: Value.Type) Value.UnionType(value_type) {
        return @field(self.value_ptr, @tagName(value_type));
    }

    pub fn isLocked(self: Ref) bool {
        return self.key_ptr.isLocked();
    }

    pub fn lock(self: Ref) void {
        return self.key_ptr.lock();
    }

    pub fn unlock(self: Ref) void {
        return self.key_ptr.unlock();
    }

    pub fn setKey(
        self: Ref,
        allocator: std.mem.Allocator,
        new_key: []const u8,
    ) (std.mem.Allocator.Error || error{InvalidKey})!void {
        try self.key_ptr.set(allocator, new_key);
    }

    /// Replaces current value directly.
    pub fn setValue(self: Ref, allocator: std.mem.Allocator, v: Value) void {
        const current_value_type = self.type();
        self.value_ptr.deinit(allocator, current_value_type);
        self.value_ptr.* = v;
        const value_type: Value.Type = .of(v);
        if (current_value_type != value_type) {
            self.key_ptr.setValueType(value_type);
        }
    }

    /// Sets value with a new scalar value.
    /// If value type is different, deallocates previous value
    /// and allocates new value. Otherwise, updates in-place.
    pub fn setValueFromContent(
        self: Ref,
        allocator: std.mem.Allocator,
        value_type: Value.Type,
        content: []const u8,
    ) (std.mem.Allocator.Error || error{ InvalidFormat, MismatchType, UnknownType, InvalidKey })!void {
        const current_value_type = self.type();

        // Collection must be handled from
        // their methods through `value`.
        if (value_type.group() == .collection) return error.MismatchType;

        if (value_type != current_value_type) {
            @branchHint(.unlikely);

            // Deallocate previous value first.
            self.value_ptr.deinit(allocator, current_value_type);
            self.value_ptr.* = try .init(allocator, value_type, content);

            // Update tag to new value type.
            return self.key_ptr.setValueType(value_type);
        }

        return self.value_ptr.set(allocator, value_type, content);
    }

    pub fn dupeValue(
        self: Ref,
        allocator: std.mem.Allocator,
        comptime value_type: Value.Type,
    ) std.mem.Allocator.Error!Value.UnionType(value_type) {
        assert(self.type() == value_type);
        return self.value_ptr.dupe(allocator, value_type);
    }

    /// Returns type of value exploiting tag of pointer to key.
    pub fn @"type"(self: Ref) Value.Type {
        return self.key_ptr.getValueType();
    }
};

test "Value.Type" {
    const allocator = std.testing.allocator;

    try std.testing.expect(try Value.Type.fromInt(0) == .void);
    try std.testing.expect(try Value.Type.fromInt(1) == .integer);
    try std.testing.expect(try Value.Type.fromInt(2) == .decimal);
    try std.testing.expect(try Value.Type.fromInt(3) == .flag);
    try std.testing.expect(try Value.Type.fromInt(4) == .string);
    try std.testing.expect(try Value.Type.fromInt(5) == .point);
    try std.testing.expect(try Value.Type.fromInt(6) == .list);
    try std.testing.expect(try Value.Type.fromInt(7) == .map);

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    try Value.Type.serializeToWriter(.void, &allocating.writer);
    try std.testing.expect(0 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Value.Type.serializeToWriter(.integer, &allocating.writer);
    try std.testing.expect(1 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Value.Type.serializeToWriter(.decimal, &allocating.writer);
    try std.testing.expect(2 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Value.Type.serializeToWriter(.flag, &allocating.writer);
    try std.testing.expect(3 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Value.Type.serializeToWriter(.string, &allocating.writer);
    try std.testing.expect(4 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Value.Type.serializeToWriter(.point, &allocating.writer);
    try std.testing.expect(5 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Value.Type.serializeToWriter(.list, &allocating.writer);
    try std.testing.expect(6 == allocating.written()[0]);
    allocating.clearRetainingCapacity();

    try Value.Type.serializeToWriter(.map, &allocating.writer);
    try std.testing.expect(7 == allocating.written()[0]);
    allocating.clearRetainingCapacity();
}

test "Ref" {
    const allocator = std.testing.allocator;

    const integer_content: [8]u8 = @bitCast(@as(i64, 42));

    {
        var key, var f = try init(allocator, "my_key", .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer deinit(allocator, key, f);

        try std.testing.expectEqualStrings("my_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var key, var f = try init(allocator, "aaa", .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer deinit(allocator, key, f);

        try ref.setKey(allocator, "bbb");

        try std.testing.expectEqualStrings("bbb", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var key, var f = try init(allocator, "short", .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer deinit(allocator, key, f);

        try ref.setKey(allocator, "a_much_longer_key");

        try std.testing.expectEqualStrings("a_much_longer_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var raw_key: [260]u8 = @splat(0);
        try std.testing.expectError(
            error.InvalidKey,
            Key.init(allocator, &raw_key, .integer),
        );
    }

    {
        const integer_20_content: [8]u8 = @bitCast(@as(i64, 20));

        var key, var f = try init(allocator, "my_key", .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer deinit(allocator, key, f);

        try ref.setValueFromContent(allocator, .integer, &integer_20_content);

        try std.testing.expectEqualStrings("my_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());
    }

    {
        var key, var f = try init(allocator, "my_key", .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer deinit(allocator, key, f);

        try ref.setValueFromContent(allocator, .string, "hello");

        try std.testing.expectEqualStrings("my_key", ref.key());
        try std.testing.expectEqual(.string, ref.type());
    }

    {
        var key, var f = try init(allocator, "evolving", .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer deinit(allocator, key, f);

        try ref.setValueFromContent(allocator, .string, "step one");
        try std.testing.expectEqualStrings("evolving", ref.key());
        try std.testing.expectEqual(.string, ref.type());

        const decimal_content: [8]u8 = @bitCast(@as(f64, 9.81));
        try ref.setValueFromContent(allocator, .decimal, &decimal_content);
        try std.testing.expectEqualStrings("evolving", ref.key());
        try std.testing.expectEqual(.decimal, ref.type());

        const flag_content: [8]u8 = @bitCast(@as(u64, 1));
        try ref.setValueFromContent(allocator, .flag, &flag_content);
        try std.testing.expectEqualStrings("evolving", ref.key());
        try std.testing.expectEqual(.flag, ref.type());
    }

    {
        var key, var f = try init(allocator, "old_key", .integer, &integer_content);

        const ref: Ref = .wrap(&key, &f);
        defer deinit(allocator, key, f);

        try ref.setKey(allocator, "new_key");
        try std.testing.expectEqualStrings("new_key", ref.key());
        try std.testing.expectEqual(.integer, ref.type());

        try ref.setValueFromContent(allocator, .string, "hello");
        try std.testing.expectEqualStrings("new_key", ref.key());
        try std.testing.expectEqual(.string, ref.type());
    }
}
