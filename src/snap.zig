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

const utils = @import("utils.zig");
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

/// Starts autosnap if it is enabled.
/// Logs configs about autosnap.
pub inline fn startAutosnap(
    storage: *Storage,
    logger: *log.Logger,
    save_info: ?AutosnapConf,
    modc: *std.atomic.Value(u64),
) !void {
    if (storage.conf.no_persistence) {
        // if server is launched with no-persistence
        // mode, disables automatically Auto-snap.
        logger.warning("Auto-snap disabled by no-persistence mode.", .{});
        return;
    }

    // if save is enabled, start Auto-snap
    // with configuration
    if (save_info) |*save| {
        const t = try utils.spawn(autosnap, .{ storage, logger, save, modc });
        t.detach();

        logger.info("Auto-snap enabled with delay={d} count={d}.", .{ save.delay, save.count });
    }
    // if save is not enabled warn
    // to say that Auto-snap is disabled.
    // items will not be saved persistently.
    else logger.warning("Auto-snap disabled.", .{});
}

/// Makes a snap of database every <delay>
/// with a min of <modify count>.
pub fn autosnap(
    storage: *Storage,
    logger: *log.Logger,
    conf: *const AutosnapConf,
    modc: *std.atomic.Value(u64),
) error{ThreadError}!void {
    const max_delay = conf.delay * std.time.ns_per_s;

    var timer = std.time.Timer.start() catch unreachable;

    // performs a snap when timer marks over config delay
    // and the count of queries is over config count.
    // when snap is finally performed resets the timer and
    // restart loop
    while (true) if (timer.read() >= max_delay and modc.load(.acquire) >= conf.count) {
        // save to the storage
        snap(storage, logger, true) catch {};

        modc.store(0, .release);
        timer.reset();
    } else std.Thread.sleep(1 * std.time.ns_per_s);
}

/// Attempts to save the storage to disk.
pub fn snap(storage: *Storage, logger: *log.Logger, comptime auto: bool) error{SaveFailed}!void {
    if (storage.conf.no_persistence) return;

    storage.save() catch |err| {
        @branchHint(.unlikely);

        const msg = switch (err) {
            error.OutOfMemory => signal.OOM(),
            error.OutOfDisk => signal.OOD(),
            else => ree.expandSaveError(err),
        };

        const src = if (auto) "Auto-snap" else "Snap";
        logger.warning("{s}: failed to save: {s}", .{ src, msg });

        // Snap fail
        return error.SaveFailed;
    };

    // Snap success
    const src = if (auto) "Auto-snap" else "Snap";
    logger.info("{s}: saved successful.", .{src});
}

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}
