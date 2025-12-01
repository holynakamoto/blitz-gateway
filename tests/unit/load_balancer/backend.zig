// Backend server management for load balancing
// Handles backend pool, health checks, and connection pooling

const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
});

pub const Backend = struct {
    host: [:0]const u8,
    port: u16,
    weight: u32 = 1, // For weighted round-robin (future)

    // Health check state
    is_healthy: bool = true,
    last_health_check: i64 = 0,
    consecutive_failures: u32 = 0,

    // Connection pool (future - will store active connections)
    // active_connections: std.ArrayList(c_int),

    // Statistics
    total_requests: u64 = 0,
    successful_requests: u64 = 0,
    failed_requests: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !Backend {
        const host_copy = try allocator.dupeZ(u8, host);
        errdefer allocator.free(host_copy);

        return Backend{
            .host = host_copy,
            .port = port,
            .weight = 1,
            .is_healthy = true,
            .last_health_check = 0,
            .consecutive_failures = 0,
            .total_requests = 0,
            .successful_requests = 0,
            .failed_requests = 0,
        };
    }

    pub fn deinit(self: *Backend, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
    }

    /// Get socket address for this backend
    pub fn getAddress(self: *const Backend) !c.struct_sockaddr_in {
        var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
        addr.sin_family = c.AF_INET;
        addr.sin_port = c.htons(self.port);

        // Ensure host is null-terminated before passing to inet_pton
        // Use a fixed-size buffer to safely copy and null-terminate the host string
        const MAX_HOST_LEN = 255; // Safe max for IP addresses and hostnames
        if (self.host.len > MAX_HOST_LEN) {
            return error.InvalidAddress;
        }

        var host_buf: [MAX_HOST_LEN + 1]u8 = undefined;
        @memcpy(host_buf[0..self.host.len], self.host);
        host_buf[self.host.len] = 0; // Ensure null termination

        // Parse host (IP address or hostname)
        if (c.inet_pton(c.AF_INET, &host_buf, &addr.sin_addr) == 1) {
            // Successfully parsed as IP address
            return addr;
        }

        // TODO: DNS resolution for hostnames
        // For now, assume it's an IP address
        return error.InvalidAddress;
    }

    /// Mark backend as healthy
    pub fn markHealthy(self: *Backend) void {
        self.is_healthy = true;
        self.consecutive_failures = 0;
    }

    /// Mark backend as unhealthy
    pub fn markUnhealthy(self: *Backend) void {
        self.consecutive_failures += 1;
        if (self.consecutive_failures >= 3) {
            // Mark unhealthy after 3 consecutive failures
            self.is_healthy = false;
        }
    }

    /// Record a successful request
    pub fn recordSuccess(self: *Backend) void {
        self.total_requests += 1;
        self.successful_requests += 1;
        self.markHealthy();
    }

    /// Record a failed request
    pub fn recordFailure(self: *Backend) void {
        self.total_requests += 1;
        self.failed_requests += 1;
        self.markUnhealthy();
    }
};

pub const BackendPool = struct {
    backends: std.ArrayListUnmanaged(*Backend),
    current_index: usize = 0, // For round-robin
    allocator: std.mem.Allocator,

    // Health check configuration
    health_check_interval: u64 = 5000, // 5 seconds in milliseconds
    health_check_timeout: u64 = 2000, // 2 seconds in milliseconds
    health_check_path: []const u8 = "/health",

    pub fn init(allocator: std.mem.Allocator) BackendPool {
        return BackendPool{
            .backends = .{},
            .current_index = 0,
            .allocator = allocator,
            .health_check_interval = 5000,
            .health_check_timeout = 2000,
            .health_check_path = "/health",
        };
    }

    pub fn deinit(self: *BackendPool) void {
        for (self.backends.items) |backend| {
            backend.deinit(self.allocator);
            self.allocator.destroy(backend);
        }
        self.backends.deinit(self.allocator);
    }

    /// Add a backend to the pool
    pub fn addBackend(self: *BackendPool, host: []const u8, port: u16) !*Backend {
        const backend = try self.allocator.create(Backend);
        errdefer self.allocator.destroy(backend);

        backend.* = try Backend.init(self.allocator, host, port);
        try self.backends.append(self.allocator, backend);

        return backend;
    }

    /// Get next backend using round-robin algorithm
    pub fn getNextBackend(self: *BackendPool) ?*Backend {
        if (self.backends.items.len == 0) {
            return null;
        }

        var attempts: usize = 0;
        while (attempts < self.backends.items.len) {
            const backend = self.backends.items[self.current_index];
            self.current_index = (self.current_index + 1) % self.backends.items.len;

            // Only return healthy backends
            if (backend.is_healthy) {
                return backend;
            }

            attempts += 1;
        }

        // If no healthy backends, return the first one anyway (failover)
        if (self.backends.items.len > 0) {
            return self.backends.items[0];
        }

        return null;
    }

    /// Get all healthy backends
    pub fn getHealthyBackends(self: *BackendPool) []*Backend {
        // Return slice of healthy backends (for future use)
        // For now, we'll use getNextBackend which filters automatically
        return self.backends.items;
    }

    /// Get backend statistics
    pub fn getStats(self: *const BackendPool) struct {
        total_backends: usize,
        healthy_backends: usize,
        total_requests: u64,
        successful_requests: u64,
        failed_requests: u64,
    } {
        var healthy_count: usize = 0;
        var total_reqs: u64 = 0;
        var success_reqs: u64 = 0;
        var failed_reqs: u64 = 0;

        for (self.backends.items) |backend| {
            if (backend.is_healthy) {
                healthy_count += 1;
            }
            total_reqs += backend.total_requests;
            success_reqs += backend.successful_requests;
            failed_reqs += backend.failed_requests;
        }

        return .{
            .total_backends = self.backends.items.len,
            .healthy_backends = healthy_count,
            .total_requests = total_reqs,
            .successful_requests = success_reqs,
            .failed_requests = failed_reqs,
        };
    }
};
