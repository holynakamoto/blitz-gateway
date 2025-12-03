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
            .file = b.path("src/core/bind_wrapper.c"),
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

        // Add picotls include paths (needed for openssl_wrapper.c)
        exe.addIncludePath(b.path("deps/picotls/include"));
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

    // Foundation validation tests - REMOVED (validate_foundation.zig deleted)
    // Load balancer tests - REMOVED (duplicate test files deleted, use src/ directly)
    // Load balancer tests removed (duplicate test files deleted)

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

    // QUIC standalone server executable - REMOVED (quic_main.zig deleted, use main.zig instead)

    // QUIC Handshake Server (full TLS integration)
    // Create a new module with src/main.zig as root, then override entry point
    const quic_handshake_server_module = b.addModule("quic_handshake_server", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });
    const quic_handshake_server_exe = b.addExecutable(.{
        .name = "quic_handshake_server",
        .root_module = quic_handshake_server_module,
    });
    quic_handshake_server_exe.linkLibC();
    if (target.result.os.tag == .linux) {
        quic_handshake_server_exe.linkSystemLibrary("ssl");
        quic_handshake_server_exe.linkSystemLibrary("crypto");
        quic_handshake_server_exe.linkSystemLibrary("uring");
        quic_handshake_server_exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
        quic_handshake_server_exe.addIncludePath(.{ .cwd_relative = "src" });
        quic_handshake_server_exe.addIncludePath(b.path("deps/picotls/include"));
    }
    b.installArtifact(quic_handshake_server_exe);

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

    // Rate limiting tests
    const rate_limit_tests = b.addTest(.{
        .root_module = b.addModule("rate_limit_root", .{
            .root_source_file = b.path("tests/unit/rate_limit/rate_limit_test.zig"),
            .target = target,
        }),
    });

    rate_limit_tests.linkLibC();

    const run_rate_limit_tests = b.addRunArtifact(rate_limit_tests);
    const rate_limit_test_step = b.step("test-rate-limit", "Run rate limiting tests");
    rate_limit_test_step.dependOn(&run_rate_limit_tests.step);

    // eBPF benchmark tests
    const ebpf_benchmark_tests = b.addTest(.{
        .root_module = b.addModule("ebpf_benchmark_root", .{
            .root_source_file = b.path("tests/unit/ebpf/ebpf_benchmark_test.zig"),
            .target = target,
        }),
    });

    ebpf_benchmark_tests.linkLibC();

    const run_ebpf_benchmark_tests = b.addRunArtifact(ebpf_benchmark_tests);
    const ebpf_benchmark_test_step = b.step("test-ebpf-benchmark", "Run eBPF benchmark tests");
    ebpf_benchmark_test_step.dependOn(&run_ebpf_benchmark_tests.step);

    // Bench step - run benchmark tests
    const bench_step = b.step("bench", "Run benchmark tests");
    bench_step.dependOn(ebpf_benchmark_test_step);

    // Graceful reload tests
    const graceful_reload_tests = b.addTest(.{
        .root_module = b.addModule("graceful_reload_root", .{
            .root_source_file = b.path("tests/integration/graceful_reload_test.zig"),
            .target = target,
        }),
    });

    graceful_reload_tests.linkLibC();

    const run_graceful_reload_tests = b.addRunArtifact(graceful_reload_tests);
    const graceful_reload_test_step = b.step("test-graceful-reload", "Run graceful reload tests");
    graceful_reload_test_step.dependOn(&run_graceful_reload_tests.step);

    // Metrics tests
    const metrics_tests = b.addTest(.{
        .root_module = b.addModule("metrics_root", .{
            .root_source_file = b.path("tests/unit/metrics/metrics_test.zig"),
            .target = target,
        }),
    });

    metrics_tests.linkLibC();

    const run_metrics_tests = b.addRunArtifact(metrics_tests);
    const metrics_test_step = b.step("test-metrics", "Run metrics tests");
    metrics_test_step.dependOn(&run_metrics_tests.step);

    // JWT tests
    const jwt_tests = b.addTest(.{
        .root_module = b.addModule("jwt_root", .{
            .root_source_file = b.path("src/auth/jwt.zig"),
            .target = target,
        }),
    });
    jwt_tests.linkLibC();

    const run_jwt_tests = b.addRunArtifact(jwt_tests);
    const jwt_test_step = b.step("test-jwt", "Run JWT tests");
    jwt_test_step.dependOn(&run_jwt_tests.step);

    // WASM plugin tests
    const wasm_tests = b.addTest(.{
        .root_module = b.addModule("wasm_test", .{
            .root_source_file = b.path("tests/unit/wasm/wasm_test.zig"),
            .target = target,
        }),
    });
    wasm_tests.linkLibC();

    const run_wasm_tests = b.addRunArtifact(wasm_tests);
    const wasm_test_step = b.step("test-wasm", "Run WASM plugin tests");
    wasm_test_step.dependOn(&run_wasm_tests.step);

    // HTTP server - REMOVED (consolidated into main.zig)
    // Use: zig build run -- --mode http

    // Documentation generation step (placeholder)
    // Note: Actual docs generation would require creating a lib artifact with emit_docs
    // For now, this step exists to satisfy the CI workflow
    _ = b.step("docs", "Generate documentation");
    // Docs generation not yet implemented - step exists for CI compatibility

    // .deb package build step using nfpm
    const deb_step = b.step("deb", "Build .deb package using nfpm");
    deb_step.dependOn(b.getInstallStep()); // Ensure binary is built first

    // Create a run command to build the deb package
    const deb_cmd = b.addSystemCommand(&[_][]const u8{
        "bash", "-c",
        \\#!/bin/bash
        \\set -euo pipefail
        \\echo "Building .deb package..."
        \\# Check if nfpm is available (should be installed in CI)
        \\if ! command -v nfpm &> /dev/null; then
        \\    echo "ERROR: nfpm not found. Please install nfpm:"
        \\    echo "  go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest"
        \\    echo "  # or"
        \\    echo "  sudo apt-get install -y nfpm"
        \\    exit 1
        \\fi
        \\# Copy binary to expected location for nfpm
        \\mkdir -p zig-out/bin zig-out/deb
        \\cp zig-out/bin/blitz zig-out/bin/blitz-quic
        \\# Build package
        \\nfpm pkg --packager deb --target zig-out/deb/ --config packaging/nfpm.yaml
        \\echo "✅ .deb package built successfully!"
        \\echo "📦 Package location: zig-out/deb/"
        \\ls -la zig-out/deb/
    });
    deb_step.dependOn(&deb_cmd.step);
}
