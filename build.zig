const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{}); // Optimize options are used via command line

    const root_module = b.addModule("root", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });
    const exe = b.addExecutable(.{
        .name = "blitz",
        .root_module = root_module,
    });
    // Target and optimize are set via standardTargetOptions/standardOptimizeOption above

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
    const test_root_module = b.addModule("test_root", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });
    const unit_tests = b.addTest(.{
        .root_module = test_root_module,
    });

    unit_tests.linkLibC();
    
    if (target.result.os.tag == .linux) {
        unit_tests.linkSystemLibrary("uring");
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    
    // Foundation validation tests
    const foundation_root_module = b.addModule("foundation_root", .{
        .root_source_file = b.path("src/validate_foundation.zig"),
        .target = target,
    });
    const foundation_tests = b.addTest(.{
        .root_module = foundation_root_module,
    });

    foundation_tests.linkLibC();
    
    if (target.result.os.tag == .linux) {
        foundation_tests.linkSystemLibrary("ssl");
        foundation_tests.linkSystemLibrary("crypto");
    }

    const run_foundation_tests = b.addRunArtifact(foundation_tests);
    const foundation_test_step = b.step("test-foundation", "Run TLS/HTTP/2 foundation validation tests");
    foundation_test_step.dependOn(&run_foundation_tests.step);
    
    // Load balancer tests
    const load_balancer_root_module = b.addModule("load_balancer_root", .{
        .root_source_file = b.path("src/load_balancer/test.zig"),
        .target = target,
    });
    const load_balancer_tests = b.addTest(.{
        .root_module = load_balancer_root_module,
    });

    load_balancer_tests.linkLibC();

    const run_load_balancer_tests = b.addRunArtifact(load_balancer_tests);
    const load_balancer_test_step = b.step("test-load-balancer", "Run load balancer tests");
    load_balancer_test_step.dependOn(&run_load_balancer_tests.step);
    
    // QUIC tests
    const quic_root_module = b.addModule("quic_root", .{
        .root_source_file = b.path("src/quic/test.zig"),
        .target = target,
    });
    const quic_tests = b.addTest(.{
        .root_module = quic_root_module,
    });

    quic_tests.linkLibC();

    const run_quic_tests = b.addRunArtifact(quic_tests);
    const quic_test_step = b.step("test-quic", "Run QUIC packet parsing tests");
    quic_test_step.dependOn(&run_quic_tests.step);
    
    // QUIC frame tests
    const quic_frame_tests = b.addTest(.{
        .root_module = b.addModule("quic_frame_root", .{
            .root_source_file = b.path("src/quic/frames_test.zig"),
            .target = target,
        }),
    });

    quic_frame_tests.linkLibC();

    const run_quic_frame_tests = b.addRunArtifact(quic_frame_tests);
    const quic_frame_test_step = b.step("test-quic-frames", "Run QUIC frame parsing tests");
    quic_frame_test_step.dependOn(&run_quic_frame_tests.step);
    
    // QUIC packet generation tests
    const quic_packet_gen_tests = b.addTest(.{
        .root_module = b.addModule("quic_packet_gen_root", .{
            .root_source_file = b.path("src/quic/packet_gen_test.zig"),
            .target = target,
        }),
    });

    quic_packet_gen_tests.linkLibC();

    const run_quic_packet_gen_tests = b.addRunArtifact(quic_packet_gen_tests);
    const quic_packet_gen_test_step = b.step("test-quic-packet-gen", "Run QUIC packet generation tests");
    quic_packet_gen_test_step.dependOn(&run_quic_packet_gen_tests.step);
    
    // Simple packet generation test
    const quic_packet_simple_tests = b.addTest(.{
        .root_module = b.addModule("quic_packet_simple_root", .{
            .root_source_file = b.path("src/quic/packet_gen_simple_test.zig"),
            .target = target,
        }),
    });

    quic_packet_simple_tests.linkLibC();

    const run_quic_packet_simple_tests = b.addRunArtifact(quic_packet_simple_tests);
    const quic_packet_simple_test_step = b.step("test-quic-packet-simple", "Run simple QUIC packet generation test");
    quic_packet_simple_test_step.dependOn(&run_quic_packet_simple_tests.step);
}