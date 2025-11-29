const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig 0.13.0+ compatible build
    const exe = b.addExecutable(.{
        .name = "blitz",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,  // Strip debug symbols to avoid linker issues
    });

    // Link against libc
    exe.linkLibC();
    
    // Link liburing on Linux (conditional linking)
    if (target.result.os.tag == .linux) {
        // Add C wrapper source first
        // Link liburing first
        exe.linkSystemLibrary("uring");
        // Add C wrapper source after linking
        exe.addCSourceFile(.{ .file = b.path("src/bind_wrapper.c"), .flags = &.{"-Wl,--no-as-needed"} });
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run Blitz");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

