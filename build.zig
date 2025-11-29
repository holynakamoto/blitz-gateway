const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "blitz",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link libc (required for C interop)
    exe.linkLibC();

    // Platform-specific configuration
    if (target.result.os.tag == .linux) {
        // Link liburing
        exe.linkSystemLibrary("uring");
        
        // Link OpenSSL for TLS 1.3
        exe.linkSystemLibrary("ssl");
        exe.linkSystemLibrary("crypto");

        // Add C wrappers with proper flags
        exe.addCSourceFile(.{
            .file = b.path("src/bind_wrapper.c"),
            .flags = &[_][]const u8{
                "-std=c99",
                "-D_GNU_SOURCE",
                "-fno-sanitize=undefined",
            },
        });
        
        exe.addCSourceFile(.{
            .file = b.path("src/tls/openssl_wrapper.c"),
            .flags = &[_][]const u8{
                "-std=c99",
                "-D_GNU_SOURCE",
                "-fno-sanitize=undefined",
            },
        });

        // Add include paths for headers
        exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
        exe.addIncludePath(.{ .cwd_relative = "src" });
    }

    // Install the binary
    b.installArtifact(exe);

    // Run command
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

    unit_tests.linkLibC();
    
    if (target.result.os.tag == .linux) {
        unit_tests.linkSystemLibrary("uring");
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    
    // Foundation validation tests
    const foundation_tests = b.addTest(.{
        .root_source_file = b.path("src/validate_foundation.zig"),
        .target = target,
        .optimize = optimize,
    });

    foundation_tests.linkLibC();
    
    if (target.result.os.tag == .linux) {
        foundation_tests.linkSystemLibrary("ssl");
        foundation_tests.linkSystemLibrary("crypto");
    }

    const run_foundation_tests = b.addRunArtifact(foundation_tests);
    const foundation_test_step = b.step("test-foundation", "Run TLS/HTTP/2 foundation validation tests");
    foundation_test_step.dependOn(&run_foundation_tests.step);
}