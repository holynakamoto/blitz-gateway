//! WASM Plugin Manager
//! Coordinates plugin loading, execution, and lifecycle management

const std = @import("std");
const runtime = @import("runtime.zig");
const types = @import("types.zig");
const http = @import("../http/parser.zig");

/// Plugin Manager coordinates all WASM plugin operations
pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    runtime: runtime.Runtime,
    registry: types.PluginRegistry,
    config: PluginManagerConfig,

    pub const PluginManagerConfig = struct {
        /// Plugin directory for auto-discovery
        plugin_dir: ?[]const u8 = null,
        /// Enable hot-reloading of plugins
        hot_reload: bool = false,
        /// Global memory limit per plugin instance
        memory_limit: usize = 1024 * 1024, // 1MB
        /// Global execution timeout
        timeout_ms: u32 = 5000,
        /// Maximum number of plugin instances
        max_instances: usize = 100,
    };

    pub fn init(allocator: std.mem.Allocator, config: PluginManagerConfig) !PluginManager {
        // Initialize host functions
        var host_functions = types.HostFunctionRegistry.init(allocator);
        try registerHostFunctions(&host_functions);

        return PluginManager{
            .allocator = allocator,
            .runtime = runtime.Runtime.init(allocator),
            .registry = .{
                .allocator = allocator,
                .plugins = std.StringHashMap(types.PluginInstance).init(allocator),
                .host_functions = host_functions,
            },
            .config = config,
        };
    }

    pub fn deinit(self: *PluginManager) void {
        self.runtime.deinit();
        self.registry.deinit();
    }

    /// Load a plugin from configuration
    pub fn loadPlugin(self: *PluginManager, config: types.PluginConfig) !void {
        // Load WASM module
        if (std.mem.startsWith(u8, config.wasm_path, "http")) {
            // TODO: Load from HTTP URL
            return error.HttpLoadNotImplemented;
        } else {
            // Load from file
            try self.runtime.loadModuleFromFile(config.id, config.wasm_path);
        }

        // Create instance
        const instance_id = try std.fmt.allocPrint(self.allocator, "{s}-instance", .{config.id});
        defer self.allocator.free(instance_id);

        try self.runtime.createInstance(
            config.id,
            instance_id,
            &self.registry.host_functions,
            config.memory_limit,
        );

        // Get instance
        const instance = self.runtime.getInstance(instance_id) orelse return error.InstanceCreationFailed;

        // Create plugin instance
        const plugin_instance = types.PluginInstance{
            .config = config,
            .instance = instance,
            .last_used = std.time.timestamp(),
            .execute_fn = executePluginFunction,
            .cleanup_fn = cleanupPluginInstance,
        };

        // Register plugin
        try self.registry.register(plugin_instance);
    }

    /// Load plugins from directory
    pub fn loadPluginsFromDir(self: *PluginManager, dir_path: []const u8) !void {
        var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;

            const plugin_id = try self.allocator.dupe(u8, entry.name[0..entry.name.len - 5]); // Remove .wasm
            defer self.allocator.free(plugin_id);

            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });
            defer self.allocator.free(full_path);

            // Create default config
            const config = types.PluginConfig{
                .id = try self.allocator.dupe(u8, plugin_id),
                .name = try self.allocator.dupe(u8, plugin_id),
                .description = try std.fmt.allocPrint(self.allocator, "Auto-loaded plugin: {s}", .{plugin_id}),
                .version = try self.allocator.dupe(u8, "1.0.0"),
                .type = .request_preprocess, // Default type
                .wasm_path = try self.allocator.dupe(u8, full_path),
                .priority = 100,
                .timeout_ms = self.config.timeout_ms,
                .memory_limit = self.config.memory_limit,
                .enabled = true,
            };

            self.loadPlugin(config) catch |err| {
                std.log.err("Failed to load plugin {s}: {}", .{ plugin_id, err });
            };
        }
    }

    /// Execute plugins for a specific request stage
    pub fn executePlugins(
        self: *PluginManager,
        plugin_type: types.PluginType,
        ctx: *types.PluginContext,
        request: ?*http.Request,
        response: ?*http.Response,
    ) !types.ExecutionResult {
        const plugins = try self.registry.getByType(plugin_type, self.allocator);
        defer self.allocator.free(plugins);

        for (plugins) |plugin| {
            // Create execution timeout
            const timeout_ns = @as(u64, plugin.config.timeout_ms) * 1000000; // Convert to nanoseconds

            // Execute plugin with timeout
            const result = plugin.execute(ctx, request, response) catch |err| {
                std.log.err("Plugin {s} execution failed: {}", .{ plugin.config.id, err });
                return types.ExecutionResult.failed("Plugin execution failed", 500);
            };

            // Check if plugin wants to stop processing
            switch (result.status) {
                .stop, .error => return result,
                .ok => continue,
            }
        }

        return types.ExecutionResult.success();
    }

    /// Get plugin statistics
    pub fn getStats(self: *const PluginManager, allocator: std.mem.Allocator) !std.json.Value {
        var stats = std.json.ObjectMap.init(allocator);
        defer stats.deinit();

        // Count plugins by type
        var type_counts = std.json.ObjectMap.init(allocator);
        defer type_counts.deinit();

        var it = self.registry.plugins.iterator();
        while (it.next()) |entry| {
            const plugin = entry.value_ptr;
            const type_str = @tagName(plugin.config.type);

            const count = (type_counts.get(type_str) orelse std.json.Value{ .integer = 0 }).integer + 1;
            try type_counts.put(try allocator.dupe(u8, type_str), std.json.Value{ .integer = count });
        }

        try stats.put("total_plugins", std.json.Value{ .integer = @intCast(self.registry.plugins.count()) });
        try stats.put("plugins_by_type", std.json.Value{ .object = type_counts });

        return std.json.Value{ .object = stats };
    }

    /// Register built-in host functions
    fn registerHostFunctions(registry: *types.HostFunctionRegistry) !void {
        // Log function
        try registry.register("log", hostLog);

        // Get environment variable
        try registry.register("get_env", hostGetEnv);

        // Set response header
        try registry.register("set_header", hostSetHeader);

        // Get request header
        try registry.register("get_header", hostGetHeader);

        // Get request body
        try registry.register("get_body", hostGetBody);
    }
};

/// Execute plugin function (callback for PluginInstance)
fn executePluginFunction(
    instance_opaque: *anyopaque,
    ctx: *types.PluginContext,
    request: ?*http.Request,
    response: ?*http.Response,
) anyerror!types.ExecutionResult {
    const instance = @as(*runtime.Instance, @ptrCast(@alignCast(instance_opaque)));

    // Convert request/response to WASM values
    var args = std.ArrayList(runtime.Value).init(ctx.allocator);
    defer args.deinit();

    // Add request method if available
    if (request) |req| {
        try args.append(runtime.Value{ .string = @tagName(req.method) });
        try args.append(runtime.Value{ .string = req.path });
    } else {
        try args.append(runtime.Value{ .string = "" });
        try args.append(runtime.Value{ .string = "" });
    }

    // Call the appropriate plugin function
    const func_name = switch (ctx.data.get("stage") orelse "process_request") {
        "process_request" => "process_request",
        "process_response" => "process_response",
        else => "process_request",
    };

    const result = try instance.call(func_name, ctx, args.items);

    // Convert result back
    switch (result) {
        .i32 => |code| {
            if (code == 0) {
                return types.ExecutionResult.success();
            } else if (code == 1) {
                return types.ExecutionResult.stopped();
            } else {
                return types.ExecutionResult.failed("Plugin returned error", null);
            }
        },
        else => return types.ExecutionResult.failed("Invalid plugin return value", 500),
    }
}

/// Cleanup plugin instance (callback for PluginInstance)
fn cleanupPluginInstance(instance_opaque: *anyopaque) void {
    // Instance cleanup is handled by the runtime
    _ = instance_opaque;
}

// Host Functions (functions that WASM plugins can call)

/// Log function: log(level, message)
fn hostLog(ctx: *types.PluginContext, args: []const []const u8) ![]const u8 {
    if (args.len < 2) return error.InvalidArguments;

    const level = args[0];
    const message = args[1];

    std.log.info("[Plugin {s}] {s}: {s}", .{ ctx.plugin_id, level, message });

    // Return empty string (success)
    return "";
}

/// Get environment variable: get_env(name)
fn hostGetEnv(ctx: *types.PluginContext, args: []const []const u8) ![]const u8 {
    if (args.len < 1) return error.InvalidArguments;

    const name = args[0];
    return std.process.getEnvVarOwned(ctx.allocator, name) catch "";
}

/// Set response header: set_header(name, value)
fn hostSetHeader(ctx: *types.PluginContext, args: []const []const u8) ![]const u8 {
    if (args.len < 2) return error.InvalidArguments;

    const name = args[0];
    const value = args[1];

    // Store in context for later use
    const key = try std.fmt.allocPrint(ctx.allocator, "header_{s}", .{name});
    defer ctx.allocator.free(key);

    try ctx.data.put(key, value);

    return "";
}

/// Get request header: get_header(name)
fn hostGetHeader(ctx: *types.PluginContext, args: []const []const u8) ![]const u8 {
    if (args.len < 1) return error.InvalidArguments;

    const name = args[0];
    const key = try std.fmt.allocPrint(ctx.allocator, "req_header_{s}", .{name});
    defer ctx.allocator.free(key);

    return ctx.data.get(key) orelse "";
}

/// Get request body: get_body()
fn hostGetBody(ctx: *types.PluginContext, args: []const []const u8) ![]const u8 {
    _ = args; // Not used
    return ctx.data.get("request_body") orelse "";
}
