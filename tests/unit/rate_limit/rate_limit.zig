//! Rate limiting implementation for Blitz edge gateway
//! Hybrid eBPF + userspace approach for maximum performance and compatibility

const std = @import("std");
const builtin = @import("builtin");

/// Rate limiting configuration
pub const RateLimitConfig = struct {
    /// Global rate limit (requests per second across all clients)
    global_rps: ?u32 = null,

    /// Per-IP rate limit (requests per second per client IP)
    per_ip_rps: ?u32 = null,

    /// Burst allowance multiplier (how many seconds of burst to allow)
    burst_multiplier: f32 = 2.0,

    /// Whether to use eBPF acceleration (Linux only)
    enable_ebpf: bool = true,

    /// Cleanup interval for expired entries (seconds)
    cleanup_interval_seconds: u32 = 60,
};

/// Rate limiting decision result
pub const RateLimitResult = enum {
    /// Request allowed
    allow,

    /// Request denied due to global limit
    deny_global,

    /// Request denied due to per-IP limit
    deny_per_ip,

    /// Rate limiter temporarily unavailable
    unavailable,
};

/// Rate limiting statistics
pub const RateLimitStats = struct {
    /// Total requests processed
    total_requests: u64 = 0,

    /// Requests allowed
    allowed_requests: u64 = 0,

    /// Requests denied (global limit)
    denied_global: u64 = 0,

    /// Requests denied (per-IP limit)
    denied_per_ip: u64 = 0,

    /// Current active IP addresses being tracked
    active_ips: usize = 0,

    /// Memory usage in bytes
    memory_usage: usize = 0,
};

/// Main rate limiter interface
pub const RateLimiter = struct {
    config: RateLimitConfig,
    allocator: std.mem.Allocator,

    /// Global token bucket state
    global_tokens: f64 = 0,
    global_last_update: i64 = 0,

    /// Per-IP tracking (userspace fallback)
    ip_buckets: std.AutoHashMap(u32, IpBucket),

    /// Statistics
    stats: RateLimitStats = .{},

    /// eBPF context (when available)
    ebpf_ctx: ?EbpfContext = null,

    const IpBucket = struct {
        tokens: f64,
        last_update: i64,
    };

    const EbpfContext = struct {
        /// eBPF program FD
        prog_fd: i32 = -1,

        /// eBPF map FDs
        global_map_fd: i32 = -1,
        ip_map_fd: i32 = -1,

        /// XDP interface index
        ifindex: u32 = 0,
    };

    /// Initialize rate limiter
    pub fn init(allocator: std.mem.Allocator, config: RateLimitConfig) !RateLimiter {
        var limiter = RateLimiter{
            .config = config,
            .allocator = allocator,
            .ip_buckets = std.AutoHashMap(u32, IpBucket).init(allocator),
        };

        // Try to initialize eBPF if enabled and on Linux
        if (config.enable_ebpf and builtin.os.tag == .linux) {
            limiter.ebpf_ctx = try initEbpf(&limiter);
        }

        return limiter;
    }

    /// Deinitialize rate limiter
    pub fn deinit(self: *RateLimiter) void {
        if (self.ebpf_ctx) |*ctx| {
            deinitEbpf(ctx);
        }
        self.ip_buckets.deinit();
    }

    /// Check if a request should be allowed
    pub fn checkRequest(self: *RateLimiter, client_ip: u32) RateLimitResult {
        self.stats.total_requests += 1;

        // If eBPF is available, use it for high-performance checking
        if (self.ebpf_ctx) |*ctx| {
            return self.checkEbpf(client_ip, ctx);
        }

        // Fall back to userspace implementation
        return self.checkUserspace(client_ip);
    }

    /// Userspace rate limiting implementation
    fn checkUserspace(self: *RateLimiter, client_ip: u32) RateLimitResult {
        const now = std.time.milliTimestamp();

        // Check global limit first
        if (self.config.global_rps) |global_limit| {
            const global_result = self.checkGlobalLimit(now, global_limit);
            if (global_result != .allow) {
                self.stats.denied_global += 1;
                return global_result;
            }
        }

        // Check per-IP limit
        if (self.config.per_ip_rps) |ip_limit| {
            const ip_result = self.checkIpLimit(client_ip, now, ip_limit);
            if (ip_result != .allow) {
                self.stats.denied_per_ip += 1;
                return ip_result;
            }
        }

        self.stats.allowed_requests += 1;
        return .allow;
    }

    /// Check global rate limit using token bucket
    fn checkGlobalLimit(self: *RateLimiter, now: i64, limit_rps: u32) RateLimitResult {
        const limit_per_second: f64 = @floatFromInt(limit_rps);
        const burst_limit = limit_per_second * self.config.burst_multiplier;

        // Calculate tokens to add since last update
        const time_diff_seconds: f64 = @as(f64, @floatFromInt(now - self.global_last_update)) / 1000.0;
        const tokens_to_add = time_diff_seconds * limit_per_second;

        self.global_tokens = @min(self.global_tokens + tokens_to_add, burst_limit);
        self.global_last_update = now;

        // Check if we have tokens
        if (self.global_tokens >= 1.0) {
            self.global_tokens -= 1.0;
            return .allow;
        }

        return .deny_global;
    }

    /// Check per-IP rate limit
    fn checkIpLimit(self: *RateLimiter, client_ip: u32, now: i64, limit_rps: u32) RateLimitResult {
        const limit_per_second: f64 = @floatFromInt(limit_rps);
        const burst_limit = limit_per_second * self.config.burst_multiplier;

        // Get or create IP bucket
        var bucket = self.ip_buckets.get(client_ip) orelse IpBucket{
            .tokens = burst_limit, // Start with full burst allowance
            .last_update = now,
        };

        // Calculate tokens to add since last update
        const time_diff_seconds: f64 = @as(f64, @floatFromInt(now - bucket.last_update)) / 1000.0;
        const tokens_to_add = time_diff_seconds * limit_per_second;

        bucket.tokens = @min(bucket.tokens + tokens_to_add, burst_limit);
        bucket.last_update = now;

        // Update the bucket in the map
        self.ip_buckets.put(client_ip, bucket) catch {
            // If we can't update, allow the request (fail open)
            return .allow;
        };

        // Check if we have tokens
        if (bucket.tokens >= 1.0) {
            bucket.tokens -= 1.0;
            self.ip_buckets.put(client_ip, bucket) catch {};
            return .allow;
        }

        return .deny_per_ip;
    }

    /// eBPF-based rate limiting (high performance path)
    fn checkEbpf(self: *RateLimiter, client_ip: u32, ctx: *EbpfContext) RateLimitResult {
        // TODO: Implement eBPF rate limiting
        // This would involve:
        // 1. XDP program that checks eBPF maps
        // 2. Updates counters and makes drop/allow decisions
        // 3. Returns result to userspace

        _ = ctx; // Not used yet

        // For now, fall back to userspace
        return self.checkUserspace(client_ip);
    }

    /// Initialize eBPF context (Linux only)
    fn initEbpf(self: *RateLimiter) !EbpfContext {
        _ = self;

        // TODO: Implement eBPF initialization
        // This would involve:
        // 1. Loading eBPF program
        // 2. Creating eBPF maps for counters
        // 3. Attaching XDP program to network interface
        // 4. Setting up cleanup handlers

        // For now, return error to fall back to userspace
        return error.EbpfNotAvailable;
    }

    /// Deinitialize eBPF context
    fn deinitEbpf(ctx: *EbpfContext) void {
        _ = ctx;

        // TODO: Implement eBPF cleanup
        // Close FDs, detach XDP program, etc.
    }

    /// Get current statistics
    pub fn getStats(self: *const RateLimiter) RateLimitStats {
        var stats = self.stats;
        stats.active_ips = self.ip_buckets.count();
        stats.memory_usage = self.ip_buckets.capacity() * @sizeOf(IpBucket) + @sizeOf(RateLimiter);
        return stats;
    }

    /// Cleanup expired entries (call periodically)
    pub fn cleanup(self: *RateLimiter) void {
        const now = std.time.milliTimestamp();
        const expiry_time = now - (@as(i64, @intCast(self.config.cleanup_interval_seconds)) * 1000);

        var iterator = self.ip_buckets.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.last_update < expiry_time) {
                _ = self.ip_buckets.remove(entry.key_ptr.*);
            }
        }
    }
};

// Error types
pub const RateLimitError = error{
    EbpfNotAvailable,
    EbpfLoadFailed,
    InvalidConfig,
};
