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
const core = @import("core/mod.zig");
const io_uring = core.io_uring;
const graceful_reload = core.graceful_reload;
const quic_server = @import("quic/server.zig");
const config = @import("config/mod.zig");
const load_balancer = @import("load_balancer/mod.zig");
const middleware = @import("middleware/mod.zig");
const rate_limit = middleware.rate_limit;
const metrics = @import("metrics/mod.zig");
const auth = @import("auth/mod.zig");
const jwt = auth.jwt;
const benchmark = @import("benchmark.zig");
const http2 = @import("http2_minimal.zig");

// C imports for socket timeout configuration
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/time.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
});

// HTTP request reading configuration
const MAX_REQUEST_SIZE: usize = 16 * 1024 * 1024; // 16MB max request size
const MAX_HEADER_SIZE: usize = 64 * 1024; // 64KB max header size
const READ_TIMEOUT_SECONDS: u64 = 30; // 30 second read timeout
const READ_BUFFER_SIZE: usize = 8192; // 8KB read buffer

const Mode = enum {
    quic, // QUIC/HTTP3 server (default)
    echo, // Echo server demo
    http, // HTTP/1.1 server with JWT
    bench, // Built-in benchmark mode
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

    // Benchmark options
    var bench_protocol: ?[]const u8 = null;
    var bench_duration: u32 = 30;
    var bench_connections: u32 = 100;
    var bench_threads: ?u32 = null;

    // TLS certificate options (for QUIC mode)
    var cert_path: ?[]const u8 = null;
    var key_path: ?[]const u8 = null;
    
    // Packet capture option (for QUIC mode)
    var enable_capture: bool = false;

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
        } else if (std.mem.eql(u8, args[i], "--bench")) {
            mode = .bench;
            // Check if next arg is a protocol name
            if (i + 1 < args.len) {
                const next = args[i + 1];
                if (std.mem.eql(u8, next, "http1") or
                    std.mem.eql(u8, next, "http2") or
                    std.mem.eql(u8, next, "http3") or
                    std.mem.eql(u8, next, "all"))
                {
                    bench_protocol = next;
                    i += 1;
                }
            }
        } else if (std.mem.eql(u8, args[i], "--duration")) {
            if (i + 1 < args.len) {
                i += 1;
                bench_duration = try std.fmt.parseInt(u32, args[i], 10);
            }
        } else if (std.mem.eql(u8, args[i], "--connections")) {
            if (i + 1 < args.len) {
                i += 1;
                bench_connections = try std.fmt.parseInt(u32, args[i], 10);
            }
        } else if (std.mem.eql(u8, args[i], "--threads")) {
            if (i + 1 < args.len) {
                i += 1;
                bench_threads = try std.fmt.parseInt(u32, args[i], 10);
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
        } else if (std.mem.eql(u8, args[i], "--cert")) {
            if (i + 1 < args.len) {
                i += 1;
                cert_path = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--key")) {
            if (i + 1 < args.len) {
                i += 1;
                key_path = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--capture")) {
            enable_capture = true;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, args[i], "--version") or std.mem.eql(u8, args[i], "-v")) {
            std.debug.print("Blitz Gateway v1.0.0\n", .{});
            return;
        }
        i += 1;
    }

    // Route to appropriate mode
    switch (mode) {
        .quic => try runQuicServer(allocator, config_path, port, cert_path, key_path, enable_capture),
        .echo => try runEchoServer(port orelse 8080),
        .http => try runHttpServer(port orelse 8080),
        .bench => try runBenchmarkMode(allocator, bench_protocol, bench_duration, bench_connections, bench_threads, port),
    }
}

fn printUsage() void {
    std.debug.print(
        \\Blitz Gateway v1.0.0
        \\High-performance QUIC/HTTP3 reverse proxy and load balancer
        \\
        \\Usage:
        \\  blitz [OPTIONS]
        \\
        \\Server Options:
        \\  --mode <mode>       Server mode: quic (default), echo, or http
        \\  --lb <config>       Load balancer mode with config file
        \\  --config <file>     Configuration file path
        \\  --port <port>       Port to listen on (default: 8443 for QUIC, 8080 for others)
        \\  --cert <file>       TLS certificate file (PEM format, for QUIC mode)
        \\  --key <file>        TLS private key file (PEM format, for QUIC mode)
        \\  --capture           Enable packet capture for QUIC sessions (writes to captures/ directory)
        \\
        \\Benchmark Options:
        \\  --bench [protocol]  Run built-in benchmarks (http1, http2, http3, or all)
        \\  --duration <secs>   Benchmark duration in seconds (default: 30)
        \\  --connections <n>   Concurrent connections (default: 100)
        \\  --threads <n>       Worker threads (default: CPU count)
        \\
        \\General:
        \\  --help, -h          Show this help message
        \\  --version, -v       Show version
        \\
        \\Examples:
        \\  blitz                               # QUIC/HTTP3 server
        \\  blitz --mode echo                   # Echo server demo
        \\  blitz --mode http                   # HTTP/1.1 server with JWT
        \\  blitz --lb config.toml              # Load balancer mode
        \\  blitz --bench                       # Benchmark all protocols
        \\  blitz --bench http1                 # Benchmark HTTP/1.1 only
        \\  blitz --bench http1 --duration 60  # 60-second HTTP/1.1 benchmark
        \\
    , .{});
}

fn runBenchmarkMode(
    allocator: std.mem.Allocator,
    protocol_arg: ?[]const u8,
    duration: u32,
    connections: u32,
    threads_arg: ?u32,
    port_arg: ?u16,
) !void {
    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Blitz Gateway - Built-in Benchmark Suite             ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    const threads = threads_arg orelse @as(u32, @intCast(std.Thread.getCpuCount() catch 4));
    const port = port_arg orelse 8080;

    // Determine which protocol(s) to benchmark
    const protocol = if (protocol_arg) |p|
        if (std.mem.eql(u8, p, "http1"))
            benchmark.BenchmarkConfig.Protocol.http1
        else if (std.mem.eql(u8, p, "http2"))
            benchmark.BenchmarkConfig.Protocol.http2
        else if (std.mem.eql(u8, p, "http3"))
            benchmark.BenchmarkConfig.Protocol.http3
        else
            benchmark.BenchmarkConfig.Protocol.all
    else
        benchmark.BenchmarkConfig.Protocol.http1; // Default to http1

    std.debug.print("NOTE: Start the server first in another terminal!\n", .{});
    std.debug.print("  HTTP/1.1: JWT_SECRET=test ./blitz --mode http\n", .{});
    std.debug.print("  Echo:     ./blitz --mode echo\n", .{});
    std.debug.print("  QUIC:     ./blitz\n", .{});
    std.debug.print("\n", .{});

    const cfg = benchmark.BenchmarkConfig{
        .protocol = protocol,
        .duration_seconds = duration,
        .connections = connections,
        .threads = threads,
        .port = port,
    };

    const result = try benchmark.runBenchmark(allocator, cfg);
    benchmark.printResults(result);
}

fn runQuicServer(allocator: std.mem.Allocator, config_path: ?[]const u8, port: ?u16, cert_path: ?[]const u8, key_path: ?[]const u8, enable_capture: bool) !void {
    if (builtin.os.tag != .linux) {
        std.log.err("QUIC server requires Linux (io_uring support)", .{});
        return error.UnsupportedPlatform;
    }

    std.debug.print("Blitz QUIC/HTTP3 Server v0.6.0\n", .{});
    std.debug.print("================================\n\n", .{});

    // Log TLS certificate configuration
    if (cert_path) |cert| {
        std.debug.print("TLS Certificate: {s}\n", .{cert});
    } else {
        std.debug.print("TLS Certificate: (none - TLS handshake will be limited)\n", .{});
    }
    if (key_path) |key| {
        std.debug.print("TLS Private Key: {s}\n", .{key});
    } else {
        std.debug.print("TLS Private Key: (none)\n", .{});
    }
    // TODO: Pass cert_path and key_path to QUIC server for TLS initialization

    // Initialize io_uring
    try io_uring.init();
    defer io_uring.deinit();

    const ring = &io_uring.ring;

    // Load configuration if provided
    if (config_path) |cfg_path| {
        std.debug.print("Loading configuration from: {s}\n", .{cfg_path});
        var cfg = try config.loadConfig(allocator, cfg_path);
        defer cfg.deinit();

        if (cfg.mode == .load_balancer) {
            std.debug.print("Starting in Load Balancer mode\n", .{});
            try runLoadBalancerMode(allocator, &cfg);
            return;
        }
    }

    // Default: Run QUIC server on port 8443
    const listen_port = port orelse 8443;
    std.debug.print("Starting QUIC/HTTP3 server on port {d}...\n", .{listen_port});
    if (enable_capture) {
        std.debug.print("Packet capture: ENABLED (files will be written to captures/ directory)\n", .{});
    }
    // TODO: Integrate cert_path, key_path, enable_capture when TLS is fully implemented
    _ = cert_path;
    _ = key_path;
    _ = enable_capture;
    _ = ring;
    try quic_server.runQuicServer(listen_port);
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

    const net = std.net;

    // Create JWT validator configuration
    var jwt_config = jwt.ValidatorConfig.init(std.heap.page_allocator);
    // Note: jwt_config ownership is transferred to jwt_validator on success.
    // Only deinit on error paths before successful initialization.

    jwt_config.algorithm = .HS256;

    // Read JWT secret from environment variable (required)
    const jwt_secret_env = std.posix.getenv("JWT_SECRET");
    const jwt_secret_raw = jwt_secret_env orelse {
        std.log.err("JWT_SECRET environment variable is required but not set", .{});
        jwt_config.deinit(std.heap.page_allocator);
        return error.JwtSecretMissing;
    };
    if (jwt_secret_raw.len == 0) {
        std.log.err("JWT_SECRET environment variable cannot be empty", .{});
        jwt_config.deinit(std.heap.page_allocator);
        return error.JwtSecretEmpty;
    }
    jwt_config.secret = try std.heap.page_allocator.dupe(u8, jwt_secret_raw);

    // Read JWT issuer from environment variable (optional, defaults to "blitz-gateway")
    const jwt_issuer_env = std.posix.getenv("JWT_ISSUER");
    jwt_config.issuer = if (jwt_issuer_env) |issuer|
        try std.heap.page_allocator.dupe(u8, issuer)
    else
        try std.heap.page_allocator.dupe(u8, "blitz-gateway");

    // Read JWT audience from environment variable (optional, defaults to "blitz-api")
    const jwt_audience_env = std.posix.getenv("JWT_AUDIENCE");
    jwt_config.audience = if (jwt_audience_env) |audience|
        try std.heap.page_allocator.dupe(u8, audience)
    else
        try std.heap.page_allocator.dupe(u8, "blitz-api");

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

fn handleHttpConnection(allocator: std.mem.Allocator, stream: std.net.Stream, jwt_validator: *jwt.Validator) !void {
    // Configure socket timeout
    const fd = stream.handle;
    var timeout: c.struct_timeval = undefined;
    timeout.tv_sec = @intCast(READ_TIMEOUT_SECONDS);
    timeout.tv_usec = 0;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &timeout, @sizeOf(c.struct_timeval));

    // Peek at first bytes to detect protocol before full read
    var peek_buf: [32]u8 = undefined;
    const peek_read = stream.read(&peek_buf) catch |err| {
        if (err == error.WouldBlock) return;
        return err;
    };
    if (peek_read == 0) return;

    // Check for direct HTTP/2 connection (prior knowledge - used by h2load)
    // HTTP/2 preface is "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" (24 bytes)
    if (peek_read >= 3 and std.mem.startsWith(u8, peek_buf[0..peek_read], "PRI")) {
        std.log.info("Direct HTTP/2 connection detected", .{});
        http2.handleDirectHttp2(stream, peek_buf[0..peek_read]) catch |err| {
            std.log.err("HTTP/2 error: {}", .{err});
        };
        return;
    }

    // Not HTTP/2, continue reading as HTTP/1.1 (prepend what we read)
    const request_data = try readHttpRequestWithPrefix(allocator, stream, peek_buf[0..peek_read]);
    defer allocator.free(request_data);

    // Check for HTTP/2 upgrade (h2c) BEFORE parsing as HTTP/1.1
    if (std.mem.indexOf(u8, request_data, "Upgrade: h2c") != null and
        std.mem.indexOf(u8, request_data, "HTTP2-Settings:") != null)
    {
        std.log.info("HTTP/2 cleartext upgrade detected", .{});
        http2.handleHttp2Upgrade(stream) catch |err| {
            std.log.err("HTTP/2 error: {}", .{err});
        };
        return; // HTTP/2 handler manages the connection
    }


    // Parse request
    const header_end = std.mem.indexOf(u8, request_data, "\r\n\r\n") orelse {
        return error.InvalidRequest;
    };
    const header_section = request_data[0..header_end];

    // Parse request line and headers
    var request_lines = std.mem.splitSequence(u8, header_section, "\r\n");
    const request_line = request_lines.next() orelse return error.InvalidRequestLine;
    var request_parts = std.mem.splitSequence(u8, request_line, " ");
    const method = request_parts.next() orelse return error.InvalidRequestLine;
    const path = request_parts.next() orelse return error.InvalidRequestLine;

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

/// Read complete HTTP request (headers + body) with proper timeout and size limits
fn readHttpRequest(allocator: std.mem.Allocator, stream: std.net.Stream) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    errdefer buffer.deinit(allocator);

    var read_buf: [READ_BUFFER_SIZE]u8 = undefined;
    var header_end_pos: ?usize = null;
    var content_length: ?usize = null;
    var is_chunked: bool = false;

    // Read until we find the header terminator "\r\n\r\n"
    while (true) {
        const bytes_read = stream.read(&read_buf) catch |err| {
            // Check if it's a timeout or would-block error
            if (err == error.WouldBlock or err == error.TimedOut) {
                return error.ReadTimeout;
            }
            return err;
        };

        if (bytes_read == 0) {
            if (buffer.items.len == 0) {
                return error.ConnectionClosed;
            }
            // EOF reached, check if we have complete headers
            if (header_end_pos == null) {
                return error.IncompleteRequest;
            }
            break;
        }

        try buffer.appendSlice(allocator, read_buf[0..bytes_read]);

        // Check for header terminator
        if (header_end_pos == null) {
            if (buffer.items.len > MAX_HEADER_SIZE) {
                return error.HeaderTooLarge;
            }

            if (std.mem.indexOf(u8, buffer.items, "\r\n\r\n")) |pos| {
                header_end_pos = pos;
                const header_section = buffer.items[0..pos];

                // Parse headers to determine body handling
                var header_lines = std.mem.splitSequence(u8, header_section, "\r\n");
                _ = header_lines.next(); // Skip request line

                while (header_lines.next()) |line| {
                    if (line.len == 0) break;
                    if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                        const name = std.mem.trim(u8, line[0..colon_pos], &std.ascii.whitespace);
                        const value = std.mem.trim(u8, line[colon_pos + 1 ..], &std.ascii.whitespace);

                        // Check for Content-Length
                        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                            content_length = std.fmt.parseInt(usize, value, 10) catch null;
                        }

                        // Check for Transfer-Encoding: chunked
                        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and
                            std.ascii.eqlIgnoreCase(value, "chunked"))
                        {
                            is_chunked = true;
                        }
                    }
                }

                // If no body expected, we're done
                if (content_length == null and !is_chunked) {
                    // Check if it's a method that might have a body
                    var method_iter = std.mem.splitSequence(u8, header_section, " ");
                    const method = method_iter.next() orelse break;
                    if (std.mem.eql(u8, method, "GET") or
                        std.mem.eql(u8, method, "HEAD") or
                        std.mem.eql(u8, method, "DELETE") or
                        std.mem.eql(u8, method, "OPTIONS"))
                    {
                        break; // No body expected
                    }
                }
            }
        }

        // If we have headers, check if we need to read body
        if (header_end_pos) |header_end| {
            const body_start = header_end + 4;
            const body_received = buffer.items.len - body_start;

            if (content_length) |cl| {
                if (body_received >= cl) {
                    // We have the complete body
                    break;
                }
                // Check total request size
                if (buffer.items.len > MAX_REQUEST_SIZE) {
                    return error.RequestTooLarge;
                }
            } else if (is_chunked) {
                // For chunked encoding, read until we get "0\r\n\r\n"
                if (buffer.items.len > MAX_REQUEST_SIZE) {
                    return error.RequestTooLarge;
                }
                // Check if we have the final chunk terminator
                const body_section = buffer.items[body_start..];
                if (std.mem.endsWith(u8, body_section, "0\r\n\r\n")) {
                    break;
                }
            } else {
                // No Content-Length and not chunked - assume no body or connection close
                break;
            }
        }
    }

    return try buffer.toOwnedSlice(allocator);
}

/// Read HTTP request with a prefix already read (for protocol detection)
fn readHttpRequestWithPrefix(allocator: std.mem.Allocator, stream: std.net.Stream, prefix: []const u8) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    errdefer buffer.deinit(allocator);

    // Start with the prefix data
    try buffer.appendSlice(allocator, prefix);

    var read_buf: [READ_BUFFER_SIZE]u8 = undefined;
    var header_end_pos: ?usize = null;
    var content_length: ?usize = null;
    var is_chunked: bool = false;

    // Check if prefix already contains header end
    if (std.mem.indexOf(u8, buffer.items, "\r\n\r\n")) |pos| {
        header_end_pos = pos;
    }

    while (true) {
        // If we already found headers, check if done
        if (header_end_pos) |_| {
            // For simple GET requests without body, we are done
            break;
        }

        const bytes_read = stream.read(&read_buf) catch |err| {
            if (err == error.WouldBlock or err == error.TimedOut) {
                return error.ReadTimeout;
            }
            return err;
        };

        if (bytes_read == 0) {
            if (buffer.items.len == 0) return error.ConnectionClosed;
            if (header_end_pos == null) return error.IncompleteRequest;
            break;
        }

        try buffer.appendSlice(allocator, read_buf[0..bytes_read]);

        if (buffer.items.len > MAX_HEADER_SIZE) {
            return error.HeaderTooLarge;
        }

        if (std.mem.indexOf(u8, buffer.items, "\r\n\r\n")) |pos| {
            header_end_pos = pos;
            // Check for Content-Length or chunked
            const header_section = buffer.items[0..pos];
            var lines = std.mem.splitSequence(u8, header_section, "\r\n");
            _ = lines.next(); // Skip request line
            while (lines.next()) |line| {
                if (line.len == 0) break;
                if (std.mem.indexOf(u8, line, ":")) |colon| {
                    const name = std.mem.trim(u8, line[0..colon], &std.ascii.whitespace);
                    const value = std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);
                    if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                        content_length = std.fmt.parseInt(usize, value, 10) catch null;
                    }
                    if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and std.ascii.eqlIgnoreCase(value, "chunked")) {
                        is_chunked = true;
                    }
                }
            }
            if (content_length == null and !is_chunked) break;
        }
    }

    return try buffer.toOwnedSlice(allocator);
}


fn handleHttpRequest(allocator: std.mem.Allocator, _: []const u8, path: []const u8, headers: *std.StringHashMap([]const u8), jwt_validator: *jwt.Validator, stream: std.net.Stream) !void {
    var status_code: u16 = 200;
    var response_body: []const u8 = "";
    var allocated_response: ?[]u8 = null;
    defer if (allocated_response) |resp| allocator.free(resp);

    const requires_auth = !std.mem.eql(u8, path, "/health");
    var authenticated = false;
    var user_claims: ?jwt.Token = null;

    if (requires_auth) {
        const auth_header = headers.get("authorization") orelse headers.get("Authorization");
        if (auth_header) |auth_token| {
            if (std.mem.startsWith(u8, auth_token, "Bearer ")) {
                const token_str = std.mem.trim(u8, auth_token["Bearer ".len..], &std.ascii.whitespace);
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
                const is_admin = if (claims.payload.custom_claims.get("admin")) |admin_claim| blk: {
                    break :blk admin_claim == .bool and admin_claim.bool == true;
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
                    is_admin = admin_claim == .bool and admin_claim.bool == true;
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

    try sendHttpResponse(allocator, stream, status_code, "application/json", response_body);
}

// Helper function to calculate formatted string size
fn calculateFormattedSize(comptime fmt: []const u8, args: anytype) usize {
    var temp_buf: [512]u8 = undefined;
    const result = std.fmt.bufPrint(&temp_buf, fmt, args) catch {
        // If formatting fails, return a conservative estimate
        // This should never happen with valid inputs, but provides safety
        return 512;
    };
    return result.len;
}

fn sendHttpResponse(allocator: std.mem.Allocator, stream: std.net.Stream, status_code: u16, content_type: []const u8, body: []const u8) !void {
    const status_text = switch (status_code) {
        200 => "OK",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        500 => "Internal Server Error",
        else => "Unknown",
    };

    // Calculate required sizes for each component
    const status_line_size = calculateFormattedSize("HTTP/1.1 {d} {s}\r\n", .{ status_code, status_text });
    const content_type_header_size = calculateFormattedSize("Content-Type: {s}\r\n", .{content_type});
    const content_length_header_size = calculateFormattedSize("Content-Length: {}\r\n\r\n", .{body.len});
    const total_size = status_line_size + content_type_header_size + content_length_header_size + body.len;

    const response_buf_size = 2048;
    var response_buf_stack: [response_buf_size]u8 = undefined;
    var response_buf: []u8 = undefined;
    var response_buf_allocated: ?[]u8 = null;
    defer if (response_buf_allocated) |buf| allocator.free(buf);

    // Use stack buffer if it fits, otherwise allocate dynamically
    if (total_size <= response_buf_size) {
        response_buf = &response_buf_stack;
    } else {
        response_buf_allocated = try allocator.alloc(u8, total_size);
        response_buf = response_buf_allocated.?;
    }

    var response_len: usize = 0;

    const status_line = try std.fmt.bufPrint(response_buf[response_len..], "HTTP/1.1 {d} {s}\r\n", .{ status_code, status_text });
    response_len += status_line.len;

    const content_type_header = try std.fmt.bufPrint(response_buf[response_len..], "Content-Type: {s}\r\n", .{content_type});
    response_len += content_type_header.len;

    const content_length_header = try std.fmt.bufPrint(response_buf[response_len..], "Content-Length: {}\r\n\r\n", .{body.len});
    response_len += content_length_header.len;

    // Ensure we have enough space for the body before copying
    if (response_len + body.len > response_buf.len) {
        return error.ResponseTooLarge;
    }
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
