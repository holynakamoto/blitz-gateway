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
        try writer.print("{s}:{d} (weight: {})", .{ self.host, self.port, self.weight });
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

    /// Authorization scheme
    scheme: []const u8 = "Bearer",

    /// Paths that don't require authentication
    unprotected_paths: std.ArrayList([]const u8) = undefined,

    pub fn init(allocator: std.mem.Allocator) JwtConfig {
        return .{
            .unprotected_paths = std.ArrayList([]const u8).initCapacity(allocator, 0) catch @panic("Failed to init unprotected_paths list"),
        };
    }

    pub fn deinit(self: *JwtConfig, allocator: std.mem.Allocator) void {
        if (self.secret) |s| allocator.free(s);
        if (self.public_key) |pk| allocator.free(pk);
        if (self.issuer) |iss| allocator.free(iss);
        if (self.audience) |aud| allocator.free(aud);
        allocator.free(self.header_name);
        allocator.free(self.scheme);

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

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .backends = std.ArrayList(Backend).initCapacity(allocator, 0) catch @panic("Failed to init backends list"),
            .jwt = JwtConfig.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
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

        const owned_backend = Backend{
            .host = host,
            .port = backend.port,
            .weight = backend.weight,
            .health_check_path = health_path,
        };

        try self.backends.append(owned_backend);
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
    var config = Config.init(allocator);
    errdefer config.deinit();

    var lines = std.mem.splitSequence(u8, content, "\n");
    var current_section: ?[]const u8 = null;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) {
            continue; // Skip empty lines and comments
        }

        if (std.mem.startsWith(u8, trimmed, "[") and std.mem.endsWith(u8, trimmed, "]")) {
            // Section header
            current_section = trimmed[1 .. trimmed.len - 1];
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

            try parseKeyValue(&config, current_section, key, clean_value);
        }
    }

    try config.validate();
    return config;
}

fn parseKeyValue(config: *Config, section: ?[]const u8, key: []const u8, value: []const u8) !void {
    if (section == null) {
        // Global configuration
        if (std.mem.eql(u8, key, "listen")) {
            if (std.mem.indexOf(u8, value, ":")) |colon_pos| {
                config.listen_addr = try config.allocator.dupe(u8, value[0..colon_pos]);
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
        // Backend configuration
        // For simplicity, we'll just add all backends in order
        // In a real implementation, you'd want to group by backend name
        if (std.mem.eql(u8, key, "host")) {
            const backend = Backend{
                .host = try config.allocator.dupe(u8, value),
                .port = 8080, // Default, will be overridden
            };
            try config.addBackend(backend);
        } else if (std.mem.eql(u8, key, "port")) {
            if (config.backends.items.len > 0) {
                const port = try std.fmt.parseInt(u16, value, 10);
                config.backends.items[config.backends.items.len - 1].port = port;
            }
        } else if (std.mem.eql(u8, key, "weight")) {
            if (config.backends.items.len > 0) {
                const weight = try std.fmt.parseInt(u32, value, 10);
                config.backends.items[config.backends.items.len - 1].weight = weight;
            }
        } else if (std.mem.eql(u8, key, "health_check_path")) {
            if (config.backends.items.len > 0) {
                const path = try config.allocator.dupe(u8, value);
                config.backends.items[config.backends.items.len - 1].health_check_path = path;
            }
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
