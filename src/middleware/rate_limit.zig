//! Rate limiting implementation for Blitz edge gateway
//! Hybrid eBPF + userspace approach for maximum performance and compatibility

const std = @import("std");
const builtin = @import("builtin");
const ebpf = @import("ebpf.zig");

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

/// Rate limiting statistics (internal, thread-safe atomic version)
const RateLimitStatsInternal = struct {
    /// Total requests processed
    total_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Requests allowed
    allowed_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Requests denied (global limit)
    denied_global: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Requests denied (per-IP limit)
    denied_per_ip: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Current active IP addresses being tracked
    active_ips: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Memory usage in bytes
    memory_usage: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

/// Rate limiting statistics (public, non-atomic snapshot)
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

    /// Mutex to protect concurrent access to ip_buckets
    ip_buckets_mutex: std.Thread.Mutex = .{},

    /// Mutex to protect concurrent access to global token bucket
    global_tokens_mutex: std.Thread.Mutex = .{},

    /// Statistics (thread-safe atomic counters)
    stats: RateLimitStatsInternal = .{},

    /// eBPF manager (when available)
    ebpf_manager: ?ebpf.EbpfManager = null,

    const IpBucket = struct {
        tokens: f64,
        last_update: i64,
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
            limiter.ebpf_manager = initEbpf(&limiter) catch {
                // initEbpf already logs warnings, so we continue in userspace-only mode
                null;
            };
        }

        return limiter;
    }

    /// Deinitialize rate limiter
    pub fn deinit(self: *RateLimiter) void {
        if (self.ebpf_manager) |*manager| {
            manager.deinit();
        }
        self.ip_buckets.deinit();
    }

    /// Check if a request should be allowed
    pub fn checkRequest(self: *RateLimiter, client_ip: u32) RateLimitResult {
        _ = self.stats.total_requests.fetchAdd(1, .monotonic);

        // If eBPF is available, use it for high-performance checking
        if (self.ebpf_manager) |*manager| {
            return self.checkEbpf(client_ip, manager);
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
                _ = self.stats.denied_global.fetchAdd(1, .monotonic);
                return global_result;
            }
        }

        // Check per-IP limit
        if (self.config.per_ip_rps) |ip_limit| {
            const ip_result = self.checkIpLimit(client_ip, now, ip_limit);
            if (ip_result != .allow) {
                _ = self.stats.denied_per_ip.fetchAdd(1, .monotonic);
                return ip_result;
            }
        }

        _ = self.stats.allowed_requests.fetchAdd(1, .monotonic);
        return .allow;
    }

    /// Check global rate limit using token bucket
    fn checkGlobalLimit(self: *RateLimiter, now: i64, limit_rps: u32) RateLimitResult {
        const limit_per_second: f64 = @floatFromInt(limit_rps);
        const burst_limit = limit_per_second * self.config.burst_multiplier;

        // Serialize concurrent access to global token bucket state
        self.global_tokens_mutex.lock();
        defer self.global_tokens_mutex.unlock();

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

        // Serialize concurrent access to ip_buckets map
        self.ip_buckets_mutex.lock();
        defer self.ip_buckets_mutex.unlock();

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

        // Check if we have tokens and decrement if available
        if (bucket.tokens >= 1.0) {
            bucket.tokens -= 1.0;
            // Update the bucket in the map after decrementing tokens
            self.ip_buckets.put(client_ip, bucket) catch {
                // If we can't update, allow the request (fail open)
                return .allow;
            };
            return .allow;
        }

        // Update the bucket even if we're denying (to track token state)
        self.ip_buckets.put(client_ip, bucket) catch {
            // If we can't update, deny the request (fail closed)
        };

        return .deny_per_ip;
    }

    /// eBPF-based rate limiting (high performance path)
    fn checkEbpf(self: *RateLimiter, client_ip: u32, manager: *ebpf.EbpfManager) RateLimitResult {
        // In a real eBPF implementation, this would query the eBPF maps
        // to check if the packet was dropped by XDP. For now, we simulate
        // the behavior and fall back to userspace checking.

        // The actual eBPF program runs in kernel space and drops packets
        // at the network interface level. This function would typically
        // be used for statistics and fallback logic.

        _ = manager; // Not used in simulation

        // For benchmarking purposes, we'll do a lightweight check
        // In production, this would query eBPF map statistics

        // Fall back to userspace for now (eBPF implementation is simulated)
        return self.checkUserspace(client_ip);
    }

    /// Initialize eBPF manager (Linux only)
    fn initEbpf(self: *RateLimiter) !ebpf.EbpfManager {
        var manager = ebpf.EbpfManager.init(self.allocator);
        var should_deinit = true;
        defer if (should_deinit) manager.deinit();

        // Try to compile and load the eBPF program
        const ebpf_source = "src/middleware/ebpf_rate_limit.c";
        const ebpf_object = "ebpf_rate_limit.o";

        // Compile eBPF program (only if source exists and clang is available)
        ebpf.compileEbpfProgram(ebpf_source, ebpf_object) catch |err| {
            std.log.warn("eBPF compilation failed ({any}), falling back to userspace", .{err});
            return err;
        };

        // Load eBPF program
        manager.loadEbpfProgram(ebpf_object) catch |err| {
            std.log.warn("eBPF program loading failed ({any}), falling back to userspace", .{err});
            return err;
        };

        // Create eBPF maps
        manager.createMaps() catch |err| {
            std.log.warn("eBPF map creation failed ({any}), falling back to userspace", .{err});
            return err;
        };

        // Load eBPF program into kernel
        manager.loadProgram() catch |err| {
            std.log.warn("eBPF program loading failed ({any}), falling back to userspace", .{err});
            return err;
        };

        // Try to attach to network interface (eth0 by default)
        manager.attachXdp("eth0") catch |err| {
            std.log.warn("XDP attachment failed ({any}), eBPF rate limiting disabled", .{err});
            std.log.info("eBPF program loaded but not attached - falling back to userspace", .{});
            return err;
        };

        // Configure rate limiting parameters
        const ebpf_config = ebpf.EbpfRateLimitConfig{
            .global_rps = self.config.global_rps orelse 0,
            .per_ip_rps = self.config.per_ip_rps orelse 0,
            .window_seconds = 1, // 1 second window
        };

        manager.updateConfig(ebpf_config) catch |err| {
            std.log.warn("eBPF config update failed ({any}), falling back to userspace", .{err});
            return err;
        };

        std.log.info("eBPF rate limiting successfully initialized and attached to eth0", .{});

        // Success - cancel the deferred deinit to avoid double-free
        should_deinit = false;
        return manager;
    }

    /// Get current statistics (returns a non-atomic snapshot)
    pub fn getStats(self: *const RateLimiter) RateLimitStats {
        // Serialize concurrent access to ip_buckets map for reading
        // Note: mutex.lock() requires mutable access, so we use @constCast
        // This is safe because we're only reading and the mutex protects the map
        const mutable_self = @constCast(self);
        mutable_self.ip_buckets_mutex.lock();
        defer mutable_self.ip_buckets_mutex.unlock();

        return RateLimitStats{
            .total_requests = self.stats.total_requests.load(.monotonic),
            .allowed_requests = self.stats.allowed_requests.load(.monotonic),
            .denied_global = self.stats.denied_global.load(.monotonic),
            .denied_per_ip = self.stats.denied_per_ip.load(.monotonic),
            .active_ips = self.ip_buckets.count(),
            .memory_usage = self.ip_buckets.capacity() * @sizeOf(IpBucket) + @sizeOf(RateLimiter),
        };
    }

    /// Cleanup expired entries (call periodically)
    pub fn cleanup(self: *RateLimiter) void {
        const now = std.time.milliTimestamp();
        const expiry_time = now - (@as(i64, @intCast(self.config.cleanup_interval_seconds)) * 1000);

        // Serialize concurrent access to ip_buckets map
        self.ip_buckets_mutex.lock();
        defer self.ip_buckets_mutex.unlock();

        // First pass: collect keys to remove
        var keys_to_remove = std.ArrayList(u32).init(self.allocator);
        defer keys_to_remove.deinit();

        var iterator = self.ip_buckets.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.last_update < expiry_time) {
                keys_to_remove.append(entry.key_ptr.*) catch {
                    // If we can't allocate, skip this key and continue
                    continue;
                };
            }
        }

        // Second pass: remove collected keys
        for (keys_to_remove.items) |key| {
            _ = self.ip_buckets.remove(key);
        }
    }
};

// Error types
pub const RateLimitError = error{
    EbpfNotAvailable,
    EbpfLoadFailed,
    InvalidConfig,
};
