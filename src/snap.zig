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
//! It contains the implementation of Snap and Auto-snap.

const std = @import("std");

const signal = @import("signal.zig");
const log = @import("log.zig");
const ree = @import("ree.zig");

const Storage = @import("storage.zig").Storage;

/// Config for Auto-snap.
pub const AutosnapConf = struct {
    /// Saving delay from 2 saves.
    delay: u64,

    // Count of database modifies before snap.
    count: u64,
};

/// Makes a snap of database every <delay>
/// with a min of <modify count>.
/// This function is already threaded.
pub fn autosnap(storage: *Storage, logger: *log.Logger, conf: *const AutosnapConf, modc: *std.atomic.Value(u64)) error{ThreadError}!void {
    var timer = std.time.Timer.start() catch unreachable;

    while (true) {
        std.time.sleep(1 * std.time.ns_per_s);

        if (timer.read() >= conf.delay * std.time.ns_per_s and modc.load(.acquire) >= conf.count) {
            // Save to storage
            snap(storage, logger, true) catch {};

            modc.store(0, .release);
            timer.reset();
        }
    }
}

/// Attempts to save the storage to disk.
pub fn snap(storage: *Storage, logger: *log.Logger, auto: bool) !void {
    storage.save() catch |err| {
        const msg = switch (err) {
            error.OutOfMemory => signal.OOM(),
            error.NoSpaceLeft => signal.OOD(),
            else => ree.expandSaveError(err),
        };

        if (auto)
            logger.warning("Auto-snap: failed to save: {s}", .{msg})
        else
            logger.warning("Snap: failed to save: {s}", .{msg});
    };

    if (auto)
        logger.info("Auto-snap: saved successful.", .{})
    else
        logger.info("Snap: saved successful.", .{});

    // Snap success
    return;
}
