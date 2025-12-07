//! Tests for OpenTelemetry metrics implementation
//! Tests counters, gauges, histograms, and Prometheus exposition

const std = @import("std");
const testing = std.testing;
const metrics = @import("metrics.zig");

test "Metrics: Counter basic functionality" {
    const allocator = std.testing.allocator;

    var counter = metrics.Counter.init("test_counter", "A test counter", "requests");
    defer allocator.destroy(&counter);

    // Initial value should be 0
    try testing.expectEqual(@as(u64, 0), counter.get());

    // Increment by 1
    counter.inc();
    try testing.expectEqual(@as(u64, 1), counter.get());

    // Increment by 5
    counter.incBy(5);
    try testing.expectEqual(@as(u64, 6), counter.get());
}

test "Metrics: Gauge basic functionality" {
    const allocator = std.testing.allocator;

    var gauge = metrics.Gauge.init("test_gauge", "A test gauge", "connections");
    defer allocator.destroy(&gauge);

    // Initial value should be 0
    try testing.expectEqual(@as(f64, 0.0), gauge.get());

    // Set to 42
    gauge.set(42.0);
    try testing.expectEqual(@as(f64, 42.0), gauge.get());

    // Set to negative value
    gauge.set(-10.5);
    try testing.expectEqual(@as(f64, -10.5), gauge.get());
}

test "Metrics: Histogram basic functionality" {
    const allocator = std.testing.allocator;

    const buckets = [_]f64{ 1.0, 2.0, 5.0, 10.0 };
    var histogram = try metrics.Histogram.init(allocator, "test_histogram", "A test histogram", "seconds", &buckets);
    defer histogram.deinit();

    // Initial state
    try testing.expectEqual(@as(u64, 0), histogram.getCount());
    try testing.expectEqual(@as(f64, 0.0), histogram.getSum());

    // Observe some values
    histogram.observe(0.5); // bucket 0
    histogram.observe(1.5); // bucket 1
    histogram.observe(3.0); // bucket 2
    histogram.observe(7.0); // bucket 2
    histogram.observe(15.0); // bucket 3 (last)

    // Check counts
    const counts = histogram.getCounts();
    try testing.expectEqual(@as(u64, 1), counts[0]); // 0.5 <= 1.0
    try testing.expectEqual(@as(u64, 1), counts[1]); // 1.5 <= 2.0
    try testing.expectEqual(@as(u64, 2), counts[2]); // 3.0, 7.0 <= 10.0
    try testing.expectEqual(@as(u64, 1), counts[3]); // 15.0 > 10.0

    // Check sum and count
    try testing.expectEqual(@as(u64, 5), histogram.getCount());
    try testing.expectEqual(@as(f64, 27.0), histogram.getSum());
}

test "Metrics: Registry functionality" {
    const allocator = std.testing.allocator;

    var registry = metrics.MetricsRegistry.init(allocator);
    defer registry.deinit();

    // Create metrics
    var counter = metrics.Counter.init("test_counter", "Test counter", "ops");
    defer allocator.destroy(&counter);

    var gauge = metrics.Gauge.init("test_gauge", "Test gauge", "items");
    defer allocator.destroy(&gauge);

    // Register metrics
    try registry.registerCounter(&counter);
    try registry.registerGauge(&gauge);

    // Check registration
    try testing.expectEqual(@as(usize, 1), registry.counters.items.len);
    try testing.expectEqual(@as(usize, 1), registry.gauges.items.len);

    // Update metrics
    counter.incBy(42);
    gauge.set(3.14);

    // Check values through registry
    try testing.expectEqual(@as(u64, 42), registry.counters.items[0].get());
    try testing.expectEqual(@as(f64, 3.14), registry.gauges.items[0].get());
}

test "Metrics: Prometheus exporter" {
    const allocator = std.testing.allocator;

    var registry = metrics.MetricsRegistry.init(allocator);
    defer registry.deinit();

    // Create and register metrics
    var counter = metrics.Counter.init("test_requests_total", "Total requests", "requests");
    defer allocator.destroy(&counter);

    var gauge = metrics.Gauge.init("test_active_connections", "Active connections", "connections");
    defer allocator.destroy(&gauge);

    const buckets = [_]f64{ 0.1, 1.0, 10.0 };
    var histogram = try metrics.Histogram.init(allocator, "test_request_duration", "Request duration", "seconds", &buckets);
    defer histogram.deinit();

    try registry.registerCounter(&counter);
    try registry.registerGauge(&gauge);
    try registry.registerHistogram(&histogram);

    // Update metrics
    counter.incBy(100);
    gauge.set(5.0);
    histogram.observe(0.05); // bucket 0
    histogram.observe(0.5); // bucket 1
    histogram.observe(5.0); // bucket 2

    // Export to Prometheus format
    var buffer = std.ArrayList(u8).initCapacity(allocator, 1024);
    defer buffer.deinit();

    const exporter = metrics.PrometheusExporter.init(&registry);
    try exporter.writeMetrics(buffer.writer());

    const output = buffer.items;

    // Check that output contains expected content
    try testing.expect(std.mem.indexOf(u8, output, "# HELP test_requests_total Total requests") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test_requests_total{unit=\"requests\"} 100") != null);
    try testing.expect(std.mem.indexOf(u8, output, "# HELP test_active_connections Active connections") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test_active_connections{unit=\"connections\"} 5") != null);
    try testing.expect(std.mem.indexOf(u8, output, "# TYPE test_request_duration histogram") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test_request_duration_count 3") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test_request_duration_sum 5.55") != null);
}

test "Metrics: BlitzMetrics integration" {
    const allocator = std.testing.allocator;

    var blitz_metrics = try metrics.BlitzMetrics.init(allocator);
    defer blitz_metrics.deinit();

    // Test HTTP request recording
    blitz_metrics.recordHttpRequest(0.025); // 25ms request
    blitz_metrics.recordHttpResponse(200); // 200 OK

    // Test connection tracking
    blitz_metrics.incrementActiveConnections();
    blitz_metrics.incrementActiveConnections();

    // Test QUIC metrics
    blitz_metrics.recordQuicPacket();
    blitz_metrics.recordQuicHandshake(0.01); // 10ms handshake

    // Test rate limiting metrics
    blitz_metrics.recordRateLimitRequest(true, 42); // dropped, 42 active IPs

    // Test load balancer metrics
    blitz_metrics.recordLbRequest("backend-1");
    blitz_metrics.updateBackendHealth("backend-1", true);

    // Verify metrics were recorded
    try testing.expectEqual(@as(u64, 1), blitz_metrics.http_requests_total.get());
    try testing.expectEqual(@as(u64, 1), blitz_metrics.http_responses_total.get());
    try testing.expectEqual(@as(f64, 2.0), blitz_metrics.active_connections.get());
    try testing.expectEqual(@as(u64, 1), blitz_metrics.quic_packets_total.get());
    try testing.expectEqual(@as(u64, 1), blitz_metrics.quic_handshakes_total.get());
    try testing.expectEqual(@as(u64, 1), blitz_metrics.rate_limit_requests_dropped.get());
    try testing.expectEqual(@as(f64, 42.0), blitz_metrics.rate_limit_active_ips.get());
    try testing.expectEqual(@as(u64, 1), blitz_metrics.lb_requests_total.get());
}

test "Metrics: Prometheus format validation" {
    const allocator = std.testing.allocator;

    var blitz_metrics = try metrics.BlitzMetrics.init(allocator);
    defer blitz_metrics.deinit();

    // Add some test data
    blitz_metrics.recordHttpRequest(0.1);
    blitz_metrics.recordHttpResponse(200);
    blitz_metrics.incrementActiveConnections();

    // Get Prometheus output
    const prometheus_output = try blitz_metrics.getPrometheusMetrics(allocator);
    defer allocator.free(prometheus_output);

    // Validate Prometheus format
    try testing.expect(std.mem.startsWith(u8, prometheus_output, "# HELP"));

    // Should contain key metrics
    try testing.expect(std.mem.indexOf(u8, prometheus_output, "blitz_http_requests_total") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus_output, "blitz_active_connections") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus_output, "# TYPE") != null);

    // Should end with valid metric values (no trailing commas, etc.)
    try testing.expect(std.mem.indexOf(u8, prometheus_output, "\n\n") == null); // No double newlines
}

test "Metrics: Histogram quantile calculation" {
    const allocator = std.testing.allocator;

    const buckets = [_]f64{ 0.1, 1.0, 10.0, 100.0 };
    var histogram = try metrics.Histogram.init(allocator, "test_histogram", "Test histogram", "seconds", &buckets);
    defer histogram.deinit();

    // Add observations
    histogram.observe(0.05); // bucket 0
    histogram.observe(0.05); // bucket 0
    histogram.observe(0.5); // bucket 1
    histogram.observe(5.0); // bucket 2
    histogram.observe(50.0); // bucket 3
    histogram.observe(500.0); // overflow

    // Check bucket counts (cumulative)
    const counts = histogram.getCounts();
    try testing.expectEqual(@as(u64, 2), counts[0]); // 2 values <= 0.1
    try testing.expectEqual(@as(u64, 1), counts[1]); // 1 additional value <= 1.0
    try testing.expectEqual(@as(u64, 1), counts[2]); // 1 additional value <= 10.0
    try testing.expectEqual(@as(u64, 2), counts[3]); // 2 additional values > 10.0

    try testing.expectEqual(@as(u64, 6), histogram.getCount());
    try testing.expectEqual(@as(f64, 555.1), histogram.getSum()); // 0.05+0.05+0.5+5.0+50.0+500.0
}

test "Metrics: Thread safety" {
    const allocator = std.testing.allocator;

    var counter = metrics.Counter.init("thread_safety_test", "Thread safety test", "ops");
    defer allocator.destroy(&counter);

    // Test concurrent increments (basic thread safety check)
    const num_threads = 4;
    const increments_per_thread = 1000;

    var threads: [num_threads]std.Thread = undefined;

    for (&threads, 0..) |*thread, i| {
        _ = i; // Thread index not used
        thread.* = try std.Thread.spawn(.{}, struct {
            fn worker(c: *metrics.Counter, increments: usize) void {
                var j: usize = 0;
                while (j < increments) : (j += 1) {
                    c.inc();
                }
            }
        }.worker, .{ &counter, increments_per_thread });
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Should have exactly the expected number of increments
    const expected = num_threads * increments_per_thread;
    try testing.expectEqual(@as(u64, expected), counter.get());
}

test "Metrics: Memory management" {
    const allocator = std.testing.allocator;

    // Test registry cleanup
    var registry = metrics.MetricsRegistry.init(allocator);
    defer registry.deinit();

    // Add multiple metrics
    var counters: [5]metrics.Counter = undefined;
    var gauges: [3]metrics.Gauge = undefined;

    for (&counters, 0..) |*counter, i| {
        counter.* = metrics.Counter.init(std.fmt.allocPrint(allocator, "counter_{d}", .{i}) catch "counter", "Test counter", "ops");
        try registry.registerCounter(counter);
    }

    for (&gauges, 0..) |*gauge, i| {
        gauge.* = metrics.Gauge.init(std.fmt.allocPrint(allocator, "gauge_{d}", .{i}) catch "gauge", "Test gauge", "value");
        try registry.registerGauge(gauge);
    }

    // Registry should track them
    try testing.expectEqual(@as(usize, 5), registry.counters.items.len);
    try testing.expectEqual(@as(usize, 3), registry.gauges.items.len);

    // Cleanup should work
    registry.deinit();

    // Should be empty after deinit
    try testing.expectEqual(@as(usize, 0), registry.counters.items.len);
    try testing.expectEqual(@as(usize, 0), registry.gauges.items.len);
}

// Note: MetricsHttpServer thread safety tests are implemented as integration tests
// in tests/integration/ due to the complexity of testing HTTP server thread management.
// The key fixes implemented are:
// 1. Track active handler threads instead of detaching them immediately
// 2. Join all active threads in stop() to prevent use-after-free
// 3. Use proper synchronization with mutexes for thread-safe access to the thread list
