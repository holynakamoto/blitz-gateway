//! WASM Plugin System Types and Interfaces
//! Defines the contract between host (Blitz Gateway) and WASM plugins

const std = @import("std");
const http = @import("../http/parser.zig");

/// Plugin execution context
pub const PluginContext = struct {
    allocator: std.mem.Allocator,
    plugin_id: []const u8,
    request_id: u64,

    /// Plugin-specific data store
    data: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, plugin_id: []const u8, request_id: u64) PluginContext {
        return .{
            .allocator = allocator,
            .plugin_id = plugin_id,
            .request_id = request_id,
            .data = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *PluginContext) void {
        var it = self.data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.deinit();
    }
};

/// Plugin result status
pub const PluginResult = enum {
    /// Continue processing (success)
    ok,
    /// Stop processing with success (e.g., handled request)
    stop,
    /// Error occurred, stop processing
    @"error",
};

/// Plugin execution result
pub const ExecutionResult = struct {
    status: PluginResult,
    error_message: ?[]const u8 = null,
    http_status_code: ?u16 = null,

    pub fn success() ExecutionResult {
        return .{ .status = .ok };
    }

    pub fn stopped() ExecutionResult {
        return .{ .status = .stop };
    }

    pub fn failed(message: []const u8, http_status: ?u16) ExecutionResult {
        return .{
            .status = .@"error",
            .error_message = message,
            .http_status_code = http_status,
        };
    }
};

/// Plugin types (what stage of request processing they handle)
pub const PluginType = enum {
    /// Request preprocessing (before routing)
    request_preprocess,
    /// Custom routing logic
    routing,
    /// Authentication/authorization
    auth,
    /// Request transformation
    request_transform,
    /// Backend communication (before sending to backend)
    backend_pre,
    /// Response transformation (after backend response)
    response_transform,
    /// Response postprocessing (before sending to client)
    response_postprocess,
    /// Custom metrics/logging
    observability,
};

/// Plugin configuration
pub const PluginConfig = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    version: []const u8,
    type: PluginType,

    /// WASM module path (file path or URL)
    wasm_path: []const u8,

    /// Plugin-specific configuration (JSON)
    config: ?[]const u8 = null,

    /// Execution priority (lower numbers execute first)
    priority: u16 = 100,

    /// Execution timeout in milliseconds
    timeout_ms: u32 = 5000,

    /// Memory limit in bytes
    memory_limit: u32 = 1024 * 1024, // 1MB default

    /// Enable/disable plugin
    enabled: bool = true,

    pub fn deinit(self: *PluginConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.description) |desc| allocator.free(desc);
        allocator.free(self.version);
        allocator.free(self.wasm_path);
        if (self.config) |cfg| allocator.free(cfg);
    }
};

/// Host function registry
/// Maps function names to implementations that plugins can call
pub const HostFunctionRegistry = struct {
    allocator: std.mem.Allocator,
    functions: std.StringHashMap(*const fn (ctx: *PluginContext, args: []const []const u8) anyerror![]const u8),

    pub fn init(allocator: std.mem.Allocator) HostFunctionRegistry {
        return .{
            .allocator = allocator,
            .functions = std.StringHashMap(*const fn (ctx: *PluginContext, args: []const []const u8) anyerror![]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *HostFunctionRegistry) void {
        var it = self.functions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.functions.deinit();
    }

    /// Register a host function
    pub fn register(self: *HostFunctionRegistry, name: []const u8, func: *const fn (ctx: *PluginContext, args: []const []const u8) anyerror![]const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        try self.functions.put(name_copy, func);
    }

    /// Call a registered host function
    pub fn call(self: *const HostFunctionRegistry, name: []const u8, ctx: *PluginContext, args: []const []const u8) ![]const u8 {
        const func = self.functions.get(name) orelse return error.FunctionNotFound;
        return func(ctx, args);
    }
};

/// Plugin instance interface
pub const PluginInstance = struct {
    config: PluginConfig,
    instance: *anyopaque, // WASM runtime instance
    last_used: i64,

    /// Execute plugin with request context
    execute_fn: *const fn (
        instance: *anyopaque,
        ctx: *PluginContext,
        request: ?*http.Request,
        response: ?*http.Response,
    ) anyerror!ExecutionResult,

    /// Cleanup plugin instance
    cleanup_fn: *const fn (instance: *anyopaque) void,

    pub fn execute(
        self: *PluginInstance,
        ctx: *PluginContext,
        request: ?*http.Request,
        response: ?*http.Response,
    ) !ExecutionResult {
        self.last_used = std.time.timestamp();
        return self.execute_fn(self.instance, ctx, request, response);
    }

    pub fn cleanup(self: *PluginInstance) void {
        self.cleanup_fn(self.instance);
    }
};

/// Plugin registry manages loaded plugins
pub const PluginRegistry = struct {
    allocator: std.mem.Allocator,
    plugins: std.StringHashMap(PluginInstance),
    host_functions: HostFunctionRegistry,

    pub fn init(allocator: std.mem.Allocator) PluginRegistry {
        return .{
            .allocator = allocator,
            .plugins = std.StringHashMap(PluginInstance).init(allocator),
            .host_functions = HostFunctionRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *PluginRegistry) void {
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.cleanup();
            entry.value_ptr.config.deinit(self.allocator);
        }
        self.plugins.deinit();
        self.host_functions.deinit();
    }

    /// Register a plugin instance
    pub fn register(self: *PluginRegistry, instance: PluginInstance) !void {
        const id_copy = try self.allocator.dupe(u8, instance.config.id);
        try self.plugins.put(id_copy, instance);
    }

    /// Get a plugin by ID
    pub fn get(self: *const PluginRegistry, id: []const u8) ?*PluginInstance {
        return self.plugins.getPtr(id);
    }

    /// Remove a plugin
    pub fn remove(self: *PluginRegistry, id: []const u8) bool {
        if (self.plugins.fetchRemove(id)) |kv| {
            self.allocator.free(kv.key);
            kv.value.cleanup();
            kv.value.config.deinit(self.allocator);
            return true;
        }
        return false;
    }

    /// Get all plugins of a specific type
    pub fn getByType(self: *const PluginRegistry, plugin_type: PluginType, allocator: std.mem.Allocator) ![]*PluginInstance {
        var result = std.ArrayList(*PluginInstance).init(allocator);
        defer result.deinit();

        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.config.type == plugin_type and entry.value_ptr.config.enabled) {
                try result.append(entry.value_ptr);
            }
        }

        // Sort by priority (lower numbers first)
        std.sort.insertion(*PluginInstance, result.items, {}, struct {
            fn lessThan(_: void, a: *PluginInstance, b: *PluginInstance) bool {
                return a.config.priority < b.config.priority;
            }
        }.lessThan);

        return result.toOwnedSlice();
    }
};
