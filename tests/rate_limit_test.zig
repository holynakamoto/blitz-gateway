//! Unit tests for rate limiting functionality
//! Tests both global and per-IP rate limiting with token bucket algorithm

const std = @import("std");
const testing = std.testing;
const rate_limit = @import("rate_limit.zig");
const config_mod = @import("config_mod.zig");

test "Rate Limit: Initialize with default config" {
    const allocator = std.testing.allocator;

    const config = rate_limit.RateLimitConfig{};
    var limiter = try rate_limit.RateLimiter.init(allocator, config);
    defer limiter.deinit();

    // Should initialize successfully with default config
    try testing.expect(limiter.config.global_rps == null);
    try testing.expect(limiter.config.per_ip_rps == null);
    try testing.expect(limiter.config.enable_ebpf == true);
    try testing.expect(limiter.config.burst_multiplier == 2.0);
}

test "Rate Limit: Initialize with rate limits" {
    const allocator = std.testing.allocator;

    const config = rate_limit.RateLimitConfig{
        .global_rps = 1000,
        .per_ip_rps = 100,
        .burst_multiplier = 3.0,
        .enable_ebpf = false,
    };

    var limiter = try rate_limit.RateLimiter.init(allocator, config);
    defer limiter.deinit();

    try testing.expectEqual(@as(?u32, 1000), limiter.config.global_rps);
    try testing.expectEqual(@as(?u32, 100), limiter.config.per_ip_rps);
    try testing.expectEqual(@as(f32, 3.0), limiter.config.burst_multiplier);
    try testing.expectEqual(false, limiter.config.enable_ebpf);
}

test "Rate Limit: Global rate limiting allows requests under limit" {
    const allocator = std.testing.allocator;

    const config = rate_limit.RateLimitConfig{
        .global_rps = 10, // 10 requests per second
        .enable_ebpf = false, // Force userspace
    };

    var limiter = try rate_limit.RateLimiter.init(allocator, config);
    defer limiter.deinit();

    const client_ip: u32 = 0x7F000001; // 127.0.0.1

    // Should allow requests at normal rate
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const result = limiter.checkRequest(client_ip);
        try testing.expectEqual(rate_limit.RateLimitResult.allow, result);
    }

    // Check statistics
    const stats = limiter.getStats();
    try testing.expectEqual(@as(u64, 10), stats.total_requests);
    try testing.expectEqual(@as(u64, 10), stats.allowed_requests);
    try testing.expectEqual(@as(u64, 0), stats.denied_global);
    try testing.expectEqual(@as(u64, 0), stats.denied_per_ip);
}

test "Rate Limit: Global rate limiting denies requests over limit" {
    const allocator = std.testing.allocator;

    const config = rate_limit.RateLimitConfig{
        .global_rps = 5, // 5 requests per second
        .burst_multiplier = 1.0, // No burst allowance
        .enable_ebpf = false,
    };

    var limiter = try rate_limit.RateLimiter.init(allocator, config);
    defer limiter.deinit();

    const client_ip: u32 = 0x7F000001;

    // Should allow first 5 requests
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const result = limiter.checkRequest(client_ip);
        try testing.expectEqual(rate_limit.RateLimitResult.allow, result);
    }

    // Next request should be denied (no burst tokens left)
    const denied_result = limiter.checkRequest(client_ip);
    try testing.expectEqual(rate_limit.RateLimitResult.deny_global, denied_result);

    // Check statistics
    const stats = limiter.getStats();
    try testing.expectEqual(@as(u64, 6), stats.total_requests);
    try testing.expectEqual(@as(u64, 5), stats.allowed_requests);
    try testing.expectEqual(@as(u64, 1), stats.denied_global);
}

test "Rate Limit: Per-IP rate limiting" {
    const allocator = std.testing.allocator;

    const config = rate_limit.RateLimitConfig{
        .per_ip_rps = 3, // 3 requests per second per IP
        .burst_multiplier = 1.0,
        .enable_ebpf = false,
    };

    var limiter = try rate_limit.RateLimiter.init(allocator, config);
    defer limiter.deinit();

    const ip1: u32 = 0xC0A80001; // 192.168.0.1
    const ip2: u32 = 0xC0A80002; // 192.168.0.2

    // IP1 should be able to make 3 requests
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const result = limiter.checkRequest(ip1);
        try testing.expectEqual(rate_limit.RateLimitResult.allow, result);
    }

    // IP1 next request should be denied
    const ip1_denied = limiter.checkRequest(ip1);
    try testing.expectEqual(rate_limit.RateLimitResult.deny_per_ip, ip1_denied);

    // IP2 should still be allowed (separate limit)
    const ip2_allowed = limiter.checkRequest(ip2);
    try testing.expectEqual(rate_limit.RateLimitResult.allow, ip2_allowed);

    // Check IP tracking
    const stats = limiter.getStats();
    try testing.expectEqual(@as(usize, 2), stats.active_ips);
}

test "Rate Limit: Combined global and per-IP limits" {
    const allocator = std.testing.allocator;

    const config = rate_limit.RateLimitConfig{
        .global_rps = 5, // 5 total requests per second
        .per_ip_rps = 3, // 3 requests per second per IP
        .burst_multiplier = 1.0,
        .enable_ebpf = false,
    };

    var limiter = try rate_limit.RateLimiter.init(allocator, config);
    defer limiter.deinit();

    const ip1: u32 = 0x0A000001; // 10.0.0.1

    // Should allow 3 requests (per-IP limit)
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const result = limiter.checkRequest(ip1);
        try testing.expectEqual(rate_limit.RateLimitResult.allow, result);
    }

    // Next request should be denied by per-IP limit
    const denied_per_ip = limiter.checkRequest(ip1);
    try testing.expectEqual(rate_limit.RateLimitResult.deny_per_ip, denied_per_ip);

    // Check that global limit still has capacity
    const stats = limiter.getStats();
    try testing.expectEqual(@as(u64, 4), stats.total_requests);
    try testing.expectEqual(@as(u64, 0), stats.denied_global);
    try testing.expectEqual(@as(u64, 1), stats.denied_per_ip);
}

test "Rate Limit: Token bucket refills over time" {
    const allocator = std.testing.allocator;

    const config = rate_limit.RateLimitConfig{
        .global_rps = 2, // 2 requests per second = 0.5 tokens per 250ms
        .burst_multiplier = 1.0,
        .enable_ebpf = false,
    };

    var limiter = try rate_limit.RateLimiter.init(allocator, config);
    defer limiter.deinit();

    const client_ip: u32 = 0x7F000001;

    // Use up all tokens
    const result1 = limiter.checkRequest(client_ip);
    try testing.expectEqual(rate_limit.RateLimitResult.allow, result1);

    const result2 = limiter.checkRequest(client_ip);
    try testing.expectEqual(rate_limit.RateLimitResult.allow, result2);

    // Should be denied (no tokens left)
    const denied = limiter.checkRequest(client_ip);
    try testing.expectEqual(rate_limit.RateLimitResult.deny_global, denied);

    // Simulate time passing (500ms = 1 token should refill)
    limiter.global_last_update -= 500;

    // Should allow one more request
    const allowed_again = limiter.checkRequest(client_ip);
    try testing.expectEqual(rate_limit.RateLimitResult.allow, allowed_again);
}

test "Rate Limit: IP cleanup removes expired entries" {
    const allocator = std.testing.allocator;

    const config = rate_limit.RateLimitConfig{
        .per_ip_rps = 1,
        .cleanup_interval_seconds = 1, // 1 second expiry
        .enable_ebpf = false,
    };

    var limiter = try rate_limit.RateLimiter.init(allocator, config);
    defer limiter.deinit();

    const ip1: u32 = 0x0A000001;
    const ip2: u32 = 0x0A000002;

    // Make requests from both IPs
    _ = limiter.checkRequest(ip1);
    _ = limiter.checkRequest(ip2);

    try testing.expectEqual(@as(usize, 2), limiter.ip_buckets.count());

    // Expire the first IP's entry
    if (limiter.ip_buckets.getPtr(ip1)) |bucket| {
        bucket.last_update -= 2000; // 2 seconds ago
    }

    // Run cleanup
    limiter.cleanup();

    // Should only have one IP left
    try testing.expectEqual(@as(usize, 1), limiter.ip_buckets.count());
    try testing.expect(limiter.ip_buckets.contains(ip2));
    try testing.expect(!limiter.ip_buckets.contains(ip1));
}

test "Rate Limit: Burst allowance works correctly" {
    const allocator = std.testing.allocator;

    const config = rate_limit.RateLimitConfig{
        .global_rps = 10, // 10 requests per second
        .burst_multiplier = 2.0, // Allow 20 requests burst
        .enable_ebpf = false,
    };

    var limiter = try rate_limit.RateLimiter.init(allocator, config);
    defer limiter.deinit();

    const client_ip: u32 = 0x7F000001;

    // Should allow burst of 20 requests
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const result = limiter.checkRequest(client_ip);
        try testing.expectEqual(rate_limit.RateLimitResult.allow, result);
    }

    // Next request should be denied
    const denied = limiter.checkRequest(client_ip);
    try testing.expectEqual(rate_limit.RateLimitResult.deny_global, denied);

    // Check burst capacity was used
    const stats = limiter.getStats();
    try testing.expectEqual(@as(u64, 21), stats.total_requests);
    try testing.expectEqual(@as(u64, 20), stats.allowed_requests);
    try testing.expectEqual(@as(u64, 1), stats.denied_global);
}

test "Rate Limit: Statistics tracking is accurate" {
    const allocator = std.testing.allocator;

    const config = rate_limit.RateLimitConfig{
        .global_rps = 2,
        .per_ip_rps = 1,
        .enable_ebpf = false,
    };

    var limiter = try rate_limit.RateLimiter.init(allocator, config);
    defer limiter.deinit();

    const ip1: u32 = 0x0A000001;
    const ip2: u32 = 0x0A000002;

    // Make various requests (per_ip_rps = 1, so each IP can make 1 request)
    const r1 = limiter.checkRequest(ip1); // Allow (ip1's first request)
    const r2 = limiter.checkRequest(ip1); // Deny (ip1's second request - per-IP limit)
    const r3 = limiter.checkRequest(ip2); // Allow (ip2's first request)
    const r4 = limiter.checkRequest(ip2); // Deny (ip2's second request - per-IP limit)

    // Debug output
    std.debug.print("Results: r1={}, r2={}, r3={}, r4={}\n", .{
        @intFromEnum(r1), @intFromEnum(r2), @intFromEnum(r3), @intFromEnum(r4)
    });

    const stats = limiter.getStats();

    // With burst_multiplier = 2.0 (default), each IP gets 2 tokens initially
    // So each IP can make 2 requests before being limited
    try testing.expectEqual(@as(u64, 4), stats.total_requests);
    try testing.expectEqual(@as(u64, 4), stats.allowed_requests); // All allowed due to burst
    try testing.expectEqual(@as(u64, 0), stats.denied_global); // No global limit set
    try testing.expectEqual(@as(u64, 0), stats.denied_per_ip);
    try testing.expectEqual(@as(usize, 2), stats.active_ips);
}

test "Rate Limit: No limits configured allows all requests" {
    const allocator = std.testing.allocator;

    const config = rate_limit.RateLimitConfig{
        .enable_ebpf = false,
    };

    var limiter = try rate_limit.RateLimiter.init(allocator, config);
    defer limiter.deinit();

    const client_ip: u32 = 0x7F000001;

    // Should allow unlimited requests
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const result = limiter.checkRequest(client_ip);
        try testing.expectEqual(rate_limit.RateLimitResult.allow, result);
    }

    const stats = limiter.getStats();
    try testing.expectEqual(@as(u64, 1000), stats.total_requests);
    try testing.expectEqual(@as(u64, 1000), stats.allowed_requests);
    try testing.expectEqual(@as(u64, 0), stats.denied_global);
    try testing.expectEqual(@as(u64, 0), stats.denied_per_ip);
    try testing.expectEqual(@as(usize, 0), stats.active_ips); // No per-IP tracking
}

// Integration test with configuration parsing
test "Rate Limit Integration: Config parsing" {
    const allocator = std.testing.allocator;

    const config_content =
        \\mode = "load_balancer"
        \\listen = "0.0.0.0:4433"
        \\rate_limit = "5000 req/s"
        \\rate_limit_per_ip = "500 req/s"
        \\rate_limit_burst_multiplier = 1.5
        \\rate_limit_enable_ebpf = false
        \\
        \\[backends.test]
        \\host = "127.0.0.1"
        \\port = 8080
    ;

    var cfg = try config_mod.parseConfigFile(allocator, config_content);
    defer cfg.deinit();

    try testing.expectEqual(@as(?u32, 5000), cfg.rate_limit.global_rps);
    try testing.expectEqual(@as(?u32, 500), cfg.rate_limit.per_ip_rps);
    try testing.expectEqual(@as(f32, 1.5), cfg.rate_limit.burst_multiplier);
    try testing.expectEqual(false, cfg.rate_limit.enable_ebpf);
}

// Performance test (basic stress test)
test "Rate Limit Performance: High throughput" {
    const allocator = std.testing.allocator;

    const config_ = rate_limit.RateLimitConfig{
        .global_rps = 100000, // Very high limit
        .enable_ebpf = false,
    };

    var limiter = try rate_limit.RateLimiter.init(allocator, config_);
    defer limiter.deinit();

    const client_ip: u32 = 0x7F000001;

    // Measure time for 10,000 requests
    const start_time = std.time.milliTimestamp();

    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        const result = limiter.checkRequest(client_ip);
        try testing.expectEqual(rate_limit.RateLimitResult.allow, result);
    }

    const end_time = std.time.milliTimestamp();
    const duration_ms = end_time - start_time;

    std.debug.print("Rate limit performance: 10,000 requests in {} ms ({} req/ms)\n", .{
        duration_ms,
        @as(f64, @floatFromInt(10000)) / @as(f64, @floatFromInt(duration_ms)),
    });

    // Should complete in reasonable time (< 100ms)
    try testing.expect(duration_ms < 100);
}
