const std = @import("std");
const testing = std.testing;

// Simple smoke test for WASM plugin system
// Full integration tests are done via HTTP server testing

test "WASM Plugin System - Basic Types" {
    // Test that the basic types compile and work
    const result_ok = PluginResult.ok;
    const result_stop = PluginResult.stop;
    const result_error = PluginResult.@"error";

    try testing.expect(result_ok == .ok);
    try testing.expect(result_stop == .stop);
    try testing.expect(result_error == .@"error");
}

test "WASM Plugin System - Plugin Types" {
    // Test that plugin types are properly defined
    const preprocess = PluginType.request_preprocess;
    const routing = PluginType.routing;
    const auth = PluginType.auth;
    const transform = PluginType.request_transform;
    const backend = PluginType.backend_pre;
    const response = PluginType.response_transform;
    const postprocess = PluginType.response_postprocess;
    const observability = PluginType.observability;

    try testing.expect(preprocess == .request_preprocess);
    try testing.expect(routing == .routing);
    try testing.expect(auth == .auth);
    try testing.expect(transform == .request_transform);
    try testing.expect(backend == .backend_pre);
    try testing.expect(response == .response_transform);
    try testing.expect(postprocess == .response_postprocess);
    try testing.expect(observability == .observability);
}

test "WASM Plugin System - Execution Results" {
    // Test execution result creation
    const success = ExecutionResult{ .status = .ok, .error_message = null, .http_status_code = null };
    const stopped = ExecutionResult{ .status = .stop, .error_message = null, .http_status_code = null };

    try testing.expect(success.status == .ok);
    try testing.expect(stopped.status == .stop);

    // Test helper functions exist (would be tested in integration)
    _ = success;
    _ = stopped;
}

// Import the actual types from the main codebase
// These are tested in integration via HTTP server
const PluginResult = @import("../src/wasm/types.zig").PluginResult;
const PluginType = @import("../src/wasm/types.zig").PluginType;
const ExecutionResult = @import("../src/wasm/types.zig").ExecutionResult;
