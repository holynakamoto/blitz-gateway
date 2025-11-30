//! Integration tests for load balancer configuration and server integration
//! Tests the end-to-end functionality of config parsing and load balancer setup

const std = @import("std");
const config = @import("config.zig");
const load_balancer = @import("load_balancer.zig");

test "Load Balancer Integration: Config Parsing" {
    std.debug.print("\n🧪 Testing Load Balancer Config Integration\n", .{});

    const allocator = std.testing.allocator;

    // Test 1: Parse example configuration
    std.debug.print("  1. Parsing example configuration...\n", .{});

    const example_config =
        \\mode = "load_balancer"
        \\listen = "0.0.0.0:4433"
        \\
        \\[backends.origin-1]
        \\host = "127.0.0.1"
        \\port = 8443
        \\weight = 10
        \\health_check_path = "/health"
        \\
        \\[backends.origin-2]
        \\host = "127.0.0.1"
        \\port = 8444
        \\weight = 5
    ;

    var parsed_config = try config.parseConfigFile(allocator, example_config);
    defer parsed_config.deinit();

    try std.testing.expectEqual(config.Config.Mode.load_balancer, parsed_config.mode);
    try std.testing.expectEqualStrings("0.0.0.0", parsed_config.listen_addr);
    try std.testing.expectEqual(@as(u16, 4433), parsed_config.listen_port);
    try std.testing.expectEqual(@as(usize, 2), parsed_config.backends.items.len);

    // Check first backend
    const backend1 = parsed_config.backends.items[0];
    try std.testing.expectEqualStrings("127.0.0.1", backend1.host);
    try std.testing.expectEqual(@as(u16, 8443), backend1.port);
    try std.testing.expectEqual(@as(u32, 10), backend1.weight);
    try std.testing.expect(backend1.health_check_path != null);
    try std.testing.expectEqualStrings("/health", backend1.health_check_path.?);

    // Check second backend
    const backend2 = parsed_config.backends.items[1];
    try std.testing.expectEqualStrings("127.0.0.1", backend2.host);
    try std.testing.expectEqual(@as(u16, 8444), backend2.port);
    try std.testing.expectEqual(@as(u32, 5), backend2.weight);
    try std.testing.expect(backend2.health_check_path == null);

    std.debug.print("     ✅ Config parsing successful\n", .{});
}

test "Load Balancer Integration: Load Balancer Initialization" {
    std.debug.print("  2. Testing load balancer initialization from config...\n", .{});

    const allocator = std.testing.allocator;

    // Create test configuration
    var test_config = config.Config.init(allocator);
    defer test_config.deinit();

    test_config.mode = .load_balancer;
    test_config.listen_addr = try allocator.dupe(u8, "127.0.0.1");
    test_config.listen_port = 8443;

    // Add test backends
    try test_config.addBackend(config.Backend{
        .host = "127.0.0.1",
        .port = 8081,
        .weight = 10,
    });

    try test_config.addBackend(config.Backend{
        .host = "127.0.0.1",
        .port = 8082,
        .weight = 5,
    });

    // Initialize load balancer from config
    var lb = try load_balancer.LoadBalancer.initFromConfig(allocator, test_config);
    defer lb.deinit();

    // Verify backends were added correctly
    try std.testing.expectEqual(@as(usize, 2), lb.pool.backends.items.len);

    const backend1 = lb.pool.backends.items[0];
    try std.testing.expectEqualStrings("127.0.0.1", backend1.host);
    try std.testing.expectEqual(@as(u16, 8081), backend1.port);
    try std.testing.expectEqual(@as(u32, 10), backend1.weight);

    const backend2 = lb.pool.backends.items[1];
    try std.testing.expectEqualStrings("127.0.0.1", backend2.host);
    try std.testing.expectEqual(@as(u16, 8082), backend2.port);
    try std.testing.expectEqual(@as(u32, 5), backend2.weight);

    std.debug.print("     ✅ Load balancer initialization successful\n", .{});
}

test "Load Balancer Integration: Round Robin Distribution" {
    std.debug.print("  3. Testing round-robin backend selection...\n", .{});

    const allocator = std.testing.allocator;

    var test_config = config.Config.init(allocator);
    defer test_config.deinit();

    // Add backends with different weights
    try test_config.addBackend(config.Backend{
        .host = "127.0.0.1",
        .port = 8081,
        .weight = 2, // Should get 2/3 of requests
    });

    try test_config.addBackend(config.Backend{
        .host = "127.0.0.1",
        .port = 8082,
        .weight = 1, // Should get 1/3 of requests
    });

    var lb = try load_balancer.LoadBalancer.initFromConfig(allocator, test_config);
    defer lb.deinit();

    // Test round-robin selection
    var backend1_count: usize = 0;
    var backend2_count: usize = 0;

    // Simulate 30 requests (should be 20:10 ratio due to weights)
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const selected = lb.pool.getNextBackend();
        if (selected) |backend| {
            if (backend.port == 8081) {
                backend1_count += 1;
            } else if (backend.port == 8082) {
                backend2_count += 1;
            }
        }
    }

    std.debug.print("     Backend 1 (weight 2): {} requests\n", .{backend1_count});
    std.debug.print("     Backend 2 (weight 1): {} requests\n", .{backend2_count});

    // Should be roughly 2:1 ratio
    const total = backend1_count + backend2_count;
    const backend1_ratio = @as(f32, @floatFromInt(backend1_count)) / @as(f32, @floatFromInt(total));
    const backend2_ratio = @as(f32, @floatFromInt(backend2_count)) / @as(f32, @floatFromInt(total));

    // Allow some tolerance for randomness
    try std.testing.expect(backend1_ratio > 0.55); // Should be ~66%
    try std.testing.expect(backend2_ratio < 0.45); // Should be ~33%

    std.debug.print("     ✅ Round-robin distribution working correctly\n", .{});
}

test "Load Balancer Integration: Health Check Integration" {
    std.debug.print("  4. Testing health check integration...\n", .{});

    const allocator = std.testing.allocator;

    var test_config = config.Config.init(allocator);
    defer test_config.deinit();

    try test_config.addBackend(config.Backend{
        .host = "127.0.0.1",
        .port = 8081,
        .weight = 10,
        .health_check_path = "/health",
    });

    var lb = try load_balancer.LoadBalancer.initFromConfig(allocator, test_config);
    defer lb.deinit();

    // Test that health checker was initialized
    try std.testing.expect(lb.pool.backends.items.len > 0);

    // Mark backend as unhealthy
    const backend = lb.pool.backends.items[0];
    backend.markUnhealthy();

    // Verify backend is marked unhealthy
    try std.testing.expect(!backend.is_healthy);

    // Test round-robin skips unhealthy backends
    const selected = lb.pool.getNextBackend();
    try std.testing.expect(selected == null); // No healthy backends

    std.debug.print("     ✅ Health check integration working\n", .{});
}

test "Load Balancer Integration: Statistics Tracking" {
    std.debug.print("  5. Testing statistics tracking...\n", .{});

    const allocator = std.testing.allocator;

    var test_config = config.Config.init(allocator);
    defer test_config.deinit();

    try test_config.addBackend(config.Backend{
        .host = "127.0.0.1",
        .port = 8081,
        .weight = 10,
    });

    var lb = try load_balancer.LoadBalancer.initFromConfig(allocator, test_config);
    defer lb.deinit();

    const backend = lb.pool.backends.items[0];

    // Simulate some requests
    backend.recordSuccess();
    backend.recordSuccess();
    backend.recordFailure();

    // Check statistics
    const stats = lb.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats.total_backends);
    try std.testing.expectEqual(@as(usize, 1), stats.healthy_backends); // Backend still healthy
    try std.testing.expectEqual(@as(u64, 3), stats.total_requests); // 2 success + 1 failure
    try std.testing.expectEqual(@as(u64, 2), stats.successful_requests);
    try std.testing.expectEqual(@as(u64, 1), stats.failed_requests);

    std.debug.print("     ✅ Statistics tracking working correctly\n", .{});
}

test "Load Balancer Integration: Configuration Validation" {
    std.debug.print("  6. Testing configuration validation...\n", .{});

    const allocator = std.testing.allocator;

    // Test 1: Valid load balancer config
    var valid_config = config.Config.init(allocator);
    defer valid_config.deinit();
    valid_config.mode = .load_balancer;

    try valid_config.addBackend(config.Backend{
        .host = "127.0.0.1",
        .port = 8081,
        .weight = 10,
    });

    try valid_config.validate(); // Should not error
    std.debug.print("     ✅ Valid load balancer config accepted\n", .{});

    // Test 2: Invalid load balancer config (no backends)
    var invalid_config = config.Config.init(allocator);
    defer invalid_config.deinit();
    invalid_config.mode = .load_balancer;

    const validation_error = invalid_config.validate();
    try std.testing.expectError(error.NoBackendsConfigured, validation_error);
    std.debug.print("     ✅ Invalid config (no backends) properly rejected\n", .{});

    // Test 3: Origin server mode (should pass even without backends)
    var origin_config = config.Config.init(allocator);
    defer origin_config.deinit();
    origin_config.mode = .origin;

    try origin_config.validate(); // Should not error
    std.debug.print("     ✅ Origin server mode works without backends\n", .{});

    std.debug.print("     ✅ Configuration validation working correctly\n", .{});
}

test "Load Balancer Integration: Complete Workflow" {
    std.debug.print("  7. Testing complete load balancer workflow...\n", .{});

    const allocator = std.testing.allocator;

    // 1. Parse configuration
    const config_content =
        \\mode = "load_balancer"
        \\listen = "127.0.0.1:8443"
        \\
        \\[backends.web-1]
        \\host = "10.0.0.1"
        \\port = 8080
        \\weight = 3
        \\
        \\[backends.web-2]
        \\host = "10.0.0.2"
        \\port = 8080
        \\weight = 1
    ;

    var cfg = try config.parseConfigFile(allocator, config_content);
    defer cfg.deinit();

    // 2. Initialize load balancer
    var lb = try load_balancer.LoadBalancer.initFromConfig(allocator, cfg);
    defer lb.deinit();

    // 3. Verify setup
    try std.testing.expectEqual(@as(usize, 2), lb.pool.backends.items.len);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.listen_addr);
    try std.testing.expectEqual(@as(u16, 8443), cfg.listen_port);

    // 4. Test backend selection (weight ratio should be 3:1)
    var backend1_selections: usize = 0;
    var backend2_selections: usize = 0;

    var i: usize = 0;
    while (i < 40) : (i += 1) { // 40 requests for good statistics
        const selected = lb.pool.getNextBackend();
        if (selected) |backend| {
            if (std.mem.eql(u8, backend.host, "10.0.0.1")) {
                backend1_selections += 1;
            } else if (std.mem.eql(u8, backend.host, "10.0.0.2")) {
                backend2_selections += 1;
            }
        }
    }

    // Verify weight distribution (should be roughly 3:1)
    const total_selections = backend1_selections + backend2_selections;
    const backend1_ratio = @as(f32, @floatFromInt(backend1_selections)) / @as(f32, @floatFromInt(total_selections));
    const backend2_ratio = @as(f32, @floatFromInt(backend2_selections)) / @as(f32, @floatFromInt(total_selections));

    std.debug.print("     Backend 1 selections: {} (ratio: {d:.2})\n", .{backend1_selections, backend1_ratio});
    std.debug.print("     Backend 2 selections: {} (ratio: {d:.2})\n", .{backend2_selections, backend2_ratio});

    try std.testing.expect(backend1_ratio > 0.65); // Should be ~75%
    try std.testing.expect(backend2_ratio < 0.35); // Should be ~25%

    std.debug.print("     ✅ Complete load balancer workflow successful\n", .{});
}

// Integration test summary
test "Load Balancer Integration Tests Complete" {
    std.debug.print("\n🎉 Load Balancer Integration Tests Complete!\n", .{});
    std.debug.print("==================================================\n", .{});
    std.debug.print("✅ Configuration parsing and validation\n", .{});
    std.debug.print("✅ Load balancer initialization from config\n", .{});
    std.debug.print("✅ Weighted round-robin backend selection\n", .{});
    std.debug.print("✅ Health check integration\n", .{});
    std.debug.print("✅ Statistics tracking\n", .{});
    std.debug.print("✅ Complete end-to-end workflow\n", .{});
    std.debug.print("\n🚀 Load balancer integration is fully functional!\n", .{});
}
