//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of build system.

const std = @import("std");
const Translator = @import("translate_c").Translator;

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
            // .strip = false, // For debug symbols
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
            .optimize = .debug,
            .single_threaded = false,
            .link_libc = true,
        }),
        .use_llvm = true,
        .use_lld = true,
    });

    zprof(b, unit_tests.root_module);
    mimalloc(b, unit_tests.root_module);
    rapidhash(b, unit_tests.root_module, target);

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const install_tests = b.addInstallArtifact(unit_tests, .{
        .dest_dir = .{ .override = .bin },
        .dest_sub_path = "test-bin",
    });

    const run_coverage = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--include-pattern=rapto/src",
        "--exclude-line=unreachable",
        b.pathJoin(&.{ b.root.sub_path, "zig-out", "cov" }),
        b.pathJoin(&.{ b.root.sub_path, "zig-out", "bin", "test-bin" }),
    });
    run_coverage.step.dependOn(&install_tests.step);
    const cover_step = b.step("coverage", "Generate test coverage report");
    cover_step.dependOn(&run_coverage.step);

    const lib = b.addLibrary(.{
        .name = "rapto-client",
        .root_module = b.addModule("rapto", .{
            .root_source_file = b.path("src/Client.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .static,
    });

    b.installArtifact(lib);
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
    const translate_c = b.dependency("translate_c", .{});
    const translator: Translator = .init(translate_c, .{
        .c_source_file = rapidhash_dep.path("rapidhash.h"),
        .target = target,
        .optimize = .fast,
    });
    module.addImport("rapidhash", translator.mod);
}
