//! Configuration management for Blitz QUIC/HTTP3 server
//! Supports both origin server and load balancer modes

const std = @import("std");

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

    /// Memory allocator
    allocator: std.mem.Allocator,

    pub const Mode = enum {
        origin,     // Single origin server
        load_balancer, // Load balancer mode
    };

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .backends = std.ArrayList(Backend).init(allocator),
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
        self.backends.deinit();
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

    var lines = std.mem.split(u8, content, "\n");
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
        }
    } else if (std.mem.startsWith(u8, section.?, "backends.")) {
        // Backend configuration
        // For simplicity, we'll just add all backends in order
        // In a real implementation, you'd want to group by backend name
        if (std.mem.eql(u8, key, "host")) {
            const backend = Backend{
                .host = try config.allocator.dupe(u8, value),
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
    FileNotFound,
    ParseError,
};
