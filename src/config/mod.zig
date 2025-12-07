//! Configuration management for Blitz QUIC/HTTP3 server
//! Supports both origin server and load balancer modes

const std = @import("std");
// RateLimitConfig is defined in this file, no need to import

/// Backend server configuration for load balancer mode
pub const Backend = struct {
    host: []const u8,
    port: u16,
    weight: u32 = 10,
    health_check_path: ?[]const u8 = null,

    pub fn format(
        self: Backend,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}:{d} (weight: {d})", .{ self.host, self.port, self.weight });
        if (self.health_check_path) |path| {
            try writer.print(" health:{s}", .{path});
        }
    }
};

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

/// Metrics configuration
pub const MetricsConfig = struct {
    /// Enable metrics collection
    enabled: bool = false,

    /// Metrics server port
    port: u16 = 9090,

    /// Enable Prometheus exposition format
    prometheus_enabled: bool = true,

    /// OTLP endpoint (optional)
    otlp_endpoint: ?[]const u8 = null,

    /// Collection interval in seconds
    collection_interval_seconds: u32 = 10,
};

/// JWT authentication configuration
pub const JwtConfig = struct {
    /// Enable JWT authentication
    enabled: bool = false,

    /// JWT algorithm (HS256, RS256, ES256)
    algorithm: []const u8 = "HS256",

    /// Secret key for HS256 (required for HS256)
    secret: ?[]const u8 = null,

    /// RSA/ECDSA public key for RS256/ES256 (PEM format)
    public_key: ?[]const u8 = null,

    /// Expected issuer (optional validation)
    issuer: ?[]const u8 = null,

    /// Expected audience (optional validation)
    audience: ?[]const u8 = null,

    /// Clock skew tolerance in seconds
    leeway_seconds: i64 = 0,

    /// Authorization header name
    header_name: []const u8 = "Authorization",
    header_name_allocated: bool = false,

    /// Authorization scheme
    scheme: []const u8 = "Bearer",
    scheme_allocated: bool = false,

    /// Paths that don't require authentication
    unprotected_paths: std.ArrayList([]const u8) = undefined,

    pub fn init(allocator: std.mem.Allocator) !JwtConfig {
        return .{
            .unprotected_paths = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .header_name_allocated = false,
            .scheme_allocated = false,
        };
    }

    pub fn deinit(self: *JwtConfig, allocator: std.mem.Allocator) void {
        if (self.secret) |s| allocator.free(s);
        if (self.public_key) |pk| allocator.free(pk);
        if (self.issuer) |iss| allocator.free(iss);
        if (self.audience) |aud| allocator.free(aud);
        // Only free header_name if it was dynamically allocated
        if (self.header_name_allocated) {
            allocator.free(self.header_name);
        }
        // Only free scheme if it was dynamically allocated
        if (self.scheme_allocated) {
            allocator.free(self.scheme);
        }

        for (self.unprotected_paths.items) |path| {
            allocator.free(path);
        }
        self.unprotected_paths.deinit(allocator);
    }

    /// Check if a path requires authentication
    pub fn requiresAuth(self: *const JwtConfig, path: []const u8) bool {
        for (self.unprotected_paths.items) |unprotected| {
            if (std.mem.eql(u8, path, unprotected)) {
                return false;
            }
        }
        return true;
    }
};

/// Main configuration structure
pub const Config = struct {
    /// Server mode
    mode: Mode = .origin,

    /// Listen address for server/load balancer
    listen_addr: []const u8 = "0.0.0.0",

    /// Whether listen_addr was dynamically allocated (for proper cleanup)
    listen_addr_allocated: bool = false,

    /// Listen port for server/load balancer
    listen_port: u16 = 4433,

    /// Backend servers (for load balancer mode)
    backends: std.ArrayList(Backend),

    /// Rate limiting configuration
    rate_limit: RateLimitConfig = .{},

    /// Metrics configuration
    metrics: MetricsConfig = .{},

    /// JWT authentication configuration
    jwt: JwtConfig = .{},

    /// Memory allocator
    allocator: std.mem.Allocator,

    pub const Mode = enum {
        origin, // Single origin server
        load_balancer, // Load balancer mode
    };

    pub fn init(allocator: std.mem.Allocator) !Config {
        return Config{
            .backends = try std.ArrayList(Backend).initCapacity(allocator, 0),
            .jwt = try JwtConfig.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
        // Free listen_addr if it was allocated
        if (self.listen_addr_allocated) {
            self.allocator.free(self.listen_addr);
        }

        // Free metrics endpoint if allocated
        if (self.metrics.otlp_endpoint) |endpoint| {
            self.allocator.free(endpoint);
        }

        for (self.backends.items) |*backend| {
            self.allocator.free(backend.host);
            if (backend.health_check_path) |path| {
                self.allocator.free(path);
            }
        }
        self.backends.deinit(self.allocator);
        self.jwt.deinit(self.allocator);
    }

    pub fn addBackend(self: *Config, backend: Backend) !void {
        // Duplicate strings to own the memory
        const host = try self.allocator.dupe(u8, backend.host);
        errdefer self.allocator.free(host);

        var health_path: ?[]const u8 = null;
        if (backend.health_check_path) |path| {
            health_path = try self.allocator.dupe(u8, path);
        }
        errdefer if (health_path) |p| self.allocator.free(p);

        const owned_backend = Backend{
            .host = host,
            .port = backend.port,
            .weight = backend.weight,
            .health_check_path = health_path,
        };

        try self.backends.append(self.allocator, owned_backend);
    }

    pub fn validate(self: *const Config) !void {
        if (self.mode == .load_balancer) {
            if (self.backends.items.len == 0) {
                return error.NoBackendsConfigured;
            }

            // Validate backend configurations
            for (self.backends.items) |backend| {
                if (backend.host.len == 0) {
                    return error.InvalidBackendHost;
                }
                if (backend.port == 0) {
                    return error.InvalidBackendPort;
                }
                if (backend.weight == 0) {
                    return error.InvalidBackendWeight;
                }
            }
        }
    }
};

// Simple TOML-like config file parser (no external dependencies)
pub fn parseConfigFile(allocator: std.mem.Allocator, content: []const u8) !Config {
    var config = try Config.init(allocator);
    errdefer config.deinit();

    var lines = std.mem.splitSequence(u8, content, "\n");
    var current_section: ?[]const u8 = null;
    var current_backend_section: ?[]const u8 = null;

    // Temporary variables to accumulate backend fields
    var host_opt: ?[]const u8 = null;
    var port_opt: ?u16 = null;
    var weight_opt: ?u32 = null;
    var health_check_path_opt: ?[]const u8 = null;

    // Helper function to finalize the current backend
    const finalizeBackend = struct {
        fn call(
            cfg: *Config,
            h_opt: *?[]const u8,
            p_opt: *?u16,
            w_opt: *?u32,
            hc_opt: *?[]const u8,
        ) !void {
            if (h_opt.*) |host| {
                // Allocate exactly once: duplicate host and health_check_path
                const host_dupe = try cfg.allocator.dupe(u8, host);
                errdefer cfg.allocator.free(host_dupe);

                var health_path: ?[]const u8 = null;
                if (hc_opt.*) |path| {
                    health_path = try cfg.allocator.dupe(u8, path);
                    errdefer cfg.allocator.free(health_path.?);
                }

                // Build Backend struct with parsed port/weight defaults
                const backend = Backend{
                    .host = host_dupe,
                    .port = p_opt.* orelse 8080,
                    .weight = w_opt.* orelse 10,
                    .health_check_path = health_path,
                };

                // Append directly since we've already duplicated strings
                try cfg.backends.append(cfg.allocator, backend);

                // Clear temporaries for next backend
                h_opt.* = null;
                p_opt.* = null;
                w_opt.* = null;
                hc_opt.* = null;
            }
        }
    }.call;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) {
            continue; // Skip empty lines and comments
        }

        if (std.mem.startsWith(u8, trimmed, "[") and std.mem.endsWith(u8, trimmed, "]")) {
            // Section header - finalize previous backend if we're moving to a new backend section
            const new_section = trimmed[1 .. trimmed.len - 1];
            if (std.mem.startsWith(u8, new_section, "backends.")) {
                if (current_backend_section) |prev_section| {
                    if (!std.mem.eql(u8, prev_section, new_section)) {
                        // New backend section started, finalize previous backend
                        try finalizeBackend(&config, &host_opt, &port_opt, &weight_opt, &health_check_path_opt);
                    }
                }
                current_backend_section = new_section;
            } else {
                // Moving to non-backend section, finalize current backend if any
                if (current_backend_section != null) {
                    try finalizeBackend(&config, &host_opt, &port_opt, &weight_opt, &health_check_path_opt);
                    current_backend_section = null;
                }
            }
            current_section = new_section;
        } else if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            // Key-value pair
            const key = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
            const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);

            // Remove quotes if present
            const clean_value = if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\'')))
                value[1 .. value.len - 1]
            else
                value;

            try parseKeyValue(&config, current_section, key, clean_value, &host_opt, &port_opt, &weight_opt, &health_check_path_opt);
        }
    }

    // Finalize any remaining backend at end of file
    if (current_backend_section != null) {
        try finalizeBackend(&config, &host_opt, &port_opt, &weight_opt, &health_check_path_opt);
    }

    try config.validate();
    return config;
}

fn parseKeyValue(
    config: *Config,
    section: ?[]const u8,
    key: []const u8,
    value: []const u8,
    host_opt: *?[]const u8,
    port_opt: *?u16,
    weight_opt: *?u32,
    health_check_path_opt: *?[]const u8,
) !void {
    if (section == null) {
        // Global configuration
        if (std.mem.eql(u8, key, "listen")) {
            if (std.mem.indexOf(u8, value, ":")) |colon_pos| {
                config.listen_addr = try config.allocator.dupe(u8, value[0..colon_pos]);
                config.listen_addr_allocated = true;
                config.listen_port = try std.fmt.parseInt(u16, value[colon_pos + 1 ..], 10);
            } else {
                return error.InvalidListenFormat;
            }
        } else if (std.mem.eql(u8, key, "mode")) {
            if (std.mem.eql(u8, value, "load_balancer") or std.mem.eql(u8, value, "lb")) {
                config.mode = .load_balancer;
            } else if (std.mem.eql(u8, value, "origin")) {
                config.mode = .origin;
            } else {
                return error.InvalidMode;
            }
        } else if (std.mem.eql(u8, key, "rate_limit")) {
            // Parse rate limit as "1000 req/s" format
            if (std.mem.indexOf(u8, value, "req/s")) |pos| {
                const rate_str = value[0..pos];
                const rate = try std.fmt.parseInt(u32, std.mem.trim(u8, rate_str, &std.ascii.whitespace), 10);
                config.rate_limit.global_rps = rate;
            } else {
                return error.InvalidRateLimitFormat;
            }
        } else if (std.mem.eql(u8, key, "rate_limit_per_ip")) {
            // Parse per-IP rate limit as "100 req/s" format
            if (std.mem.indexOf(u8, value, "req/s")) |pos| {
                const rate_str = value[0..pos];
                const rate = try std.fmt.parseInt(u32, std.mem.trim(u8, rate_str, &std.ascii.whitespace), 10);
                config.rate_limit.per_ip_rps = rate;
            } else {
                return error.InvalidRateLimitFormat;
            }
        } else if (std.mem.eql(u8, key, "rate_limit_burst_multiplier")) {
            config.rate_limit.burst_multiplier = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, key, "rate_limit_enable_ebpf")) {
            config.rate_limit.enable_ebpf = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "metrics_enabled")) {
            config.metrics.enabled = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "metrics_port")) {
            config.metrics.port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, key, "metrics_otlp_endpoint")) {
            config.metrics.otlp_endpoint = try config.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "metrics_prometheus_enabled")) {
            config.metrics.prometheus_enabled = std.mem.eql(u8, value, "true");
        }
    } else if (std.mem.startsWith(u8, section.?, "backends.")) {
        // Backend configuration - accumulate fields in temporary variables
        // Do NOT call allocator.dupe() here; allocation happens once when backend is finalized
        if (std.mem.eql(u8, key, "host")) {
            host_opt.* = value;
        } else if (std.mem.eql(u8, key, "port")) {
            port_opt.* = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, key, "weight")) {
            weight_opt.* = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "health_check_path")) {
            health_check_path_opt.* = value;
        }
    }
}

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024); // 1MB max
    defer allocator.free(content);

    return try parseConfigFile(allocator, content);
}

// Error types
pub const ConfigError = error{
    InvalidListenFormat,
    InvalidMode,
    NoBackendsConfigured,
    InvalidBackendHost,
    InvalidBackendPort,
    InvalidBackendWeight,
    InvalidRateLimitFormat,
    FileNotFound,
    ParseError,
};
