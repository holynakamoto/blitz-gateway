//! Tests for graceful reload functionality
//! Tests signal handling and configuration reloading

const std = @import("std");
const testing = std.testing;
const config = @import("../src/config.zig");
const graceful_reload = @import("../src/graceful_reload.zig");

test "Graceful Reload: Initialize and deinitialize" {
    const allocator = std.testing.allocator;

    // Create test configuration
    var test_config = try config.Config.init(allocator);
    defer test_config.deinit();

    test_config.mode = .origin;

    // Initialize graceful reload
    var gr = try graceful_reload.GracefulReload.init(allocator, test_config);
    defer gr.deinit();

    // Should initialize successfully
    try testing.expect(gr.reload_callback == null);
    try testing.expect(!gr.reloading);

    // Test getting current config
    const current = gr.getCurrentConfig();
    try testing.expectEqual(config.Config.Mode.origin, current.mode);
}

test "Graceful Reload: Configuration reload" {
    const allocator = std.testing.allocator;

    // Create initial configuration
    var initial_config = try config.Config.init(allocator);
    defer initial_config.deinit();
    initial_config.mode = .origin;

    var gr = try graceful_reload.GracefulReload.init(allocator, initial_config);
    defer gr.deinit();

    // Create a temporary config file
    const temp_config_content =
        \\mode = "load_balancer"
        \\listen = "127.0.0.1:8443"
        \\
        \\[backends.test]
        \\host = "127.0.0.1"
        \\port = 8080
    ;

    // Write to temporary file
    const temp_path = "test_config.toml";
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    try std.fs.cwd().writeFile(.{
        .sub_path = temp_path,
        .data = temp_config_content,
    });

    // Perform reload
    try gr.performReload(temp_path);

    // Check that configuration was updated
    const current = gr.getCurrentConfig();
    try testing.expectEqual(config.Config.Mode.load_balancer, current.mode);
    try testing.expectEqualStrings("127.0.0.1", current.listen_addr);
    try testing.expectEqual(@as(u16, 8443), current.listen_port);
    try testing.expectEqual(@as(usize, 1), current.backends.items.len);
}

test "Graceful Reload: Reload callback" {
    const allocator = std.testing.allocator;

    var initial_config = config.Config.init(allocator);
    defer initial_config.deinit();

    var gr = try graceful_reload.GracefulReload.init(allocator, initial_config);
    defer gr.deinit();

    // Set callback
    var callback_called = false;
    const test_callback = struct {
        fn callback(cfg: *config.Config) anyerror!void {
            _ = cfg;
            callback_called = true;
        }
    }.callback;

    gr.setReloadCallback(test_callback);

    // Create temp config
    const temp_path = "test_callback.toml";
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    try std.fs.cwd().writeFile(.{
        .sub_path = temp_path,
        .data = "mode = \"origin\"",
    });

    // Perform reload
    try gr.performReload(temp_path);

    // Check callback was called
    try testing.expect(callback_called);
}

test "Graceful Reload: Concurrent reload prevention" {
    const allocator = std.testing.allocator;

    var initial_config = config.Config.init(allocator);
    defer initial_config.deinit();

    var gr = try graceful_reload.GracefulReload.init(allocator, initial_config);
    defer gr.deinit();

    // Set reloading flag manually
    gr.reloading = true;

    // Attempt reload while already reloading
    const temp_path = "test_concurrent.toml";
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    try std.fs.cwd().writeFile(.{
        .sub_path = temp_path,
        .data = "mode = \"origin\"",
    });

    // This should not error, just log a warning and return
    try gr.performReload(temp_path);
    try testing.expect(gr.reloading); // Should still be true
}

test "Graceful Reload: Configuration validation on reload" {
    const allocator = std.testing.allocator;

    var initial_config = config.Config.init(allocator);
    defer initial_config.deinit();

    var gr = try graceful_reload.GracefulReload.init(allocator, initial_config);
    defer gr.deinit();

    // Create invalid config (load balancer with no backends)
    const temp_path = "test_invalid.toml";
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    try std.fs.cwd().writeFile(.{
        .sub_path = temp_path,
        .data = "mode = \"load_balancer\"",
    });

    // Reload should fail due to validation
    const reload_error = gr.performReload(temp_path);
    try testing.expectError(error.NoBackendsConfigured, reload_error);
}

// Integration test with rate limiting config
test "Graceful Reload Integration: Rate limiting config" {
    const allocator = std.testing.allocator;

    var initial_config = config.Config.init(allocator);
    defer initial_config.deinit();

    var gr = try graceful_reload.GracefulReload.init(allocator, initial_config);
    defer gr.deinit();

    // Create config with rate limiting
    const temp_path = "test_rate_limit.toml";
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    const config_content =
        \\mode = "load_balancer"
        \\listen = "0.0.0.0:4433"
        \\rate_limit = "1000 req/s"
        \\rate_limit_per_ip = "100 req/s"
        \\rate_limit_burst_multiplier = 2.0
        \\
        \\[backends.test]
        \\host = "127.0.0.1"
        \\port = 8080
    ;

    try std.fs.cwd().writeFile(.{
        .sub_path = temp_path,
        .data = config_content,
    });

    // Perform reload
    try gr.performReload(temp_path);

    // Check rate limiting config
    const current = gr.getCurrentConfig();
    try testing.expectEqual(@as(?u32, 1000), current.rate_limit.global_rps);
    try testing.expectEqual(@as(?u32, 100), current.rate_limit.per_ip_rps);
    try testing.expectEqual(@as(f32, 2.0), current.rate_limit.burst_multiplier);
}

// Performance test
test "Graceful Reload Performance: Config reload speed" {
    const allocator = std.testing.allocator;

    var initial_config = config.Config.init(allocator);
    defer initial_config.deinit();

    var gr = try graceful_reload.GracefulReload.init(allocator, initial_config);
    defer gr.deinit();

    // Create a config file
    const temp_path = "test_perf.toml";
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    const config_content =
        \\mode = "load_balancer"
        \\listen = "0.0.0.0:4433"
        \\
        \\[backends.web1]
        \\host = "10.0.0.1"
        \\port = 8080
        \\weight = 5
        \\
        \\[backends.web2]
        \\host = "10.0.0.2"
        \\port = 8080
        \\weight = 3
        \\
        \\[backends.web3]
        \\host = "10.0.0.3"
        \\port = 8080
        \\weight = 2
    ;

    try std.fs.cwd().writeFile(.{
        .sub_path = temp_path,
        .data = config_content,
    });

    // Measure reload time
    const start_time = std.time.milliTimestamp();

    // Perform multiple reloads
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try gr.performReload(temp_path);
    }

    const end_time = std.time.milliTimestamp();
    const total_time = end_time - start_time;
    const avg_time = @as(f64, @floatFromInt(total_time)) / 10.0;

    std.debug.print("Graceful reload performance: 10 reloads in {} ms (avg: {d:.2} ms/reload)\n", .{ total_time, avg_time });

    // Should complete quickly (< 5ms per reload on average)
    try testing.expect(avg_time < 5.0);
}
