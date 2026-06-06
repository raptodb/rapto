//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of main.

const std = @import("std");
const cli = @import("cli.zig");
const zprof = @import("zprof.zig");
const log = std.log.scoped(.rapto);

pub const version = "0.1.0";

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
}
