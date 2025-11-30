// Blitz QUIC/HTTP3 Server with Load Balancer Support
// Run with: zig build run-quic
// Load balancer mode: zig build run-quic -- --lb config.toml

const std = @import("std");
const builtin = @import("builtin");
const io_uring = @import("io_uring.zig");
const udp_server = @import("quic/udp_server.zig");
const config = @import("config.zig");
const load_balancer = @import("load_balancer/load_balancer.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Blitz QUIC/HTTP3 Server v0.3\n", .{});
    std.debug.print("Supports: Origin Server & Load Balancer modes\n\n", .{});

    // Parse command-line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.next();

    var port: u16 = 8443;
    var is_load_balancer_mode = false;
    var config_path: ?[]const u8 = null;

    // Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--lb") or std.mem.eql(u8, arg, "-L")) {
            is_load_balancer_mode = true;
            if (args.next()) |path| {
                config_path = path;
            } else {
                config_path = "lb.toml";
            }
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (args.next()) |port_str| {
                port = try std.fmt.parseInt(u16, port_str, 10);
            } else {
                std.debug.print("Error: --port requires a value\n", .{});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            const port_str = arg["--port=".len..];
            port = try std.fmt.parseInt(u16, port_str, 10);
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            printUsage();
            return error.InvalidArguments;
        }
    }

    // Initialize io_uring (required for both modes)
    if (builtin.os.tag != .linux) {
        std.log.err("Blitz server requires Linux (io_uring support)", .{});
        return error.UnsupportedPlatform;
    }

    try io_uring.init();
    defer io_uring.deinit();

    // Start server based on mode
    if (is_load_balancer_mode) {
        // Load Balancer Mode
        const cfg_path = config_path orelse "lb.toml";
        std.debug.print("Loading load balancer config: {s}\n", .{cfg_path});

        var cfg = try config.loadConfig(allocator, cfg_path);
        defer cfg.deinit();

        if (cfg.mode != .load_balancer) {
            std.debug.print("Warning: Config mode is not 'load_balancer', overriding\n", .{});
            cfg.mode = .load_balancer;
        }

        std.debug.print("Starting QUIC/HTTP3 Load Balancer\n", .{});
        std.debug.print("Listen: {s}:{d}\n", .{cfg.listen_addr, cfg.listen_port});
        std.debug.print("Backends: {}\n", .{cfg.backends.items.len});

        for (cfg.backends.items, 0..) |backend, i| {
            std.debug.print("  [{d}] {s}:{d} (weight: {})\n", .{
                i + 1, backend.host, backend.port, backend.weight
            });
            if (backend.health_check_path) |path| {
                std.debug.print("      Health check: {s}\n", .{path});
            }
        }
        std.debug.print("\n", .{});

        var lb = try load_balancer.LoadBalancer.initFromConfig(allocator, cfg);
        defer lb.deinit();

        std.log.info("Load balancer started successfully", .{});
        try lb.serve(cfg.listen_addr, cfg.listen_port);

    } else {
        // Origin Server Mode (default)
        std.debug.print("Starting QUIC Origin Server\n", .{});
        std.debug.print("Listen: 0.0.0.0:{d} (UDP)\n", .{port});
        std.debug.print("Mode: Origin Server (single instance)\n\n", .{});

        std.log.info("Origin server started on port {}", .{port});
        try udp_server.runQuicServer(&io_uring.ring, port);
    }
}

fn printUsage() void {
    std.debug.print(
        \\Blitz QUIC/HTTP3 Server v0.3
        \\
        \\Usage:
        \\  Origin Server Mode (default):
        \\    blitz-quic [--port PORT]
        \\
        \\  Load Balancer Mode:
        \\    blitz-quic --lb [CONFIG_FILE]
        \\    blitz-quic -L [CONFIG_FILE]
        \\
        \\Options:
        \\  -p, --port PORT    UDP port to listen on (default: 8443)
        \\  -L, --lb [FILE]    Enable load balancer mode (default config: lb.toml)
        \\  -h, --help         Show this help message
        \\
        \\Examples:
        \\  blitz-quic                           # Origin server on port 8443
        \\  blitz-quic --port 9443              # Origin server on port 9443
        \\  blitz-quic --lb                     # Load balancer with lb.toml
        \\  blitz-quic --lb my-config.toml      # Load balancer with custom config
        \\
        \\For load balancer configuration, see lb.example.toml
        \\
    , .{});
}

