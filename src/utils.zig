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
//! It contains the implementation of utils functions.

const std = @import("std");

/// Default hash algorithm with xxHash3
inline fn hash(noalias value: []const u8) u64 {
    return std.hash.XxHash3.hash(0, value);
}

/// Advanced equal function with vectorization and hashing
/// checking. Faster if len <= 16.
pub inline fn advancedCompare(noalias a: []const u8, noalias b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len <= 16) {
        @branchHint(.likely);
        return std.mem.eql(u8, a, b);
    }

    // hash checking usually does not match
    if (hash(a) != hash(b)) {
        @branchHint(.likely);
        return false;
    }

    // if hashes are equals, compare
    else return std.mem.eql(u8, a, b);
}

/// Returns upper string.
pub fn upperString(ascii: []u8) []u8 {
    for (ascii, 0..) |c, i|
        ascii[i] = std.ascii.toUpper(c);
    return ascii[0..];
}
