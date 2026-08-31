//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of build system.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // This parameter only affects the executable.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "raptodb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = true,
        .use_lld = true,
    });

    exe.lto = .full;

    zprof(b, exe.root_module);
    mimalloc(b, exe.root_module);
    rapidhash(b, exe.root_module, target);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = target,
            .optimize = .Debug,
            .single_threaded = false,
            .link_libc = true,
        }),
    });

    rapidhash(b, unit_tests.root_module, target);

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    b.installArtifact(exe);
}

fn zprof(b: *std.Build, module: *std.Build.Module) void {
    const zprof_dep = b.dependency("zprof", .{});
    module.addImport("zprof", zprof_dep.module("zprof"));
}

fn mimalloc(b: *std.Build, module: *std.Build.Module) void {
    const mimalloc_dep = b.dependency("mimalloc", .{});
    module.addIncludePath(mimalloc_dep.path("include"));
    module.addCSourceFile(.{
        .file = mimalloc_dep.path("src/static.c"),
        .flags = &.{ "-DMI_STATIC_LIB", "-O3", "-flto" },
    });
}

fn rapidhash(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const rapidhash_dep = b.dependency("rapidhash", .{});
    const translated = b.addTranslateC(.{
        .root_source_file = rapidhash_dep.path("rapidhash.h"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    module.addImport("rapidhash", translated.createModule());
}
