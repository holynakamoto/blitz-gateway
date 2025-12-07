const std = @import("std");
const builtin = @import("builtin");

// Build note: We use liburing-ffi.a (built from source in the VM) for proper FFI symbol resolution.
// Per PRD: The FFI variant exports all io_uring functions as regular symbols (not inline),
// which resolves undefined symbol errors when cross-compiling with Zig.

// Helper function to link liburing-ffi for proper FFI symbol resolution
// Per PRD: liburing-ffi.a exports all functions as regular symbols (not inline)
// This resolves undefined symbol errors like __io_uring_get_cqe, io_uring_queue_init, etc.
// Helper function to link liburing-ffi for proper FFI symbol resolution
fn linkLiburingFFI(exe: *std.Build.Step.Compile) void {
    // Link liburing-ffi for proper symbol resolution
    exe.addObjectFile(.{ .cwd_relative = "/usr/local/lib/liburing-ffi.a" });
    exe.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
}

// Helper function to add all C source files to an executable
fn addCSourceFiles(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .linux) return;

    // Add src/core to include path
    exe.addIncludePath(.{ .cwd_relative = "src/core" });

    // liburing headers are installed to /usr/local/include by the build script
    // Note: We still need the swab.h stub for cross-compilation (in vendor/liburing/src/include/linux/swab.h)
    exe.addIncludePath(.{ .cwd_relative = "vendor/liburing/src/include" }); // For swab.h stub only

    // Add core C files
    exe.addCSourceFile(.{
        .file = b.path("src/core/bind_wrapper.c"),
        .flags = &.{ "-std=c99", "-fno-sanitize=undefined" },
    });

    // Link liburing-ffi for proper FFI symbol resolution
    // Per PRD: This resolves undefined symbol errors from inline functions
    linkLiburingFFI(exe);

    // Picoquic integration - DISABLED (HTTP/3 now handled by Caddy)
    // Note: Picoquic sources are no longer compiled since we use Caddy for HTTP/3
    // addPicoquicSources(b, exe);

    // Help Zig find the right architecture-specific headers
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/aarch64-linux-gnu" });
    // Add /usr/include for Linux kernel headers (linux/swab.h)
    exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
}

// MsQuic linking removed - HTTP/3 is now handled by Caddy (see scripts/bench/bench.sh)

// Helper function to add Picoquic C sources and dependencies
// Note: This function will cause build errors if Picoquic is not cloned
// To enable Picoquic: 1) Run ./deps/picoquic_setup.sh, 2) Uncomment addPicoquicSources() call in addCSourceFiles()
fn addPicoquicSources(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const picoquic_dir = "deps/picoquic";
    const picotls_dir = "deps/picotls";

    // Add include paths for Picoquic and Picotls
    // Order matters: system headers first to avoid macro redefinition
    exe.addIncludePath(.{ .cwd_relative = "/usr/include" }); // System headers first
    exe.addIncludePath(.{ .cwd_relative = "/usr/local/include" }); // For installed picotls headers
    exe.addIncludePath(.{ .cwd_relative = picoquic_dir }); // Picoquic headers
    exe.addIncludePath(.{ .cwd_relative = picotls_dir }); // Picotls headers

    // Common C flags for Picoquic
    // Note: -Wno-macro-redefined to suppress macro redefinition warnings from system headers
    // -D_GNU_SOURCE ensures pthread types are available
    const cflags = &.{
        "-std=c99",
        "-fno-sanitize=undefined",
        "-DPICOQUIC_USE_PICOTLS=1",
        "-D_GNU_SOURCE", // Required for pthread types on Linux
        "-Wno-macro-redefined",
        "-Wno-unused-parameter",
        "-Wno-unused-variable",
        "-Wno-deprecated-declarations",
    };

    // Main Picoquic source files (from CMakeLists.txt, using Picotls backend)
    const picoquic_sources = [_][]const u8{
        "picoquic/bbr.c",
        "picoquic/bbr1.c",
        "picoquic/bytestream.c",
        "picoquic/cc_common.c",
        "picoquic/config.c",
        "picoquic/cubic.c",
        "picoquic/c4.c",
        "picoquic/ech.c",
        "picoquic/error_names.c",
        "picoquic/fastcc.c",
        "picoquic/frames.c",
        "picoquic/intformat.c",
        "picoquic/logger.c",
        "picoquic/logwriter.c",
        "picoquic/loss_recovery.c",
        "picoquic/newreno.c",
        "picoquic/pacing.c",
        "picoquic/packet.c",
        "picoquic/paths.c",
        "picoquic/performance_log.c",
        "picoquic/picohash.c",
        "picoquic/picoquic_lb.c",
        "picoquic/picoquic_ptls_minicrypto.c", // Picotls minicrypto backend
        "picoquic/picosocks.c",
        "picoquic/picosplay.c",
        "picoquic/port_blocking.c",
        "picoquic/prague.c",
        "picoquic/quicctx.c",
        "picoquic/register_all_cc_algorithms.c",
        "picoquic/sacks.c",
        "picoquic/sender.c",
        "picoquic/sim_link.c",
        "picoquic/siphash.c",
        "picoquic/sockloop.c",
        "picoquic/spinbit.c",
        "picoquic/ticket_store.c",
        "picoquic/timing.c",
        "picoquic/tls_api.c",
        "picoquic/token_store.c",
        "picoquic/transport.c",
        "picoquic/unified_log.c",
        "picoquic/util.c",
    };

    // Add Picoquic source files
    for (picoquic_sources) |source| {
        const full_path = b.fmt("{s}/{s}", .{ picoquic_dir, source });
        exe.addCSourceFile(.{
            .file = b.path(full_path),
            .flags = cflags,
        });
    }

    // Link required system libraries for Picoquic/Picotls
    exe.linkSystemLibrary("ssl");
    exe.linkSystemLibrary("crypto");
    exe.linkSystemLibrary("dl");
    exe.linkSystemLibrary("pthread");

    // Link Picotls static libraries if available
    exe.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    exe.addObjectFile(.{ .cwd_relative = "/usr/local/lib/libpicotls.a" });
    exe.addObjectFile(.{ .cwd_relative = "/usr/local/lib/libpicotls-minicrypto.a" });
}

pub fn build(b: *std.Build) void {
    // Explicitly set default target to Linux aarch64 (required for cross-compilation)
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .gnu,
        },
    });
    _ = b.standardOptimizeOption(.{}); // Optimize options are used via command line

    // Picoquic integration - C-based QUIC implementation via FFI

    const root_module = b.addModule("root", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });
    const exe = b.addExecutable(.{
        .name = "blitz",
        .root_module = root_module,
    });

    // Link libc (required for C interop)
    exe.linkLibC();

    // Platform-specific configuration
    if (target.result.os.tag == .linux) {
        // Add architecture-specific library paths for Ubuntu/Debian
        // Support both x86_64 and aarch64 architectures
        exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/aarch64-linux-gnu" });
        exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        exe.addLibraryPath(.{ .cwd_relative = "/lib/x86_64-linux-gnu" });
        exe.addLibraryPath(.{ .cwd_relative = "/lib/aarch64-linux-gnu" });
        exe.addLibraryPath(.{ .cwd_relative = "/lib" });

        // Picoquic integration - C-based QUIC implementation via FFI
        // NOTE: liburing-ffi is linked via addCSourceFiles() -> linkLiburingFFI()
        // We use liburing-ffi.a (not liburing.a) for proper FFI symbol resolution
        // Picoquic sources and dependencies are added via addCSourceFiles() -> addPicoquicSources()

        // Add all C source files (io_uring bindings)
        addCSourceFiles(b, exe, target);

        // Note: MsQuic linking removed - HTTP/3 is handled by Caddy

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
        // Link liburing-ffi for unit tests that use io_uring
        linkLiburingFFI(unit_tests);
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
        \\echo "Checking for nfpm..."
        \\
        \\# Try to install nfpm if not available
        \\if ! command -v nfpm &> /dev/null; then
        \\    echo "nfpm not found, attempting installation..."
        \\    # Try apt first
        \\    if command -v apt-get &> /dev/null; then
        \\        echo "Trying apt-get install nfpm..."
        \\        if apt-get update && apt-get install -y nfpm; then
        \\            echo "✅ nfpm installed via apt"
        \\        else
        \\            echo "apt install failed, trying manual download..."
        \\        fi
        \\    fi
        \\
        \\    # Manual installation if apt failed
        \\    if ! command -v nfpm &> /dev/null; then
        \\        echo "Downloading nfpm manually..."
        \\        curl -fL https://github.com/goreleaser/nfpm/releases/download/v2.35.3/nfpm_2.35.3_Linux_x86_64.tar.gz -o /tmp/nfpm.tar.gz || {
        \\            echo "ERROR: Failed to download nfpm"
        \\            exit 1
        \\        }
        \\        tar -xzf /tmp/nfpm.tar.gz -C /tmp || {
        \\            echo "ERROR: Failed to extract nfpm"
        \\            exit 1
        \\        }
        \\        mv /tmp/nfpm /usr/local/bin/nfpm || {
        \\            echo "ERROR: Failed to install nfpm"
        \\            exit 1
        \\        }
        \\        chmod +x /usr/local/bin/nfpm
        \\        echo "✅ nfpm installed manually"
        \\    fi
        \\fi
        \\
        \\# Verify nfpm works
        \\if ! nfpm version; then
        \\    echo "ERROR: nfpm installation failed or is not working"
        \\    exit 1
        \\fi
        \\
        \\echo "✅ nfpm ready"
        \\
        \\# Copy binary to expected location for nfpm
        \\mkdir -p zig-out/bin zig-out/deb
        \\if [ ! -f zig-out/bin/blitz ]; then
        \\    echo "ERROR: blitz binary not found at zig-out/bin/blitz"
        \\    exit 1
        \\fi
        \\cp zig-out/bin/blitz zig-out/bin/blitz-quic
        \\echo "✅ Binary prepared for packaging"
        \\
        \\# Build package
        \\echo "Building .deb package with nfpm..."
        \\nfpm pkg --packager deb --target zig-out/deb/ --config packaging/nfpm.yaml
        \\
        \\echo "✅ .deb package built successfully!"
        \\echo "📦 Package location: zig-out/deb/"
        \\ls -la zig-out/deb/
    });
    deb_step.dependOn(&deb_cmd.step);
}
