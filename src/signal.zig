//! BSD 3-Clause License
//!
//! Copyright (c) raptodb
//! Copyright (c) Andrea Vaccaro
//! All rights reserved.
//!
//! Redistribution and use in source and binary forms, with or without
//! modification, are permitted provided that the following conditions are met:
//!
//! 1. Redistributions of ource code must retain the above copyright notice, this
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
//! It contains the implementation of signal handler and error management.

const std = @import("std");

const snap = @import("snap.zig");
const log = @import("log.zig");

const Storage = @import("storage.zig").Storage;

const SIGINT = std.posix.system.SIG.INT;
const SIGABRT = std.posix.system.SIG.ABRT;
const SIGTERM = std.posix.system.SIG.TERM;

/// Global SIGABRT reason. The context can be
/// OutOfMemory (OOM), OutOfDisk (OOD) or Unexpected Error (UE).
var ABRT_ctx: enum { OOM, OOD, UE } = .UE;

/// Signal handler for SIGINT, SIGABRT and SIGTERM.
pub fn hsignal() void {
    const handler = struct {
        fn inner(sig: i32) callconv(.c) void {
            var stderr = std.fs.File.stderr().writerStreaming(&.{});

            const msg = switch (sig) {
                SIGINT => return,
                SIGABRT => switch (ABRT_ctx) {
                    .OOM => "OUT-OF-MEMORY: no RAM space. EXIT.\n",
                    .OOD => "OUT-OF-DISK: no disk space. EXIT. \n",
                    .UE => "UNEXPECTED ERROR. EXIT.           \n",
                },
                SIGTERM => "SIGTERM received. EXIT.           \n",
                else => unreachable,
            };

            stderr.interface.writeAll(msg) catch {};
        }
    }.inner;

    // setup for sigaction
    const s_sigint: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    std.posix.sigaction(SIGINT, &s_sigint, null);
    std.posix.sigaction(SIGABRT, &s_sigint, null);
    std.posix.sigaction(SIGTERM, &s_sigint, null);
}

/// Reports SIGABRT caused by Out Of Memory (OOM).
/// OOM is runned when there is no RAM space.
/// This invoke signal handler with OOM mark.
pub inline fn OOM() noreturn {
    @branchHint(.cold);
    ABRT_ctx = .OOM;
    std.posix.abort();
}

/// Reports SIGABRT caused by Out Of Disk (OOD).
/// OOD is runned when there is no disk space.
/// This invoke signal handler with OOD mark.
pub inline fn OOD() noreturn {
    @branchHint(.cold);
    ABRT_ctx = .OOD;
    std.posix.abort();
}

pub fn toRawTermios() std.c.termios {
    var old_termios: std.c.termios = undefined;
    _ = std.c.tcgetattr(0, &old_termios);

    var raw = old_termios;
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;

    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;

    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

    _ = std.c.tcsetattr(0, .FLUSH, &raw);

    return old_termios;
}

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}
