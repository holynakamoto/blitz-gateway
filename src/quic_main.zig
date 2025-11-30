// Blitz QUIC/HTTP3 Server with Load Balancer Support
// Run with: zig build run-quic
// Load balancer mode: zig build run-quic -- --lb config.toml

const std = @import("std");
const builtin = @import("builtin");
const io_uring = @import("io_uring.zig");
const udp_server = @import("quic/udp_server.zig");
const config = @import("config.zig");
const load_balancer = @import("load_balancer/load_balancer.zig");
const rate_limit = @import("rate_limit.zig");
const graceful_reload = @import("graceful_reload.zig");
const metrics = @import("metrics.zig");

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
    var enable_graceful_reload = true;

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

    // Determine config path
    const cfg_path = if (is_load_balancer_mode)
        config_path orelse "lb.toml"
    else
        config_path orelse "config.toml";

    // Load initial configuration
    var current_config = if (is_load_balancer_mode) blk: {
        std.debug.print("Loading load balancer config: {s}\n", .{cfg_path});
        var cfg = try config.loadConfig(allocator, cfg_path);
        if (cfg.mode != .load_balancer) {
            std.debug.print("Warning: Config mode is not 'load_balancer', overriding\n", .{});
            cfg.mode = .load_balancer;
        }
        break :blk cfg;
    } else blk: {
        // For origin server, create minimal config
        std.debug.print("Using default origin server config\n", .{});
        var cfg = config.Config.init(allocator);
        cfg.mode = .origin;
        break :blk cfg;
    };
    defer current_config.deinit();

    // Initialize graceful reload if enabled
    var reload_manager = if (enable_graceful_reload and builtin.os.tag == .linux) blk: {
        std.debug.print("Initializing graceful reload support...\n", .{});
        var gr = try graceful_reload.GracefulReload.init(allocator, current_config);
        current_config = config.Config.init(allocator); // Reset to empty since it's now owned by reload manager
        break :blk gr;
    } else blk: {
        std.debug.print("Graceful reload not available (requires Linux)\n", .{});
        break :blk null;
    };
    defer if (reload_manager) |*rm| rm.deinit();
    defer if (metrics_server) |*ms| ms.stop();
    defer if (blitz_metrics) |*bm| bm.deinit();

    // Set reload callback
    if (reload_manager) |*rm| {
        rm.setReloadCallback(&reloadCallback);
    }

    // Initialize metrics if enabled
    var blitz_metrics: ?metrics.BlitzMetrics = null;
    var metrics_server: ?metrics.MetricsServer = null;
    if (cfg.metrics.enabled) {
        blitz_metrics = try metrics.BlitzMetrics.init(allocator);
        metrics_server = metrics.MetricsServer.init(allocator, &blitz_metrics.?.registry);

        if (cfg.metrics.prometheus_enabled) {
            try metrics_server.?.start(cfg.metrics.port);
            std.debug.print("Metrics server started on port {}\n", .{cfg.metrics.port});
            std.debug.print("Prometheus metrics: http://localhost:{}/metrics\n", .{cfg.metrics.port});
        }
    }

    // Main server loop with reload support
    var server_running = true;
    while (server_running) {
        const cfg = if (reload_manager) |rm|
            rm.getCurrentConfig()
        else
            &current_config;

        if (cfg.mode == .load_balancer) {
            try runLoadBalancer(allocator, cfg, if (blitz_metrics) |*bm| bm else null);
        } else {
            try runOriginServer(allocator, port);
        }

        // Check for reload signal
        if (reload_manager) |*rm| {
            if (try rm.checkForReloadSignal()) |reload_req| {
                std.log.info("Reload signal received ({s}), restarting server...", .{
                    @tagName(reload_req.signal)
                });

                // Load new configuration
                var new_config = try config.loadConfig(allocator, cfg_path);
                errdefer new_config.deinit();

                if (new_config.mode == .load_balancer and cfg.mode != .load_balancer) {
                    std.debug.print("Switching to load balancer mode\n", .{});
                } else if (new_config.mode == .origin and cfg.mode != .origin) {
                    std.debug.print("Switching to origin server mode\n", .{});
                }

                // Perform reload
                try rm.performReload(cfg_path);
                std.log.info("Configuration reloaded, server restarting with new config", .{});

                // Continue loop to restart with new config
                continue;
            }
        }

        // If we reach here without reload, server exited normally
        server_running = false;
    }
}

/// Reload callback function
fn reloadCallback(new_config: *config.Config) anyerror!void {
    std.log.info("Reload callback: New configuration applied", .{});

    if (new_config.mode == .load_balancer) {
        std.log.info("Load balancer config: {} backends, listen on {s}:{}",
            .{new_config.backends.items.len, new_config.listen_addr, new_config.listen_port});

        for (new_config.backends.items, 0..) |backend, i| {
            std.log.info("  Backend [{}]: {s}:{} (weight: {})",
                .{i + 1, backend.host, backend.port, backend.weight});
        }
    }
}

/// Run load balancer server
fn runLoadBalancer(allocator: std.mem.Allocator, cfg: *const config.Config, blitz_metrics: ?*metrics.BlitzMetrics) !void {
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

    if (cfg.rate_limit.global_rps != null or cfg.rate_limit.per_ip_rps != null) {
        std.debug.print("Rate limiting: ", .{});
        if (cfg.rate_limit.global_rps) |rps| {
            std.debug.print("global={} RPS ", .{rps});
        }
        if (cfg.rate_limit.per_ip_rps) |rps| {
            std.debug.print("per-ip={} RPS ", .{rps});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("\n", .{});

    var lb = try load_balancer.LoadBalancer.initFromConfig(allocator, cfg.*);
    defer lb.deinit();

    // Initialize rate limiter if configured
    var rate_limiter = if (cfg.rate_limit.global_rps != null or cfg.rate_limit.per_ip_rps != null)
        try rate_limit.RateLimiter.init(allocator, cfg.rate_limit)
    else
        null;
    defer if (rate_limiter) |*rl| rl.deinit();

    std.log.info("Load balancer started successfully", .{});
    try lb.serve(cfg.listen_addr, cfg.listen_port);
}

/// Run origin server
fn runOriginServer(allocator: std.mem.Allocator, port: u16) !void {
    _ = allocator; // Not used in current implementation

    std.debug.print("Starting QUIC Origin Server\n", .{});
    std.debug.print("Listen: 0.0.0.0:{d} (UDP)\n", .{port});
    std.debug.print("Mode: Origin Server (single instance)\n\n", .{});

    std.log.info("Origin server started on port {}", .{port});
    try udp_server.runQuicServer(&io_uring.ring, port);
}

fn printUsage() void {
    std.debug.print(
        \\Blitz QUIC/HTTP3 Server v0.4 - Production Ready
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
        \\Graceful Reload (Linux only):
        \\  Send SIGHUP to reload configuration without restart
        \\  kill -HUP $(pidof blitz-quic)
        \\
        \\Examples:
        \\  blitz-quic                           # Origin server on port 8443
        \\  blitz-quic --port 9443              # Origin server on port 9443
        \\  blitz-quic --lb                     # Load balancer with lb.toml
        \\  blitz-quic --lb my-config.toml      # Load balancer with custom config
        \\
        \\Configuration files:
        \\  lb.example.toml    - Load balancer configuration template
        \\  lb.toml           - Active load balancer configuration
        \\
    , .{});
}

