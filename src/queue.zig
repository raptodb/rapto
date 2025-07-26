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
//! It contains the implementation of thread safe queue.

const std = @import("std");

const appendNoGrowing = @import("utils.zig").appendNoGrowing;

/// Thread safe queue with mutex locking
/// and thread conditions. Hightly optimized.
pub fn ThreadSafeQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        queue: std.ArrayListUnmanaged(T) = .empty,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},

        /// Puts an item on queue.
        pub fn put(self: *Self, allocator: std.mem.Allocator, item: T) error{OutOfMemory}!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            try appendNoGrowing(allocator, T, &self.queue, item);
            self.cond.signal();
        }

        /// Wait any item on queue, after waiting
        /// returns it.
        pub fn waitAndPop(self: *Self, allocator: std.mem.Allocator) T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.queue.items.len == 0) {
                @branchHint(.unlikely);
                self.cond.wait(&self.mutex);
            }

            const item = self.queue.orderedRemove(0);
            defer self.queue.shrinkAndFree(allocator, self.queue.items.len);

            return item;
        }

        /// Deinits queue and deallocates
        /// all unpopped items.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.queue.deinit(allocator);
            self.* = undefined;
        }
    };
}

test "queue" {
    var q = ThreadSafeQueue(i32){};
    defer q.deinit(std.testing.allocator);

    try q.put(std.testing.allocator, 32);
    try q.put(std.testing.allocator, 21);
    try q.put(std.testing.allocator, 0);
    try q.put(std.testing.allocator, 16);
    try q.put(std.testing.allocator, 500);

    try std.testing.expect(q.waitAndPop(std.testing.allocator) == 32);
    try std.testing.expect(q.waitAndPop(std.testing.allocator) == 21);
    try std.testing.expect(q.waitAndPop(std.testing.allocator) == 0);
    try std.testing.expect(q.waitAndPop(std.testing.allocator) == 16);
    try std.testing.expect(q.waitAndPop(std.testing.allocator) == 500);
}

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}
