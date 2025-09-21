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
//! It contains the implementation of atomic cell.

const std = @import("std");

/// Thread-safe item with get and put method.
/// When item is empty, get waits waitAndPut that puts item.
/// When item is not empty, put waits waitAndGet that retrieves item.
pub fn AtomicCell(comptime T: type) type {
    return struct {
        const Self = @This();

        shared: ?T = null,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},

        pub fn waitAndPut(self: *Self, item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.shared != null) {
                @branchHint(.unlikely);
                self.cond.wait(&self.mutex);
            }

            self.shared = item;
            self.cond.signal();
        }

        pub fn waitAndGet(self: *Self) T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.shared == null) {
                @branchHint(.unlikely);
                self.cond.wait(&self.mutex);
            }

            const item = self.shared.?;
            self.shared = null;
            self.cond.signal();

            return item;
        }
    };
}

test "atomic cell" {
    var cell: AtomicCell(u32) = .{};

    cell.waitAndPut(50);
    try std.testing.expect(cell.waitAndGet() == 50);

    cell.waitAndPut(2);
    try std.testing.expect(cell.waitAndGet() == 2);

    cell.waitAndPut(1205);
    try std.testing.expect(cell.waitAndGet() == 1205);
}
