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
        // Add architecture-specific library paths for Ubuntu/Debian
        // Docker containers use /usr/lib/x86_64-linux-gnu/
        exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        exe.addLibraryPath(.{ .cwd_relative = "/lib/x86_64-linux-gnu" });
        exe.addLibraryPath(.{ .cwd_relative = "/lib" });

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
        .root_source_file = b.path("tests/test.zig"),
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
        .root_source_file = b.path("tests/quic/test.zig"),
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
            .root_source_file = b.path("tests/quic/frames_test.zig"),
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
            .root_source_file = b.path("tests/quic/packet_gen_test.zig"),
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
            .root_source_file = b.path("tests/quic/packet_gen_simple_test.zig"),
            .target = target,
        }),
    });

    quic_packet_simple_tests.linkLibC();

    const run_quic_packet_simple_tests = b.addRunArtifact(quic_packet_simple_tests);
    const quic_packet_simple_test_step = b.step("test-quic-packet-simple", "Run simple QUIC packet generation test");
    quic_packet_simple_test_step.dependOn(&run_quic_packet_simple_tests.step);

    // QUIC standalone server executable
    const quic_server_root_module = b.addModule("quic_server_root", .{
        .root_source_file = b.path("src/quic_main.zig"),
        .target = target,
    });
    const quic_server_exe = b.addExecutable(.{
        .name = "blitz-quic",
        .root_module = quic_server_root_module,
    });

    quic_server_exe.linkLibC();

    if (target.result.os.tag == .linux) {
        // Add architecture-specific library paths for Ubuntu/Debian
        // Docker containers use /usr/lib/x86_64-linux-gnu/
        // In Zig 0.15.2, use .{ .cwd_relative = "/path" } for absolute paths
        quic_server_exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        quic_server_exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        quic_server_exe.addLibraryPath(.{ .cwd_relative = "/lib/x86_64-linux-gnu" });
        quic_server_exe.addLibraryPath(.{ .cwd_relative = "/lib" });

        // Link system libraries
        quic_server_exe.linkSystemLibrary("uring");
        quic_server_exe.linkSystemLibrary("ssl");
        quic_server_exe.linkSystemLibrary("crypto");

        quic_server_exe.addCSourceFile(.{
            .file = b.path("src/bind_wrapper.c"),
            .flags = &[_][]const u8{
                "-std=c99",
                "-D_GNU_SOURCE",
                "-fno-sanitize=undefined",
            },
        });

        quic_server_exe.addCSourceFile(.{
            .file = b.path("src/tls/openssl_wrapper.c"),
            .flags = &[_][]const u8{
                "-std=c99",
                "-D_GNU_SOURCE",
                "-fno-sanitize=undefined",
            },
        });

        quic_server_exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
        quic_server_exe.addIncludePath(.{ .cwd_relative = "src" });
    }

    b.installArtifact(quic_server_exe);

    const run_quic_server_cmd = b.addRunArtifact(quic_server_exe);
    const run_quic_server_step = b.step("run-quic", "Run standalone QUIC server on port 8443");
    run_quic_server_step.dependOn(&run_quic_server_cmd.step);

    // QUIC Handshake Server (full TLS integration)
    const quic_handshake_root_module = b.addModule("quic_handshake_root", .{
        .root_source_file = b.path("src/quic_handshake_server.zig"),
        .target = target,
    });
    const quic_handshake_exe = b.addExecutable(.{
        .name = "blitz-quic-handshake",
        .root_module = quic_handshake_root_module,
    });

    quic_handshake_exe.linkLibC();

    if (target.result.os.tag == .linux) {
        quic_handshake_exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        quic_handshake_exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        quic_handshake_exe.addLibraryPath(.{ .cwd_relative = "/lib/x86_64-linux-gnu" });
        quic_handshake_exe.addLibraryPath(.{ .cwd_relative = "/lib" });

        quic_handshake_exe.linkSystemLibrary("uring");
        // OpenSSL only used for certificate loading in minicrypto mode
        // Could be removed with more work, but acceptable for now
        quic_handshake_exe.linkSystemLibrary("ssl");
        quic_handshake_exe.linkSystemLibrary("crypto");

        quic_handshake_exe.addCSourceFile(.{
            .file = b.path("src/bind_wrapper.c"),
            .flags = &[_][]const u8{
                "-std=c99",
                "-D_GNU_SOURCE",
                "-fno-sanitize=undefined",
            },
        });

        quic_handshake_exe.addCSourceFile(.{
            .file = b.path("src/tls/openssl_wrapper.c"),
            .flags = &[_][]const u8{
                "-std=c99",
                // "-D_GNU_SOURCE", // Removed to avoid conflict with OpenSSL headers
                "-fno-sanitize=undefined",
            },
        });

        quic_handshake_exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
        quic_handshake_exe.addIncludePath(.{ .cwd_relative = "src" });

        // Critical: tell Zig where to find picotls headers
        quic_handshake_exe.addIncludePath(b.path("deps/picotls/include"));
        quic_handshake_exe.addIncludePath(b.path("deps/picotls/deps/micro-ecc"));

        // OpenSSL headers (architecture-specific location)
        quic_handshake_exe.addIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });

        // Link picotls C files - full set for TLS 1.3
        quic_handshake_exe.addCSourceFiles(.{
            .files = &.{
                "deps/picotls/lib/picotls.c",
                "deps/picotls/lib/openssl.c",
                "deps/picotls/lib/pembase64.c",
                "deps/picotls/lib/asn1.c",
                "deps/picotls/lib/certificate_compression.c",
                "deps/picotls/lib/ffx.c",
                "deps/picotls/lib/fusion.c",
                "deps/picotls/lib/hpke.c",
                "deps/picotls/lib/minicrypto-pem.c",
                "deps/picotls/lib/ptlsbcrypt.c",
                "deps/picotls/lib/uecc.c",
            },
            .flags = &[_][]const u8{
                "-std=c99",
                "-DPTLS_HAVE_OPENSSL=1",
                "-Wno-everything",
            },
        });
    }

    b.installArtifact(quic_handshake_exe);

    const run_quic_handshake_cmd = b.addRunArtifact(quic_handshake_exe);
    const run_quic_handshake_step = b.step("run-quic-handshake", "Run QUIC handshake server (full TLS)");
    run_quic_handshake_step.dependOn(&run_quic_handshake_cmd.step);

    // Transport parameters tests
    const transport_params_tests = b.addTest(.{
        .root_module = b.addModule("transport_params_root", .{
            .root_source_file = b.path("tests/quic/transport_params_test.zig"),
            .target = target,
        }),
    });

    transport_params_tests.linkLibC();

    const run_transport_params_tests = b.addRunArtifact(transport_params_tests);
    const transport_params_test_step = b.step("test-transport-params", "Run transport parameters tests");
    transport_params_test_step.dependOn(&run_transport_params_tests.step);

    // HTTP/3 integration tests
    const http3_integration_tests = b.addTest(.{
        .root_module = b.addModule("http3_integration_root", .{
            .root_source_file = b.path("tests/integration/http3_test.zig"),
            .target = target,
        }),
    });

    http3_integration_tests.linkLibC();

    const run_http3_integration_tests = b.addRunArtifact(http3_integration_tests);
    const http3_integration_test_step = b.step("test-http3-integration", "Run HTTP/3 integration tests");
    http3_integration_test_step.dependOn(&run_http3_integration_tests.step);

    // Load balancer integration tests
    const lb_integration_tests = b.addTest(.{
        .root_module = b.addModule("lb_integration_root", .{
            .root_source_file = b.path("tests/integration/load_balancer_integration_test.zig"),
            .target = target,
        }),
    });

    lb_integration_tests.linkLibC();

    const run_lb_integration_tests = b.addRunArtifact(lb_integration_tests);
    const lb_integration_test_step = b.step("test-lb-integration", "Run load balancer integration tests");
    lb_integration_test_step.dependOn(&run_lb_integration_tests.step);
}
