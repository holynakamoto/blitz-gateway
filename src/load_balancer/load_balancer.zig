// Main load balancer module
// Integrates backend pool, health checks, connection pooling, retry logic, and timeouts

const std = @import("std");
const backend = @import("backend.zig");
const health_check = @import("health_check.zig");
const connection_pool = @import("connection_pool.zig");
const config = @import("../config.zig");

pub const LoadBalancerError = error{
    NoBackendsAvailable,
    AllRetriesExhausted,
    ConnectionPoolExhausted,
    SendFailed,
    InvalidResponse,
};

pub const LoadBalancer = struct {
    pool: backend.BackendPool,
    health_checker: health_check.HealthChecker,
    conn_pool: connection_pool.ConnectionPool,
    allocator: std.mem.Allocator,

    // Configuration
    max_retries: u32 = 3,
    retry_delay_ms: u64 = 100, // Initial retry delay
    request_timeout_ms: u64 = 5000, // 5 seconds

    pub fn init(allocator: std.mem.Allocator) LoadBalancer {
        var pool = backend.BackendPool.init(allocator);
        const checker = health_check.HealthChecker.init(allocator, &pool);
        const conn_pool = connection_pool.ConnectionPool.init(allocator);

        return LoadBalancer{
            .pool = pool,
            .health_checker = checker,
            .conn_pool = conn_pool,
            .allocator = allocator,
            .max_retries = 3,
            .retry_delay_ms = 100,
            .request_timeout_ms = 5000,
        };
    }

    /// Initialize load balancer from configuration
    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config.Config) !LoadBalancer {
        var lb = LoadBalancer.init(allocator);

        // Add all backends from config
        for (cfg.backends.items) |backend_config| {
            const b = try lb.addBackend(backend_config.host, backend_config.port);
            b.weight = backend_config.weight;

            // Set health check path if specified
            if (backend_config.health_check_path) |path| {
                // Note: This would need to be implemented in the Backend struct
                // For now, we'll use the default health check
                std.log.info("Health check path configured: {s} (not yet implemented)", .{path});
            }
        }

        std.log.info("Load balancer initialized with {} backends", .{cfg.backends.items.len});
        return lb;
    }

    pub fn deinit(self: *LoadBalancer) void {
        self.conn_pool.deinit();
        self.pool.deinit();
    }

    /// Add a backend to the load balancer
    pub fn addBackend(self: *LoadBalancer, host: []const u8, port: u16) !*backend.Backend {
        return try self.pool.addBackend(host, port);
    }

    /// Forward a request to a backend with retry logic
    pub fn forwardRequest(
        self: *LoadBalancer,
        method: []const u8,
        path: []const u8,
        headers: []const u8,
        body: []const u8,
    ) LoadBalancerError!ForwardResult {
        var attempt: u32 = 0;
        var last_error: ?anyerror = null;

        while (attempt < self.max_retries) {
            // Get next backend using round-robin
            const backend_server = self.pool.getNextBackend() orelse return LoadBalancerError.NoBackendsAvailable;

            // Try to forward request
            const result = self.forwardToBackend(backend_server, method, path, headers, body) catch |err| {
                last_error = err;
                backend_server.recordFailure();

                // Exponential backoff before retry
                if (attempt < self.max_retries - 1) {
                    const delay = self.retry_delay_ms * (@as(u64, 1) << @intCast(attempt));
                    std.time.sleep(delay * 1_000_000); // Convert to nanoseconds
                }

                attempt += 1;
                continue;
            };

            // Success!
            backend_server.recordSuccess();
            return result;
        }

        // All retries failed
        return LoadBalancerError.AllRetriesExhausted;
    }

    /// Forward request to a specific backend
    fn forwardToBackend(
        self: *LoadBalancer,
        backend_server: *backend.Backend,
        method: []const u8,
        path: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !ForwardResult {
        // Get or create connection from pool
        const conn = self.conn_pool.getConnection(backend_server) catch |err| {
            return err;
        };

        const conn_opt = conn orelse {
            return LoadBalancerError.ConnectionPoolExhausted;
        };
        defer self.conn_pool.returnConnection(conn_opt);

        // Build HTTP request
        const request = try self.buildRequest(method, path, headers, body);
        defer self.allocator.free(request);

        // Send request with timeout
        try self.sendWithTimeout(conn_opt.fd, request, self.request_timeout_ms);

        // Receive response with timeout
        const response = try self.receiveWithTimeout(conn_opt.fd, self.request_timeout_ms);
        errdefer self.allocator.free(response);

        return ForwardResult{
            .status_code = try self.parseStatusCode(response),
            .headers = "", // TODO: Parse headers
            .body = response,
            .backend = backend_server,
        };
    }

    /// Build HTTP request string
    pub fn buildRequest(
        self: *LoadBalancer,
        method: []const u8,
        path: []const u8,
        headers: []const u8,
        body: []const u8,
    ) ![]u8 {
        // Simple request building
        var request = std.ArrayListUnmanaged(u8){};
        errdefer request.deinit(self.allocator);

        // Request line
        try request.writer(self.allocator).print("{s} {s} HTTP/1.1\r\n", .{ method, path });

        // Headers
        if (headers.len > 0) {
            try request.writer(self.allocator).print("{s}", .{headers});
        } else {
            try request.writer(self.allocator).print("Host: localhost\r\n", .{});
        }

        // Body
        if (body.len > 0) {
            try request.writer(self.allocator).print("Content-Length: {}\r\n", .{body.len});
        }

        try request.writer(self.allocator).print("\r\n", .{});

        // Body content
        if (body.len > 0) {
            try request.appendSlice(self.allocator, body);
        }

        return try request.toOwnedSlice(self.allocator);
    }

    /// Send data with timeout
    fn sendWithTimeout(self: *LoadBalancer, fd: c_int, data: []const u8, timeout_ms: u64) !void {
        _ = self;
        _ = timeout_ms; // TODO: Implement timeout using select/poll

        const sys = @cImport({
            @cDefine("_GNU_SOURCE", "1");
            @cInclude("sys/socket.h");
            @cInclude("unistd.h");
        });

        var sent: usize = 0;
        while (sent < data.len) {
            const result = sys.send(fd, data.ptr + sent, data.len - sent, 0);
            if (result < 0) {
                return LoadBalancerError.SendFailed;
            }
            sent += @intCast(result);
        }
    }

    /// Receive data with timeout
    fn receiveWithTimeout(self: *LoadBalancer, fd: c_int, timeout_ms: u64) ![]u8 {
        _ = timeout_ms; // TODO: Implement timeout using select/poll

        const sys = @cImport({
            @cDefine("_GNU_SOURCE", "1");
            @cInclude("sys/socket.h");
            @cInclude("unistd.h");
        });

        var buffer = std.ArrayListUnmanaged(u8){};
        errdefer buffer.deinit(self.allocator);

        var read_buf: [4096]u8 = undefined;

        while (true) {
            const received = sys.recv(fd, &read_buf, read_buf.len, 0);
            if (received <= 0) {
                break;
            }
            try buffer.appendSlice(self.allocator, read_buf[0..@intCast(received)]);
        }

        return try buffer.toOwnedSlice(self.allocator);
    }

    /// Parse HTTP status code from response
    pub fn parseStatusCode(self: *LoadBalancer, response: []const u8) !u16 {
        _ = self;

        // Find "HTTP/1.1 200" pattern
        const http_pos = std.mem.indexOf(u8, response, "HTTP/") orelse return LoadBalancerError.InvalidResponse;
        const space_pos = std.mem.indexOfScalarPos(u8, response, http_pos + 8, ' ') orelse return LoadBalancerError.InvalidResponse;
        const status_start = space_pos + 1;
        const status_end = std.mem.indexOfScalarPos(u8, response, status_start, ' ') orelse return LoadBalancerError.InvalidResponse;

        const status_str = response[status_start..status_end];
        return try std.fmt.parseInt(u16, status_str, 10);
    }

    /// Perform health check on all backends
    pub fn performHealthCheck(self: *LoadBalancer) void {
        self.health_checker.checkAllBackends();
    }

    /// Clean up stale connections
    pub fn cleanupConnections(self: *LoadBalancer) void {
        self.conn_pool.cleanupStaleConnections();
    }

    /// Get load balancer statistics
    pub fn getStats(self: *const LoadBalancer) struct {
        total_backends: usize,
        healthy_backends: usize,
        total_requests: u64,
        successful_requests: u64,
        failed_requests: u64,
    } {
        const pool_stats = self.pool.getStats();
        return .{
            .total_backends = pool_stats.total_backends,
            .healthy_backends = pool_stats.healthy_backends,
            .total_requests = pool_stats.total_requests,
            .successful_requests = pool_stats.successful_requests,
            .failed_requests = pool_stats.failed_requests,
        };
    }

    /// Start the load balancer server (integrates with QUIC server)
    /// This is a placeholder - actual implementation would integrate with
    /// the QUIC handshake server to forward requests to backends
    pub fn serve(self: *LoadBalancer, host: []const u8, port: u16) !void {
        std.log.info("Load balancer server starting on {s}:{d}", .{ host, port });
        std.log.info("Backends configured: {}", .{self.pool.backends.items.len});

        // Start health checking in background
        self.startHealthChecking();

        // TODO: Integrate with QUIC server to accept connections
        // For now, this is a placeholder that shows the load balancer is ready
        std.log.info("Load balancer is ready to accept QUIC connections", .{});

        // In a real implementation, this would:
        // 1. Listen on UDP port for QUIC connections
        // 2. Perform TLS handshake
        // 3. Parse HTTP/3 requests
        // 4. Forward to healthy backends using round-robin/load balancing
        // 5. Return responses to clients

        // For now, we'll just keep it running
        while (true) {
            std.time.sleep(1_000_000_000); // Sleep for 1 second
            self.performHealthCheck();
        }
    }

    /// Start background health checking
    fn startHealthChecking(self: *LoadBalancer) void {
        std.log.info("Starting health checks for {} backends", .{self.pool.backends.items.len});

        // Perform initial health check
        self.performHealthCheck();

        // TODO: In a real implementation, this would run in a separate thread
        // or use async/await to perform periodic health checks
    }
};

pub const ForwardResult = struct {
    status_code: u16,
    headers: []const u8,
    body: []const u8, // OWNED - must be freed
    backend: *backend.Backend,

    pub fn deinit(self: *ForwardResult, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

// Reviewed: 2025-12-01
