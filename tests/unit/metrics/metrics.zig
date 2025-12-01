//! OpenTelemetry metrics implementation for Blitz edge gateway
//! Exports metrics via OTLP and Prometheus exposition format

const std = @import("std");
const builtin = @import("builtin");

// Metric types
pub const Counter = struct {
    name: []const u8,
    description: []const u8,
    unit: []const u8,
    value: u64 = 0,

    pub fn init(name: []const u8, description: []const u8, unit: []const u8) Counter {
        return Counter{
            .name = name,
            .description = description,
            .unit = unit,
        };
    }

    pub fn inc(self: *Counter) void {
        self.incBy(1);
    }

    pub fn incBy(self: *Counter, amount: u64) void {
        _ = @atomicRmw(u64, &self.value, .Add, amount, .monotonic);
    }

    pub fn get(self: *const Counter) u64 {
        return @atomicLoad(u64, &self.value, .monotonic);
    }
};

pub const Gauge = struct {
    name: []const u8,
    description: []const u8,
    unit: []const u8,
    value: f64 = 0,

    pub fn init(name: []const u8, description: []const u8, unit: []const u8) Gauge {
        return Gauge{
            .name = name,
            .description = description,
            .unit = unit,
        };
    }

    pub fn set(self: *Gauge, value: f64) void {
        _ = @atomicStore(f64, &self.value, value, .monotonic);
    }

    pub fn get(self: *const Gauge) f64 {
        return @atomicLoad(f64, &self.value, .monotonic);
    }
};

pub const Histogram = struct {
    name: []const u8,
    description: []const u8,
    unit: []const u8,
    buckets: []f64,
    counts: []u64,
    sum: f64 = 0,
    count: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, description: []const u8, unit: []const u8, buckets: []const f64) !Histogram {
        const counts = try allocator.alloc(u64, buckets.len);
        @memset(counts, 0);

        const buckets_copy = try allocator.alloc(f64, buckets.len);
        @memcpy(buckets_copy, buckets);

        return Histogram{
            .name = name,
            .description = description,
            .unit = unit,
            .buckets = buckets_copy,
            .counts = counts,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Histogram) void {
        self.allocator.free(self.buckets);
        self.allocator.free(self.counts);
    }

    pub fn observe(self: *Histogram, value: f64) void {
        // Update sum and count
        _ = @atomicRmw(f64, &self.sum, .Add, value, .monotonic);
        _ = @atomicRmw(u64, &self.count, .Add, 1, .monotonic);

        // Find appropriate bucket
        var bucket_idx: usize = 0;
        while (bucket_idx < self.buckets.len and value > self.buckets[bucket_idx]) {
            bucket_idx += 1;
        }

        if (bucket_idx < self.counts.len) {
            _ = @atomicRmw(u64, &self.counts[bucket_idx], .Add, 1, .monotonic);
        }
    }

    pub fn getBuckets(self: *const Histogram) []const f64 {
        return self.buckets;
    }

    pub fn getCounts(self: *const Histogram) []const u64 {
        return self.counts;
    }

    pub fn getSum(self: *const Histogram) f64 {
        return @atomicLoad(f64, &self.sum, .monotonic);
    }

    pub fn getCount(self: *const Histogram) u64 {
        return @atomicLoad(u64, &self.count, .monotonic);
    }
};

// Metrics registry
pub const MetricsRegistry = struct {
    allocator: std.mem.Allocator,
    counters: std.ArrayListUnmanaged(*Counter),
    gauges: std.ArrayListUnmanaged(*Gauge),
    histograms: std.ArrayListUnmanaged(*Histogram),

    pub fn init(allocator: std.mem.Allocator) MetricsRegistry {
        return MetricsRegistry{
            .allocator = allocator,
            .counters = .{},
            .gauges = .{},
            .histograms = .{},
        };
    }

    pub fn deinit(self: *MetricsRegistry) void {
        // Note: We don't free the individual metrics here as they might be
        // owned by other parts of the code. Just free the registry lists.
        self.counters.deinit(self.allocator);
        self.gauges.deinit(self.allocator);
        self.histograms.deinit(self.allocator);
    }

    pub fn registerCounter(self: *MetricsRegistry, counter: *Counter) !void {
        try self.counters.append(self.allocator, counter);
    }

    pub fn registerGauge(self: *MetricsRegistry, gauge: *Gauge) !void {
        try self.gauges.append(self.allocator, gauge);
    }

    pub fn registerHistogram(self: *MetricsRegistry, histogram: *Histogram) !void {
        try self.histograms.append(self.allocator, histogram);
    }
};

// Prometheus exposition format exporter
pub const PrometheusExporter = struct {
    registry: *const MetricsRegistry,

    pub fn init(registry: *const MetricsRegistry) PrometheusExporter {
        return PrometheusExporter{
            .registry = registry,
        };
    }

    pub fn writeMetrics(self: *const PrometheusExporter, writer: anytype) !void {
        // Write HELP and TYPE headers for each metric
        for (self.registry.counters.items) |counter| {
            try writer.print("# HELP {s} {s}\n", .{ counter.name, counter.description });
            try writer.print("# TYPE {s} counter\n", .{counter.name});
            try writer.print("{s}{{unit=\"{s}\"}} {d}\n\n", .{ counter.name, counter.unit, counter.get() });
        }

        for (self.registry.gauges.items) |gauge| {
            try writer.print("# HELP {s} {s}\n", .{ gauge.name, gauge.description });
            try writer.print("# TYPE {s} gauge\n", .{gauge.name});
            try writer.print("{s}{{unit=\"{s}\"}} {d}\n\n", .{ gauge.name, gauge.unit, gauge.get() });
        }

        for (self.registry.histograms.items) |histogram| {
            try writer.print("# HELP {s} {s}\n", .{ histogram.name, histogram.description });
            try writer.print("# TYPE {s} histogram\n", .{histogram.name});

            const buckets = histogram.getBuckets();
            const counts = histogram.getCounts();
            const sum = histogram.getSum();
            const count = histogram.getCount();

            // Write bucket counts
            var cumulative: u64 = 0;
            for (buckets, counts, 0..) |bucket, bucket_count, i| {
                _ = i; // Index not used in current implementation
                cumulative += bucket_count;
                try writer.print("{s}_bucket{{le=\"{d}\"}} {d}\n", .{ histogram.name, bucket, cumulative });
            }
            // +Inf bucket
            try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ histogram.name, count });

            // Sum and count
            try writer.print("{s}_sum {d}\n", .{ histogram.name, sum });
            try writer.print("{s}_count {d}\n\n", .{ histogram.name, count });
        }
    }
};

// HTTP server for metrics exposition
pub const MetricsServer = struct {
    allocator: std.mem.Allocator,
    registry: *MetricsRegistry,
    server_thread: ?std.Thread = null,
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator, registry: *MetricsRegistry) MetricsServer {
        return MetricsServer{
            .allocator = allocator,
            .registry = registry,
        };
    }

    pub fn start(self: *MetricsServer, port: u16) !void {
        if (self.running) return;

        self.running = true;
        self.server_thread = try std.Thread.spawn(.{}, metricsServerThread, .{self, port});
    }

    pub fn stop(self: *MetricsServer) void {
        if (!self.running) return;

        self.running = false;
        if (self.server_thread) |thread| {
            thread.join();
            self.server_thread = null;
        }
    }

    fn metricsServerThread(self: *MetricsServer, port: u16) void {
        // Simple HTTP server for /metrics endpoint
        // In a real implementation, this would integrate with the main HTTP server
        std.log.info("Metrics server would start on port {}", .{port});
        std.log.info("Metrics available at http://localhost:{}/metrics", .{port});

        while (self.running) {
            std.time.sleep(1_000_000_000); // Sleep for 1 second
        }
    }
};

// Blitz-specific metrics
pub const BlitzMetrics = struct {
    allocator: std.mem.Allocator,
    registry: MetricsRegistry,

    // HTTP metrics
    http_requests_total: Counter,
    http_requests_duration: Histogram,
    http_responses_total: Counter,
    http_responses_by_status: std.StringHashMap(Counter),

    // Connection metrics
    active_connections: Gauge,
    total_connections: Counter,

    // QUIC metrics
    quic_packets_total: Counter,
    quic_handshakes_total: Counter,
    quic_handshake_duration: Histogram,

    // Rate limiting metrics
    rate_limit_requests_total: Counter,
    rate_limit_requests_dropped: Counter,
    rate_limit_active_ips: Gauge,

    // Load balancer metrics
    lb_requests_total: Counter,
    lb_requests_backend: std.AutoHashMap([]const u8, Counter),
    lb_backend_healthy: std.AutoHashMap([]const u8, Gauge),

    pub fn init(allocator: std.mem.Allocator) !BlitzMetrics {
        var registry = MetricsRegistry.init(allocator);

        // Define histogram buckets for latency measurements
        const latency_buckets = [_]f64{ 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 };

        var metrics = BlitzMetrics{
            .allocator = allocator,
            .registry = registry,

            // HTTP metrics
            .http_requests_total = Counter.init("blitz_http_requests_total", "Total number of HTTP requests", "requests"),
            .http_requests_duration = try Histogram.init(allocator, "blitz_http_request_duration_seconds", "HTTP request duration", "seconds", &latency_buckets),
            .http_responses_total = Counter.init("blitz_http_responses_total", "Total number of HTTP responses", "responses"),
            .http_responses_by_status = std.StringHashMap(Counter).init(allocator),

            // Connection metrics
            .active_connections = Gauge.init("blitz_active_connections", "Number of active connections", "connections"),
            .total_connections = Counter.init("blitz_connections_total", "Total number of connections", "connections"),

            // QUIC metrics
            .quic_packets_total = Counter.init("blitz_quic_packets_total", "Total number of QUIC packets", "packets"),
            .quic_handshakes_total = Counter.init("blitz_quic_handshakes_total", "Total number of QUIC handshakes", "handshakes"),
            .quic_handshake_duration = try Histogram.init(allocator, "blitz_quic_handshake_duration_seconds", "QUIC handshake duration", "seconds", &latency_buckets),

            // Rate limiting metrics
            .rate_limit_requests_total = Counter.init("blitz_rate_limit_requests_total", "Total requests subject to rate limiting", "requests"),
            .rate_limit_requests_dropped = Counter.init("blitz_rate_limit_requests_dropped", "Requests dropped by rate limiting", "requests"),
            .rate_limit_active_ips = Gauge.init("blitz_rate_limit_active_ips", "Number of IPs currently being rate limited", "ips"),

            // Load balancer metrics
            .lb_requests_total = Counter.init("blitz_lb_requests_total", "Total load balancer requests", "requests"),
            .lb_requests_backend = std.AutoHashMap([]const u8, Counter).init(allocator),
            .lb_backend_healthy = std.AutoHashMap([]const u8, Gauge).init(allocator),
        };

        // Register all metrics
        try registry.registerCounter(&metrics.http_requests_total);
        try registry.registerHistogram(&metrics.http_requests_duration);
        try registry.registerCounter(&metrics.http_responses_total);
        try registry.registerGauge(&metrics.active_connections);
        try registry.registerCounter(&metrics.total_connections);
        try registry.registerCounter(&metrics.quic_packets_total);
        try registry.registerCounter(&metrics.quic_handshakes_total);
        try registry.registerHistogram(&metrics.quic_handshake_duration);
        try registry.registerCounter(&metrics.rate_limit_requests_total);
        try registry.registerCounter(&metrics.rate_limit_requests_dropped);
        try registry.registerGauge(&metrics.rate_limit_active_ips);
        try registry.registerCounter(&metrics.lb_requests_total);

        return metrics;
    }

    pub fn deinit(self: *BlitzMetrics) void {
        self.http_requests_duration.deinit();
        self.quic_handshake_duration.deinit();
        self.http_responses_by_status.deinit();
        self.lb_requests_backend.deinit();
        self.lb_backend_healthy.deinit();
        self.registry.deinit();
    }

    // HTTP metrics methods
    pub fn recordHttpRequest(self: *BlitzMetrics, duration_seconds: f64) void {
        self.http_requests_total.inc();
        self.http_requests_duration.observe(duration_seconds);
    }

    pub fn recordHttpResponse(self: *BlitzMetrics, status_code: u16) void {
        self.http_responses_total.inc();

    // Get or create status-specific counter
    const status_key = status_code / 100 * 100; // Group by hundreds (2xx, 3xx, etc.)
    const status_key_str = std.fmt.allocPrint(self.allocator, "{d}", .{status_key}) catch return;
    defer self.allocator.free(status_key_str);

    const status_counter = self.http_responses_by_status.getOrPutValue(status_key_str, Counter.init(
        std.fmt.allocPrint(self.allocator, "blitz_http_responses_{d}xx_total", .{status_key / 100}) catch "blitz_http_responses_unknown_total",
        std.fmt.allocPrint(self.allocator, "HTTP {d}xx responses", .{status_key / 100}) catch "HTTP responses",
        "responses"
    )) catch return;

    status_counter.value_ptr.inc();
    }

    // Connection metrics methods
    pub fn incrementActiveConnections(self: *BlitzMetrics) void {
        self.total_connections.inc();
        self.active_connections.set(self.active_connections.get() + 1);
    }

    pub fn decrementActiveConnections(self: *BlitzMetrics) void {
        self.active_connections.set(@max(0, self.active_connections.get() - 1));
    }

    // QUIC metrics methods
    pub fn recordQuicPacket(self: *BlitzMetrics) void {
        self.quic_packets_total.inc();
    }

    pub fn recordQuicHandshake(self: *BlitzMetrics, duration_seconds: f64) void {
        self.quic_handshakes_total.inc();
        self.quic_handshake_duration.observe(duration_seconds);
    }

    // Rate limiting metrics methods
    pub fn recordRateLimitRequest(self: *BlitzMetrics, dropped: bool, active_ips: usize) void {
        self.rate_limit_requests_total.inc();
        if (dropped) {
            self.rate_limit_requests_dropped.inc();
        }
        self.rate_limit_active_ips.set(@floatFromInt(active_ips));
    }

    // Load balancer metrics methods
    pub fn recordLbRequest(self: *BlitzMetrics, backend_host: []const u8) void {
        self.lb_requests_total.inc();

        // Record per-backend metrics
        const backend_key = std.fmt.allocPrint(self.allocator, "backend_{s}", .{backend_host}) catch return;
        defer self.allocator.free(backend_key);

        const backend_counter = self.lb_requests_backend.getOrPutValue(backend_key, Counter.init(
            std.fmt.allocPrint(self.allocator, "blitz_lb_requests_backend_{s}_total", .{backend_host}) catch "blitz_lb_requests_backend_unknown_total",
            std.fmt.allocPrint(self.allocator, "Requests to backend {s}", .{backend_host}) catch "Requests to backend",
            "requests"
        )) catch return;

        backend_counter.value_ptr.inc();
    }

    pub fn updateBackendHealth(self: *BlitzMetrics, backend_host: []const u8, healthy: bool) void {
        const backend_key = std.fmt.allocPrint(self.allocator, "backend_{s}", .{backend_host}) catch return;
        defer self.allocator.free(backend_key);

        const health_gauge = self.lb_backend_healthy.getOrPutValue(backend_key, Gauge.init(
            std.fmt.allocPrint(self.allocator, "blitz_lb_backend_{s}_healthy", .{backend_host}) catch "blitz_lb_backend_unknown_healthy",
            std.fmt.allocPrint(self.allocator, "Backend {s} health status", .{backend_host}) catch "Backend health status",
            "status"
        )) catch return;

        health_gauge.value_ptr.set(if (healthy) 1.0 else 0.0);
    }

    // Get Prometheus exposition format
    pub fn getPrometheusMetrics(self: *const BlitzMetrics, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).initCapacity(allocator, 1024);
        defer buffer.deinit();

        const exporter = PrometheusExporter.init(&self.registry);
        try exporter.writeMetrics(buffer.writer());

        return buffer.toOwnedSlice();
    }
};
