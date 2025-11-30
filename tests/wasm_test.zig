const std = @import("std");
const testing = std.testing;
const wasm_types = @import("../src/wasm/types.zig");
const wasm_manager = @import("../src/wasm/manager.zig");

test "WASM Plugin Manager initialization" {
    const allocator = testing.allocator;

    const config = wasm_manager.PluginManager.PluginManagerConfig{
        .memory_limit = 1024 * 1024,
        .timeout_ms = 5000,
    };

    var manager = try wasm_manager.PluginManager.init(allocator, config);
    defer manager.deinit();

    // Test that manager initializes correctly
    try testing.expect(manager.config.memory_limit == 1024 * 1024);
    try testing.expect(manager.config.timeout_ms == 5000);
}

test "Plugin Context creation and cleanup" {
    const allocator = testing.allocator;

    var ctx = wasm_types.PluginContext.init(allocator, "test-plugin", 12345);
    defer ctx.deinit();

    // Test context properties
    try testing.expectEqualStrings(ctx.plugin_id, "test-plugin");
    try testing.expect(ctx.request_id == 12345);

    // Test data storage
    try ctx.data.put("test_key", "test_value");
    const value = ctx.data.get("test_key");
    try testing.expect(value != null);
    try testing.expectEqualStrings(value.?, "test_value");
}

test "Host Function Registry" {
    const allocator = testing.allocator;

    var registry = wasm_types.HostFunctionRegistry.init(allocator);
    defer registry.deinit();

    // Register a test function
    try registry.register("test_func", testHostFunction);

    // Call the function
    var ctx = wasm_types.PluginContext.init(allocator, "test", 1);
    defer ctx.deinit();

    const args = [_][]const u8{"arg1", "arg2"};
    const result = try registry.call("test_func", &ctx, &args);
    defer allocator.free(result);

    try testing.expectEqualStrings(result, "test_result");
}

test "Plugin Registry operations" {
    const allocator = testing.allocator;

    var registry = wasm_types.PluginRegistry.init(allocator);
    defer registry.deinit();

    // Create a mock plugin instance
    const config = wasm_types.PluginConfig{
        .id = try allocator.dupe(u8, "test-plugin"),
        .name = try allocator.dupe(u8, "Test Plugin"),
        .version = try allocator.dupe(u8, "1.0.0"),
        .type = .request_preprocess,
        .wasm_path = try allocator.dupe(u8, "/dev/null"),
        .priority = 100,
        .enabled = true,
    };
    defer config.deinit(allocator);

    const instance = wasm_types.PluginInstance{
        .config = config,
        .instance = undefined,
        .last_used = std.time.timestamp(),
        .execute_fn = mockExecute,
        .cleanup_fn = mockCleanup,
    };

    // Register plugin
    try registry.register(instance);

    // Test retrieval
    const retrieved = registry.get("test-plugin");
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings(retrieved.?.config.id, "test-plugin");

    // Test type filtering
    const plugins = try registry.getByType(.request_preprocess, allocator);
    defer allocator.free(plugins);
    try testing.expect(plugins.len == 1);
    try testing.expectEqualStrings(plugins[0].config.id, "test-plugin");
}

test "Plugin execution result handling" {
    // Test success result
    const success_result = wasm_types.ExecutionResult.success();
    try testing.expect(success_result.status == .ok);
    try testing.expect(success_result.error_message == null);

    // Test stop result
    const stop_result = wasm_types.ExecutionResult.stopped();
    try testing.expect(stop_result.status == .stop);

    // Test error result
    const error_result = wasm_types.ExecutionResult.failed("Test error", 500);
    try testing.expect(error_result.status == .error);
    try testing.expectEqualStrings(error_result.error_message.?, "Test error");
    try testing.expect(error_result.http_status_code.? == 500);
}

// Mock functions for testing

fn testHostFunction(ctx: *wasm_types.PluginContext, args: []const []const u8) anyerror![]const u8 {
    _ = ctx; // Not used in test
    _ = args; // Not used in test
    return try testing.allocator.dupe(u8, "test_result");
}

fn mockExecute(
    instance_opaque: *anyopaque,
    ctx: *wasm_types.PluginContext,
    request: ?*anyopaque,
    response: ?*anyopaque,
) anyerror!wasm_types.ExecutionResult {
    _ = instance_opaque; // Not used in mock
    _ = ctx; // Not used in mock
    _ = request; // Not used in mock
    _ = response; // Not used in mock
    return wasm.types.ExecutionResult.success();
}

fn mockCleanup(instance_opaque: *anyopaque) void {
    _ = instance_opaque; // Not used in mock
}
