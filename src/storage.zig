//! BSD 3-Clause License
//!
//! Copyright (c) raptodb
//! Copyright (c) Andrea Vaccaro
//! All rights reserved.
//!
//! Redistribution and use in source and binary forms, with or without
//! modification, are permitted provided that the following conditions are met:
//!
//! 1. Redistributions of source code must retain the above copyright notice, this
//!    list of conditions and the following disclaimer.
//!
//! 2. Redistributions in binary form must reproduce the above copyright notice,
//!    this list of conditions and the following disclaimer in the documentation
//!    and/or other materials provided with the distribution.
//!
//! 3. Neither the name of the copyright holder nor the names of its
//!    contributors may be used to endorse or promote products derived from
//!    this software without specific prior written permission.
//!
//! THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//! AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//! IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//! DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
//! FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//! DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//! SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//! CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//! OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//! OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//!
//! This file is part of "Rapto".
//! It contains the implementation of storage.

const std = @import("std");

const signal = @import("signal.zig");
const lz4 = @import("lz4.zig");
const utils = @import("utils.zig");
const field = @import("field.zig");

const Object = @import("object.zig").Object;
const RaptoConfig = @import("options.zig").RaptoConfig;

/// Store of objects.
pub const Storage = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    /// Storage file.
    file: std.fs.File,

    /// Store of objects.
    store: std.ArrayList(Object),

    conf: *RaptoConfig,

    pub const LoadError = error{ LoadingError, OutOfMemory };
    pub const SaveError = error{ FileSeek, FileSync, WriteFailed, OutOfMemory, OutOfDisk };
    pub const PutError = error{ TypeOverflow, OutOfMemory };

    /// Initializes storage with an allocator, file and size in bytes.
    pub fn init(allocator: std.mem.Allocator, file: std.fs.File, conf: *RaptoConfig) Self {
        return Self{
            .allocator = allocator,
            .file = file,
            .store = std.ArrayList(Object).initCapacity(allocator, 0) catch unreachable,
            .conf = conf,
        };
    }

    /// Loads stored objects from file to memory.
    /// Returns the number of loaded items.
    pub noinline fn load(self: *Self) LoadError!u64 {
        var buf: [16 * 1024]u8 = undefined;
        var reader = self.file.readerStreaming(&buf);
        // count of loaded items
        var i: u64 = 0;

        while (true) {
            // get size of compressed object.
            // if it fails, data is fully loaded
            const size = reader.interface.takeInt(u64, .little) catch break;
            if (size == 0) break;

            // get compressed object with length
            const compressed = try self.allocator.alloc(u8, size);
            errdefer self.allocator.free(compressed);

            reader.interface.readSliceAll(compressed) catch return error.LoadingError;

            const decompressed = lz4.decompress(self.allocator, compressed);
            self.allocator.free(compressed);

            if (decompressed) |data| {
                defer self.allocator.free(data);

                // add this object to store
                var obj = Object.deserialize(self.allocator, data) catch |err| {
                    @branchHint(.unlikely);
                    if (err != error.OutOfMemory) break;
                    return error.OutOfMemory;
                };
                errdefer obj.deinit(self.allocator);

                try self.store.append(self.allocator, obj);
                i += 1; // increment loaded items
            }
            // rare branch: OOM or object
            // corrupted (caused by decompression fail)
            else |err| {
                // branch is unlikely assuming space limit
                // is inferior to that to reach OOM,
                // which has already been checked before decompression,
                // also the decompression error is rare
                @branchHint(.unlikely);
                if (err == error.OutOfMemory) return error.OutOfMemory;
            }
        }

        // shrink unused memory
        self.store.shrinkAndFree(self.allocator, self.store.items.len);

        return i;
    }

    /// Save objects into file. This function
    /// overwrites the file with new data.
    pub noinline fn save(self: *Self) SaveError!void {
        self.file.seekTo(0) catch return error.FileSeek;
        self.file.setEndPos(0) catch return error.FileSeek;

        var buf: [16 * 1024]u8 = undefined;
        var writer = self.file.writerStreaming(&buf);

        var i: u64 = self.store.items.len;
        while (i != 0) {
            i -= 1;

            // serialize object, serialized
            // contains size + object
            const serialized = try self.store.items[i].serialize(self.allocator);
            defer self.allocator.free(serialized);

            const compressed = try lz4.compress(self.allocator, serialized);
            defer self.allocator.free(compressed);

            // append size and serialized Object to file
            writer.interface.writeInt(u64, compressed.len, comptime .little) catch break;
            writer.interface.writeAll(compressed) catch break;
        }

        if (writer.err) |err| {
            @branchHint(.unlikely);
            return if (err == error.NoSpaceLeft) error.OutOfDisk else error.WriteFailed;
        }

        try writer.interface.flush();
        self.file.sync() catch return error.FileSync;
    }

    /// Puts item in the store and return index. If exist, overwrite it.
    /// If not exist, stores item on head of array, as most
    /// priority element for LRU policy.
    pub fn put(
        self: *Self,
        comptime field_type: field.Type,
        noalias key: []const u8,
        noalias value: anytype,
    ) PutError!u64 {
        const i = self.search(key) orelse
            // if key does not exist
            return self.append(field_type, key, value);

        var obj = &self.store.items[i];

        // updates value if the
        // field type is the same
        if (field_type == obj.type) {
            @branchHint(.likely);

            switch (field_type) {
                .integer => obj.field.integer = value,
                .decimal => obj.field.decimal = value,
                .string => try obj.field.string.set(self.allocator, value),
            }

            obj.metadata.update();
        }
        // if field type is not same, overwrites
        // object saving the same metadata
        else {
            // update value and metadata
            var metadata = obj.metadata;
            metadata.update();

            obj.deinit(self.allocator);

            obj.* = try .set(self.allocator, field_type, key, value);
            obj.metadata = metadata;
        }

        return i;
    }

    /// Retrieves object from the store using the specified key.
    /// When key is found, promote.
    /// If key does not exist, returns null.
    pub inline fn get(self: *Self, noalias key: []const u8) ?*Object {
        const index = self.search(key) orelse return null;
        return &self.store.items[index];
    }

    /// Searches object in store and return its index.
    /// If object is not found return null.
    /// if object is found updates the metadata and promotes.
    pub fn search(self: *Self, noalias key: []const u8) ?u64 {
        var i: u64 = self.store.items.len;
        while (i != 0) {
            @branchHint(.likely);

            i -= 1;
            const obj = &self.store.items[i];
            if (utils.advancedCompare(obj.getKey(), key))
                return self.promote(i);
        }

        return null;
    }

    /// Promotes index by Transposition Heuristic for
    /// LRU-like priority and return new index.
    /// This function swaps index to front element.
    /// Called when linear search hits key.
    inline fn promote(self: *Self, index: u64) u64 {
        if (index == self.store.items.len - 1) return index;

        const front_index = index + 1;
        @call(.always_inline, std.mem.swap, .{
            Object,
            &self.store.items[front_index], // front
            &self.store.items[index], // current index
        });

        return front_index;
    }

    /// Sorts storage with insertion sorting
    /// algorithm. Sorting is in ascendent
    /// order for LRU policy.
    pub inline fn sort(self: *Self) void {
        std.sort.insertion(Object, self.store.items, {}, comptime compareLRU);
    }

    /// Duplicates object with same metadata and different key.
    pub fn dupe(self: *Self, obj: *Object, key: []const u8) PutError!void {
        const i = switch (obj.type) {
            .integer => try self.put(.integer, key, obj.field.integer),
            .decimal => try self.put(.decimal, key, obj.field.decimal),
            .string => try self.put(.string, key, obj.field.string.get()),
        };
        self.store.items[i].metadata = obj.metadata;
    }

    /// Appends new object at head of the list.
    /// Returns the index of object.
    pub fn append(self: *Self, comptime field_type: field.Type, noalias key: []const u8, noalias value: anytype) PutError!u64 {
        // create new object
        var obj: Object = try .set(self.allocator, field_type, key, value);
        errdefer obj.deinit(self.allocator);

        // if allocator is not std.heap.FixedBufferAllocator
        if (self.conf.db_size == null)
            // add to list growing memory 1 at a time
            try utils.appendNoGrowing(Object, self.allocator, &self.store, obj)
        else // if allocator allocates in stack
            try self.store.append(self.allocator, obj);

        // promote skipped because the array is reversed.
        // now the obj is already on the head.
        return self.store.items.len - 1;
    }

    /// Removes item from index from store.
    /// If key is found, deallocates and removes it.
    pub noinline fn removeAtIndex(self: *Self, index: u64) void {
        var obj: *Object = @constCast(&self.store.orderedRemove(index));

        // deallocate object and shrink
        obj.deinit(self.allocator);
        self.store.shrinkAndFree(self.allocator, self.store.items.len);
    }

    /// Deinits storage.
    /// Deallocates every key.
    pub fn deinit(self: *Self) void {
        // deallocate every key
        for (self.store.items) |*obj|
            obj.deinit(self.allocator);
        // deallocate store
        self.store.deinit(self.allocator);

        self.* = undefined;
    }
};

/// compareFn function for LRU policy.
/// This function is useful for sorting after load to RAM.
fn compareLRU(_: void, a: Object, b: Object) bool {
    // compare last access with ascendent order
    return a.metadata.last_access < b.metadata.last_access;
}

test "storage" {
    var conf: RaptoConfig = .{};
    var storage = Storage.init(std.testing.allocator, undefined, &conf);
    defer storage.deinit();

    const v1: []const u8 = "bar";
    const index1 = try storage.put(.string, "foo", v1);
    try std.testing.expect(index1 == 0);

    const index2 = try storage.put(.integer, "num", 42);
    try std.testing.expect(index2 == 1);

    const obj1 = storage.get("foo") orelse return error.TestExpectedObject;
    try std.testing.expectEqualStrings("foo", obj1.getKey());
    try std.testing.expectEqualStrings("bar", obj1.field.string.get());

    const obj2 = storage.get("num") orelse return error.TestExpectedObject;
    try std.testing.expect(obj2.field.integer == 42);

    // overwriting
    const v2: []const u8 = "baz";
    const index3 = try storage.put(.string, "foo", v2);
    try std.testing.expect(index1 == index3 - 1); // index1 promoted after put

    const obj3 = storage.get("foo") orelse return error.TestExpectedObject;
    try std.testing.expectEqualStrings("baz", obj3.field.string.get());

    storage.removeAtIndex(index1);
    try std.testing.expect(storage.get("num") == null);

    const index4 = storage.search("foo") orelse return error.TestExpectedObject;
    try std.testing.expect(index4 == 0);
}

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}
