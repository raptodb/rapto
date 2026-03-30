//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of build system.

const std = @import("std");

const defaultSystemLibs = [_][]const u8{"lz4"};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "raptodb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rapto.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    linkDefaultLibs(exe);

    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = false,
        }),
    });
    linkDefaultLibs(lib_unit_tests);

    // add step for testing
    const run_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    b.installArtifact(exe);
}

inline fn linkDefaultLibs(compile: *std.Build.Step.Compile) void {
    compile.linkLibC();
    inline for (defaultSystemLibs) |lib| {
        compile.linkSystemLibrary(lib);
    }
}
