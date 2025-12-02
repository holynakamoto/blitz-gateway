// Health check system for backend monitoring
// Performs periodic health checks on backend servers

const std = @import("std");
const backend = @import("backend.zig");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("sys/time.h");
});

pub const HealthChecker = struct {
    pool: *backend.BackendPool,
    allocator: std.mem.Allocator,
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator, pool: *backend.BackendPool) HealthChecker {
        return HealthChecker{
            .pool = pool,
            .allocator = allocator,
            .running = false,
        };
    }

    /// Perform a health check on a single backend
    pub fn checkBackend(self: *HealthChecker, backend_server: *backend.Backend) !bool {
        const now = std.time.milliTimestamp();
        backend_server.last_health_check = now;

        // Create socket
        const sockfd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (sockfd < 0) {
            return false;
        }
        defer _ = c.close(sockfd);

        // Set non-blocking
        const flags = c.fcntl(sockfd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(sockfd, c.F_SETFL, flags | c.O_NONBLOCK);

        // Set timeout
        var timeout: c.struct_timeval = undefined;
        timeout.tv_sec = @intCast(self.pool.health_check_timeout / 1000);
        timeout.tv_usec = @intCast((self.pool.health_check_timeout % 1000) * 1000);
        _ = c.setsockopt(sockfd, c.SOL_SOCKET, c.SO_RCVTIMEO, &timeout, @sizeOf(c.struct_timeval));
        _ = c.setsockopt(sockfd, c.SOL_SOCKET, c.SO_SNDTIMEO, &timeout, @sizeOf(c.struct_timeval));

        // Get backend address
        const addr = try backend_server.getAddress();
        const addr_ptr: *const c.struct_sockaddr = @ptrCast(&addr);

        // Connect (non-blocking)
        const connect_result = c.connect(sockfd, @ptrCast(addr_ptr), @sizeOf(c.struct_sockaddr_in));
        if (connect_result < 0) {
            const err = c.errno;
            if (err != c.EINPROGRESS) {
                return false;
            }
        }

        // Wait for connection with select
        var write_fds: c.fd_set = undefined;
        c.FD_ZERO(&write_fds);
        c.FD_SET(sockfd, &write_fds);

        var select_timeout: c.struct_timeval = timeout;
        const select_result = c.select(sockfd + 1, null, &write_fds, null, &select_timeout);
        if (select_result <= 0) {
            return false; // Timeout or error
        }

        // Check if connection succeeded
        var so_error: c_int = 0;
        var len: c.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(sockfd, c.SOL_SOCKET, c.SO_ERROR, &so_error, &len) < 0 or so_error != 0) {
            return false;
        }

        // Send HTTP health check request
        // Loop until all bytes are sent (handle partial writes on non-blocking sockets)
        const health_request = "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var bytes_sent: usize = 0;

        while (bytes_sent < health_request.len) {
            const result = c.send(sockfd, health_request.ptr + bytes_sent, health_request.len - bytes_sent, 0);

            if (result > 0) {
                // Partial or complete write - increment bytes_sent
                bytes_sent += @intCast(result);
            } else if (result == -1) {
                const err = c.errno;
                if (err == c.EINTR) {
                    // Interrupted by signal - retry
                    continue;
                } else if (err == c.EAGAIN or err == c.EWOULDBLOCK) {
                    // Socket would block - wait for it to become writable
                    var send_write_fds: c.fd_set = undefined;
                    c.FD_ZERO(&send_write_fds);
                    c.FD_SET(sockfd, &send_write_fds);

                    var send_timeout: c.struct_timeval = timeout;
                    const send_select_result = c.select(sockfd + 1, null, &send_write_fds, null, &send_timeout);
                    if (send_select_result <= 0) {
                        // Timeout or error waiting for socket to become writable
                        return false;
                    }
                    // Socket is now writable - retry send
                    continue;
                } else {
                    // Non-recoverable error
                    return false;
                }
            } else {
                // Unexpected return value (should not happen)
                return false;
            }
        }

        // Read response (simplified - just check for HTTP/1.1 200)
        var response_buf: [512]u8 = undefined;
        const received = c.recv(sockfd, &response_buf, response_buf.len, 0);
        if (received <= 0) {
            return false;
        }

        // Check if response contains "200 OK" or "200"
        const response = response_buf[0..@intCast(received)];
        if (std.mem.indexOf(u8, response, "200") != null) {
            return true;
        }

        return false;
    }

    /// Perform health check on all backends
    pub fn checkAllBackends(self: *HealthChecker) void {
        for (self.pool.backends.items) |backend_server| {
            const is_healthy = self.checkBackend(backend_server) catch false;
            if (is_healthy) {
                backend_server.markHealthy();
            } else {
                backend_server.markUnhealthy();
            }
        }
    }

    /// Start health check loop (runs in background)
    /// Note: This is a simplified version. In production, this would run in a separate thread
    pub fn start(self: *HealthChecker) void {
        self.running = true;
        // TODO: Run in separate thread or async task
        // For now, health checks will be performed on-demand or via periodic calls
    }

    /// Stop health check loop
    pub fn stop(self: *HealthChecker) void {
        self.running = false;
    }
};
