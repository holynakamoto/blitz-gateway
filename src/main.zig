//! Blitz Gateway - High-performance QUIC/HTTP3 reverse proxy and load balancer
//!
//! Usage:
//!   zig build run                    # Run QUIC/HTTP3 server (default)
//!   zig build run -- --mode echo     # Run echo server demo
//!   zig build run -- --mode http     # Run HTTP/1.1 server with JWT
//!   zig build run -- --mode quic     # Run QUIC/HTTP3 server
//!   zig build run -- --lb config.toml # Run load balancer mode

const std = @import("std");
const builtin = @import("builtin");
const io_uring = @import("io_uring.zig");
const udp_server = @import("quic/udp_server.zig");
const config = @import("config/mod.zig");
const load_balancer = @import("load_balancer/mod.zig");
const rate_limit = @import("rate_limit.zig");
const graceful_reload = @import("graceful_reload.zig");
const metrics = @import("metrics.zig");

const Mode = enum {
    quic, // QUIC/HTTP3 server (default)
    echo, // Echo server demo
    http, // HTTP/1.1 server with JWT
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var mode: Mode = .quic;
    var config_path: ?[]const u8 = null;
    var port: ?u16 = null;

    // Simple argument parsing
    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--mode")) {
            if (i + 1 < args.len) {
                i += 1;
                if (std.mem.eql(u8, args[i], "echo")) {
                    mode = .echo;
                } else if (std.mem.eql(u8, args[i], "http")) {
                    mode = .http;
                } else if (std.mem.eql(u8, args[i], "quic")) {
                    mode = .quic;
                } else {
                    std.log.err("Unknown mode: {s}. Use: echo, http, or quic", .{args[i]});
                    return error.InvalidMode;
                }
            }
        } else if (std.mem.eql(u8, args[i], "--lb") or std.mem.eql(u8, args[i], "--config")) {
            if (i + 1 < args.len) {
                i += 1;
                config_path = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--port") or std.mem.eql(u8, args[i], "-p")) {
            if (i + 1 < args.len) {
                i += 1;
                port = try std.fmt.parseInt(u16, args[i], 10);
            }
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printUsage();
            return;
        }
        i += 1;
    }

    // Route to appropriate mode
    switch (mode) {
        .quic => try runQuicServer(allocator, config_path, port),
        .echo => try runEchoServer(port orelse 8080),
        .http => try runHttpServer(port orelse 8080),
    }
}

fn printUsage() void {
    std.debug.print(
        \\Blitz Gateway v0.6.0
        \\High-performance QUIC/HTTP3 reverse proxy and load balancer
        \\
        \\Usage:
        \\  zig build run [OPTIONS]
        \\
        \\Options:
        \\  --mode <mode>     Server mode: quic (default), echo, or http
        \\  --lb <config>     Load balancer mode with config file
        \\  --config <file>   Configuration file path
        \\  --port <port>     Port to listen on (default: 8443 for QUIC, 8080 for others)
        \\  --help, -h        Show this help message
        \\
        \\Examples:
        \\  zig build run                           # QUIC/HTTP3 server
        \\  zig build run -- --mode echo            # Echo server demo
        \\  zig build run -- --mode http            # HTTP/1.1 server
        \\  zig build run -- --lb config.toml       # Load balancer mode
        \\  zig build run -- --port 9000            # Custom port
        \\
    , .{});
}

fn runQuicServer(allocator: std.mem.Allocator, config_path: ?[]const u8, port: ?u16) !void {
    if (builtin.os.tag != .linux) {
        std.log.err("QUIC server requires Linux (io_uring support)", .{});
        return error.UnsupportedPlatform;
    }

    std.debug.print("Blitz QUIC/HTTP3 Server v0.6.0\n", .{});
    std.debug.print("================================\n\n", .{});

    // Initialize io_uring
    try io_uring.init();
    defer io_uring.deinit();

    const ring = &io_uring.ring;

    // Load configuration if provided
    if (config_path) |cfg_path| {
        std.debug.print("Loading configuration from: {s}\n", .{cfg_path});
        var cfg = try config.Config.loadConfig(allocator, cfg_path);
        defer cfg.deinit(allocator);

        if (cfg.mode == .load_balancer) {
            std.debug.print("Starting in Load Balancer mode\n", .{});
            try runLoadBalancerMode(allocator, &cfg);
            return;
        }
    }

    // Default: Run QUIC server on port 8443
    const listen_port = port orelse 8443;
    std.debug.print("Starting QUIC/HTTP3 server on port {d}...\n", .{listen_port});
    try udp_server.runQuicServer(ring, listen_port);
}

fn runEchoServer(port: u16) !void {
    if (builtin.os.tag != .linux) {
        std.log.err("Echo server requires Linux (io_uring support)", .{});
        return error.UnsupportedPlatform;
    }

    std.debug.print("Blitz Echo Server Demo\n", .{});
    std.debug.print("======================\n\n", .{});

    try io_uring.init();
    defer io_uring.deinit();

    std.log.info("Starting echo server on port {d}...", .{port});
    try io_uring.runEchoServer(port);
}

fn runHttpServer(port: u16) !void {
    std.debug.print("Blitz HTTP/1.1 Server with JWT Authentication\n", .{});
    std.debug.print("==============================================\n\n", .{});

    const jwt = @import("jwt.zig");
    const net = std.net;

    // Create JWT validator configuration
    var jwt_config = jwt.ValidatorConfig.init(std.heap.page_allocator);
    defer jwt_config.deinit(std.heap.page_allocator);

    jwt_config.algorithm = .HS256;
    jwt_config.secret = try std.heap.page_allocator.dupe(u8, "your-256-bit-secret");
    jwt_config.issuer = try std.heap.page_allocator.dupe(u8, "blitz-gateway");
    jwt_config.audience = try std.heap.page_allocator.dupe(u8, "blitz-api");

    var jwt_validator = jwt.Validator.init(std.heap.page_allocator, jwt_config);
    defer jwt_validator.deinit();

    const address = try net.Address.parseIp("127.0.0.1", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("Server listening on http://127.0.0.1:{d}\n", .{port});
    std.debug.print("Test endpoints:\n", .{});
    std.debug.print("  GET  /health        - Health check (no auth)\n", .{});
    std.debug.print("  GET  /api/profile   - Protected (requires JWT)\n", .{});
    std.debug.print("  GET  /api/admin     - Admin only (requires admin JWT)\n\n", .{});

    while (true) {
        const conn = try server.accept();
        defer conn.stream.close();

        try handleHttpConnection(std.heap.page_allocator, conn.stream, &jwt_validator);
    }
}

fn handleHttpConnection(allocator: std.mem.Allocator, stream: std.net.Stream, jwt_validator: *@import("jwt.zig").Validator) !void {
    var buffer: [8192]u8 = undefined;
    const bytes_read = try stream.read(&buffer);
    if (bytes_read == 0) return;

    const request_data = buffer[0..bytes_read];
    const request_str = std.mem.sliceTo(request_data, 0);
    var request_lines = std.mem.splitSequence(u8, request_str, "\r\n");

    const request_line = request_lines.next() orelse return;
    var request_parts = std.mem.splitSequence(u8, request_line, " ");
    const method = request_parts.next() orelse return;
    const path = request_parts.next() orelse return;

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    while (request_lines.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
            const name = std.mem.trim(u8, line[0..colon_pos], &std.ascii.whitespace);
            const value = std.mem.trim(u8, line[colon_pos + 1 ..], &std.ascii.whitespace);
            try headers.put(name, value);
        }
    }

    try handleHttpRequest(allocator, method, path, &headers, jwt_validator, stream);
}

fn handleHttpRequest(allocator: std.mem.Allocator, _: []const u8, path: []const u8, headers: *std.StringHashMap([]const u8), jwt_validator: *@import("jwt.zig").Validator, stream: std.net.Stream) !void {
    var status_code: u16 = 200;
    var response_body: []const u8 = "";
    var allocated_response: ?[]u8 = null;
    defer if (allocated_response) |resp| allocator.free(resp);

    const requires_auth = !std.mem.eql(u8, path, "/health");
    var authenticated = false;
    var user_claims: ?@import("jwt.zig").Token = null;

    if (requires_auth) {
        const auth_header = headers.get("authorization") orelse headers.get("Authorization");
        if (auth_header) |auth| {
            if (std.mem.startsWith(u8, auth, "Bearer ")) {
                const token_str = std.mem.trim(u8, auth["Bearer ".len..], &std.ascii.whitespace);
                user_claims = jwt_validator.validateToken(token_str) catch null;
                authenticated = user_claims != null;
            }
        }

        if (!authenticated) {
            status_code = 401;
            response_body = "{\"error\":\"Unauthorized\",\"message\":\"Valid JWT token required\"}";
        }
    }

    if (status_code == 200) {
        if (std.mem.eql(u8, path, "/health")) {
            response_body = "{\"status\":\"healthy\",\"server\":\"blitz\"}";
        } else if (std.mem.eql(u8, path, "/api/profile")) {
            if (user_claims) |claims| {
                const user_id = claims.payload.sub orelse "unknown";
                const is_admin = if (claims.payload.custom_claims.get("admin")) |admin_claim| {
                    admin_claim == .bool and admin_claim.bool == true;
                } else false;

                allocated_response = try std.fmt.allocPrint(allocator, "{{\"user_id\":\"{s}\",\"profile\":{{\"name\":\"John Doe\",\"email\":\"john@example.com\"}},\"authenticated\":true,\"is_admin\":{}}}", .{ user_id, is_admin });
                response_body = allocated_response.?;
            } else {
                response_body = "{\"error\":\"Authentication required\"}";
            }
        } else if (std.mem.eql(u8, path, "/api/admin")) {
            var is_admin = false;
            if (user_claims) |claims| {
                if (claims.payload.custom_claims.get("admin")) |admin_claim| {
                    is_admin = admin_claim == .Bool and admin_claim.Bool == true;
                }
            }

            if (!is_admin) {
                status_code = 403;
                response_body = "{\"error\":\"Forbidden\",\"message\":\"Admin role required\"}";
            } else {
                response_body = "{\"message\":\"Admin access granted\"}";
            }
        } else {
            status_code = 404;
            response_body = "{\"error\":\"Not found\"}";
        }
    }

    try sendHttpResponse(stream, status_code, "application/json", response_body);
}

fn sendHttpResponse(stream: std.net.Stream, status_code: u16, content_type: []const u8, body: []const u8) !void {
    const status_text = switch (status_code) {
        200 => "OK",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        500 => "Internal Server Error",
        else => "Unknown",
    };

    var response_buf: [2048]u8 = undefined;
    var response_len: usize = 0;

    const status_line = try std.fmt.bufPrint(response_buf[response_len..], "HTTP/1.1 {d} {s}\r\n", .{ status_code, status_text });
    response_len += status_line.len;

    const content_type_header = try std.fmt.bufPrint(response_buf[response_len..], "Content-Type: {s}\r\n", .{content_type});
    response_len += content_type_header.len;

    const content_length_header = try std.fmt.bufPrint(response_buf[response_len..], "Content-Length: {}\r\n\r\n", .{body.len});
    response_len += content_length_header.len;

    @memcpy(response_buf[response_len .. response_len + body.len], body);
    response_len += body.len;

    _ = try stream.write(response_buf[0..response_len]);
}

fn runLoadBalancerMode(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    if (builtin.os.tag != .linux) {
        std.log.err("Load balancer requires Linux (io_uring support)", .{});
        return error.UnsupportedPlatform;
    }

    std.debug.print("Blitz Load Balancer v0.6.0\n", .{});
    std.debug.print("=========================\n\n", .{});

    // Initialize load balancer from config
    var lb = try load_balancer.LoadBalancer.initFromConfig(allocator, cfg.*);
    defer lb.deinit();

    // Use listen address and port from config
    const listen_addr = cfg.listen_addr;
    const listen_port = cfg.listen_port;

    std.debug.print("Load balancer configuration:\n", .{});
    std.debug.print("  Listen: {s}:{d}\n", .{ listen_addr, listen_port });
    std.debug.print("  Backends: {d}\n\n", .{cfg.backends.items.len});

    // Start load balancer server
    try lb.serve(listen_addr, listen_port);
}
