//! WASM Runtime Interface
//! Abstracts WASM execution for plugin system
//! Currently provides a mock implementation - replace with wasmtime-zig when available

const std = @import("std");
const types = @import("types.zig");

/// WASM Runtime errors
pub const RuntimeError = error{
    ModuleLoadFailed,
    InstantiationFailed,
    ExecutionTimeout,
    MemoryLimitExceeded,
    FunctionNotFound,
    InvalidArguments,
    RuntimeError,
};

/// WASM Value types (simplified)
pub const Value = union(enum) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    string: []const u8,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }
};

/// WASM Function signature
pub const Function = struct {
    name: []const u8,
    params: []const std.builtin.Type,
    result: ?std.builtin.Type,

    pub fn deinit(self: *Function, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.params);
    }
};

/// WASM Module represents a loaded WASM binary
pub const Module = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    functions: std.StringHashMap(Function),

    pub fn init(allocator: std.mem.Allocator, wasm_bytes: []const u8) !Module {
        // In real implementation, this would parse the WASM module
        // For now, we'll create a mock module
        var functions = std.StringHashMap(Function).init(allocator);

        // Mock plugin functions that should be exported by WASM modules
        const mock_functions = [_][]const u8{
            "init",
            "process_request",
            "process_response",
            "cleanup",
        };

        for (mock_functions) |func_name| {
            const func = Function{
                .name = try allocator.dupe(u8, func_name),
                .params = try allocator.dupe(std.builtin.Type, &[_]std.builtin.Type{}),
                .result = null,
            };
            try functions.put(try allocator.dupe(u8, func_name), func);
        }

        return Module{
            .allocator = allocator,
            .bytes = try allocator.dupe(u8, wasm_bytes),
            .functions = functions,
        };
    }

    pub fn deinit(self: *Module) void {
        self.allocator.free(self.bytes);

        var it = self.functions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.functions.deinit();
    }

    pub fn getFunction(self: *const Module, name: []const u8) ?*const Function {
        return self.functions.getPtr(name);
    }
};

/// WASM Instance represents a runnable WASM module
pub const Instance = struct {
    allocator: std.mem.Allocator,
    module: Module,
    memory: []u8,
    host_functions: *const types.HostFunctionRegistry,

    pub fn init(allocator: std.mem.Allocator, module: Module, host_functions: *const types.HostFunctionRegistry, memory_limit: usize) !Instance {
        const memory = try allocator.alloc(u8, memory_limit);
        @memset(memory, 0);

        return Instance{
            .allocator = allocator,
            .module = module,
            .memory = memory,
            .host_functions = host_functions,
        };
    }

    pub fn deinit(self: *Instance) void {
        self.allocator.free(self.memory);
        // Note: module is owned by caller
    }

    /// Call a WASM function
    pub fn call(self: *Instance, func_name: []const u8, ctx: *types.PluginContext, args: []const Value) !Value {
        // Mock WASM function execution
        // In real implementation, this would execute actual WASM code

        if (std.mem.eql(u8, func_name, "init")) {
            // Plugin initialization
            return Value{ .i32 = 0 }; // Success
        }

        if (std.mem.eql(u8, func_name, "process_request")) {
            // Mock request processing
            // This would call the actual WASM plugin function
            return self.mockProcessRequest(ctx, args);
        }

        if (std.mem.eql(u8, func_name, "process_response")) {
            // Mock response processing
            return self.mockProcessResponse(ctx, args);
        }

        if (std.mem.eql(u8, func_name, "cleanup")) {
            // Plugin cleanup
            return Value{ .i32 = 0 }; // Success
        }

        return RuntimeError.FunctionNotFound;
    }

    /// Mock request processing (replace with real WASM execution)
    fn mockProcessRequest(self: *Instance, ctx: *types.PluginContext, args: []const Value) !Value {
        _ = self; // Not used in mock
        _ = args; // Not used in mock

        // Mock plugin behavior: log the request
        std.debug.print("[WASM Plugin {s}] Processing request {d}\n", .{
            ctx.plugin_id,
            ctx.request_id,
        });

        // Simulate some plugin logic
        try ctx.data.put("processed", "true");

        return Value{ .i32 = 0 }; // Continue processing
    }

    /// Mock response processing (replace with real WASM execution)
    fn mockProcessResponse(self: *Instance, ctx: *types.PluginContext, args: []const Value) !Value {
        _ = self; // Not used in mock
        _ = args; // Not used in mock

        // Mock plugin behavior: add custom header
        std.debug.print("[WASM Plugin {s}] Processing response {d}\n", .{
            ctx.plugin_id,
            ctx.request_id,
        });

        return Value{ .i32 = 0 }; // Success
    }
};

/// WASM Runtime manages module loading and execution
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(Module),
    instances: std.StringHashMap(Instance),

    pub fn init(allocator: std.mem.Allocator) Runtime {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap(Module).init(allocator),
            .instances = std.StringHashMap(Instance).init(allocator),
        };
    }

    pub fn deinit(self: *Runtime) void {
        // Clean up instances
        var instance_it = self.instances.iterator();
        while (instance_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.instances.deinit();

        // Clean up modules
        var module_it = self.modules.iterator();
        while (module_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.modules.deinit();
    }

    /// Load a WASM module from bytes
    pub fn loadModule(self: *Runtime, id: []const u8, wasm_bytes: []const u8) !void {
        const module = try Module.init(self.allocator, wasm_bytes);
        const id_copy = try self.allocator.dupe(u8, id);
        try self.modules.put(id_copy, module);
    }

    /// Load a WASM module from file
    pub fn loadModuleFromFile(self: *Runtime, id: []const u8, file_path: []const u8) !void {
        const file = try std.fs.openFileAbsolute(file_path, .{});
        defer file.close();

        const wasm_bytes = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024); // 10MB limit
        defer self.allocator.free(wasm_bytes);

        try self.loadModule(id, wasm_bytes);
    }

    /// Create an instance of a loaded module
    pub fn createInstance(self: *Runtime, module_id: []const u8, instance_id: []const u8, host_functions: *const types.HostFunctionRegistry, memory_limit: usize) !void {
        const module = self.modules.get(module_id) orelse return RuntimeError.ModuleLoadFailed;
        const instance = try Instance.init(self.allocator, module.*, host_functions, memory_limit);

        const id_copy = try self.allocator.dupe(u8, instance_id);
        try self.instances.put(id_copy, instance);
    }

    /// Get an instance
    pub fn getInstance(self: *Runtime, instance_id: []const u8) ?*Instance {
        return self.instances.getPtr(instance_id);
    }

    /// Remove an instance
    pub fn removeInstance(self: *Runtime, instance_id: []const u8) bool {
        if (self.instances.fetchRemove(instance_id)) |kv| {
            self.allocator.free(kv.key);
            kv.value.deinit();
            return true;
        }
        return false;
    }

    /// Execute a function in a WASM instance
    pub fn execute(
        self: *Runtime,
        instance_id: []const u8,
        func_name: []const u8,
        ctx: *types.PluginContext,
        args: []const Value,
    ) !Value {
        const instance = self.getInstance(instance_id) orelse return RuntimeError.InstantiationFailed;
        return instance.call(func_name, ctx, args);
    }
};
