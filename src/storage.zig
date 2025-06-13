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

const Object = @import("object.zig").Object;
const FieldType = @import("object.zig").FieldType;

/// Store of objects.
pub const Storage = struct {
    const Self = @This();

    allocator: std.mem.Allocator = undefined,

    /// Storage file.
    file: std.fs.File = undefined,

    /// Store of objects.
    store: std.ArrayListUnmanaged(Object) = undefined,

    /// Store capacity.
    /// Should be changed with addition
    /// or subtraction of object size.
    store_cap: u64 = 0,

    /// Initializes storage with an allocator, file and size in bytes.
    pub fn init(allocator: std.mem.Allocator, file: std.fs.File, size: u64) Self {
        return Self{
            .allocator = allocator,
            .file = file,
            .store = std.ArrayListUnmanaged(Object).initCapacity(allocator, 0) catch unreachable,
            .store_cap = size,
        };
    }

    /// Loads stored objects from file to memory.
    /// Returns the number of loaded items.
    pub const LoadError = error{ LoadingError, ExcedeedSpaceLimit } || signal.SignalError;
    pub noinline fn load(self: *Self) LoadError!u64 {
        const reader = self.file.reader();
        // count of loaded items
        var i: u64 = 0;

        while (true) {
            // get size of compressed object.
            // if it fails, data is fully loaded
            const size = reader.readInt(u64, .little) catch break;
            if (size == 0) {
                @branchHint(.unlikely);
                break;
            }

            // get compressed object with length
            const compressed = try self.allocator.alloc(u8, size);
            errdefer self.allocator.free(compressed);

            _ = reader.readAll(compressed) catch return error.LoadingError;

            // decompression occupies a max 255 times more than compressed,
            // for this reason, check firstly if it doesn't excedeed space limit
            _ = std.math.sub(u64, self.store_cap, compressed.len *| 255) catch return error.ExcedeedSpaceLimit;

            // if it assumes it can allocate the compressed size for 255 times, decompresses
            const decompressed = lz4.decompress(self.allocator, compressed);
            self.allocator.free(compressed);

            if (decompressed) |data| {
                defer self.allocator.free(data);

                // add this object to store
                var obj = Object.deserialize(self.allocator, data) catch |err| switch (err) {
                    error.OutOfMemory => {
                        @branchHint(.unlikely);
                        return error.OutOfMemory;
                    },
                    else => break,
                };
                errdefer obj.deinit(self.allocator);

                // update capacity with loaded object
                try self.removeCapacity(obj.getSize());

                try self.store.append(self.allocator, obj);
                i += 1; // increment loaded items
            }

            // rare branch: OOM or object
            // corrupted (caused by decompression fail)
            else |err| {
                // branch is cold assuming space limit
                // is inferior to that to reach OOM,
                // which has already been checked before decompression,
                // also the decompression error is rare
                @branchHint(.cold);
                if (err == error.OutOfMemory) return error.OutOfMemory;
            }
        }

        // shrink unused memory
        self.store.shrinkAndFree(self.allocator, self.store.items.len);

        return i;
    }

    /// Save objects into file. This function
    /// overwrites the file with new data.
    pub const SaveError = error{ FileSeek, FileSync } || signal.SignalError || std.fs.File.WriteError;
    pub noinline fn save(self: *Self) SaveError!void {
        self.file.seekTo(0) catch return error.FileSeek;
        self.file.setEndPos(0) catch return error.FileSeek;

        const writer = self.file.writer();

        var i: u64 = self.store.items.len;
        while (i > 0) {
            i -= 1;

            // serialize object, serialized
            // contains size + object
            const serialized = try self.store.items[i].serialize(self.allocator);
            defer self.allocator.free(serialized);

            const compressed = try lz4.compress(self.allocator, serialized);
            defer self.allocator.free(compressed);

            // append size and serialized Object to file
            writer.writeInt(u64, compressed.len, comptime .little) catch |err|
                if (err == error.NoSpaceLeft) return error.OutOfDisk;
            writer.writeAll(compressed) catch |err|
                if (err == error.NoSpaceLeft) return error.OutOfDisk;
        }

        self.file.sync() catch return error.FileSync;
    }

    /// Retrieves object from the store using the specified key.
    /// When key is found, promote.
    /// If key does not exist, returns null.
    pub fn get(self: *Self, noalias key: []const u8) ?*Object {
        const index = self.search(key) orelse return null;
        return &self.store.items[index];
    }

    /// Puts item in the store and return index. If exist, overwrite it.
    /// If not exist, stores item on head of array, as most
    /// priority element for LRU policy.
    pub const PutError = error{ TypeOverflow, ExcedeedSpaceLimit } || signal.SignalError;
    pub fn put(self: *Self, comptime field_type: FieldType, noalias key: []const u8, noalias value: anytype) PutError!u64 {
        // check if key already exist
        if (self.search(key)) |i| {
            var obj = &self.store.items[i];

            // update value
            if (field_type == obj.field) {
                @branchHint(.likely);

                obj.field = switch (field_type) {
                    .integer => .{ .integer = value },
                    .decimal => .{ .decimal = value },
                    .string => blk: {
                        if (value.len != obj.field.string.len)
                            obj.field.string = try self.allocator.realloc(obj.field.string, value.len);

                        @memcpy(obj.field.string, value);
                        break :blk .{ .string = obj.field.string };
                    },
                };
            }

            // if value has different type,
            // set new object passing metadata
            else {
                // restore size without this object,
                // then add size with updated object
                try self.addCapacity(self.store.items[i].getSize());

                // update value and metadata
                var metadata = self.store.items[i].metadata;
                metadata.update();

                self.store.items[i].deinit(self.allocator);
                self.store.items[i] = try Object.set(self.allocator, field_type, key, value);
                self.store.items[i].metadata = metadata;

                // update capacity with updated object
                try self.removeCapacity(self.store.items[i].getSize());
            }

            return i;
        }

        // create new object
        var obj = try Object.set(self.allocator, field_type, key, value);
        errdefer obj.deinit(self.allocator);

        // update store capacity
        try self.removeCapacity(obj.getSize());

        // add to list growing memory 1 at a time
        try self.store.ensureTotalCapacityPrecise(self.allocator, self.store.items.len + 1);
        self.store.appendAssumeCapacity(obj);

        // promote skipped because the array is reversed.
        // now the obj is already on the head.
        return self.store.items.len - 1;
    }

    /// Removes item from index from store.
    /// If key is found, deallocates and removes it.
    pub noinline fn removeAtIndex(self: *Self, index: u64) error{ExcedeedSpaceLimit}!void {
        var obj: *Object = @constCast(&self.store.orderedRemove(index));

        // add capacity
        try self.addCapacity(obj.getSize());

        // deallocate object and shrink
        obj.deinit(self.allocator);
        self.store.shrinkAndFree(self.allocator, self.store.items.len);
    }

    /// Searches object in store and return its index.
    /// If object is not found return null.
    /// if object is found updates the metadata and promotes.
    pub fn search(self: *Self, noalias key: []const u8) ?u64 {
        var i: u64 = self.store.items.len;
        while (i > 0) {
            i -= 1;

            const obj = &self.store.items[i];
            if (utils.advancedCompare(obj.key, key))
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
        std.mem.swap(
            Object,
            &self.store.items[front_index], // front
            &self.store.items[index], // current index
        );

        return front_index;
    }

    /// Prefetch storage with insertion sorting
    /// algorithm. Sorting is in ascendent
    /// order for LRU policy.
    pub inline fn prefetch(self: *Self) void {
        std.sort.insertion(Object, self.store.items, {}, comptime compareLRU);
    }

    pub inline fn addCapacity(self: *Self, size: u64) error{ExcedeedSpaceLimit}!void {
        const v = std.math.add(u64, self.store_cap, size);
        self.store_cap = v catch return error.ExcedeedSpaceLimit;
    }

    pub inline fn removeCapacity(self: *Self, size: u64) error{ExcedeedSpaceLimit}!void {
        const v = std.math.sub(u64, self.store_cap, size);
        self.store_cap = v catch return error.ExcedeedSpaceLimit;
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
/// This function is useful for prefetching after load to RAM.
fn compareLRU(_: void, a: Object, b: Object) bool {
    // compare last access with ascendent order
    return a.metadata.last_access < b.metadata.last_access;
}
