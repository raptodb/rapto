//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of build system.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "raptodb",
        .root_module = exe_mod,
    });
    exe.root_module.link_libc = true;

    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = target,
            .optimize = .Debug,
            .single_threaded = false,
        }),
    });
    lib_unit_tests.root_module.link_libc = true;

    const run_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    b.installArtifact(exe);
}
