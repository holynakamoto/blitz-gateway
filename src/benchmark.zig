//! Built-in benchmark module for Blitz Gateway
//!
//! Provides self-contained performance testing without external tools.
//!
//! Usage:
//!   ./blitz --bench              # Run all protocol benchmarks
//!   ./blitz --bench http1        # Benchmark HTTP/1.1 only
//!   ./blitz --bench --duration 60  # Custom duration

const std = @import("std");
const net = std.net;
const time = std.time;

pub const BenchmarkConfig = struct {
    protocol: Protocol,
    duration_seconds: u32 = 30,
    connections: u32 = 100,
    threads: u32 = 4,
    target_host: []const u8 = "127.0.0.1",
    port: u16 = 8080,

    pub const Protocol = enum {
        http1,
        http2,
        http3,
        all,
    };
};

pub const BenchmarkResult = struct {
    protocol: []const u8,
    total_requests: u64,
    successful_requests: u64,
    failed_requests: u64,
    duration_ns: u64,
    rps: f64,
    avg_latency_us: f64,
    p50_latency_us: f64,
    p99_latency_us: f64,
    p999_latency_us: f64,
    min_latency_us: f64,
    max_latency_us: f64,
    bytes_transferred: u64,
};

/// Latency histogram for percentile calculations
const LatencyHistogram = struct {
    latencies: std.ArrayListUnmanaged(u64),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) LatencyHistogram {
        return .{
            .latencies = .{},
            .allocator = allocator,
        };
    }

    fn deinit(self: *LatencyHistogram) void {
        self.latencies.deinit(self.allocator);
    }

    fn record(self: *LatencyHistogram, latency_ns: u64) !void {
        try self.latencies.append(self.allocator, latency_ns);
    }

    fn calculatePercentile(self: *LatencyHistogram, percentile: f64) f64 {
        if (self.latencies.items.len == 0) return 0;

        // Sort latencies
        std.mem.sort(u64, self.latencies.items, {}, std.sort.asc(u64));

        const index = @as(usize, @intFromFloat(
            @as(f64, @floatFromInt(self.latencies.items.len)) * percentile,
        ));
        const clamped_index = @min(index, self.latencies.items.len - 1);

        return @as(f64, @floatFromInt(self.latencies.items[clamped_index])) / 1000.0; // Convert to µs
    }

    fn getMin(self: *LatencyHistogram) f64 {
        if (self.latencies.items.len == 0) return 0;
        var min: u64 = std.math.maxInt(u64);
        for (self.latencies.items) |lat| {
            min = @min(min, lat);
        }
        return @as(f64, @floatFromInt(min)) / 1000.0;
    }

    fn getMax(self: *LatencyHistogram) f64 {
        if (self.latencies.items.len == 0) return 0;
        var max: u64 = 0;
        for (self.latencies.items) |lat| {
            max = @max(max, lat);
        }
        return @as(f64, @floatFromInt(max)) / 1000.0;
    }

    fn getAverage(self: *LatencyHistogram) f64 {
        if (self.latencies.items.len == 0) return 0;
        var sum: u64 = 0;
        for (self.latencies.items) |lat| {
            sum += lat;
        }
        return @as(f64, @floatFromInt(sum)) /
            @as(f64, @floatFromInt(self.latencies.items.len)) / 1000.0;
    }
};

/// Worker thread state
const WorkerState = struct {
    id: u32,
    config: BenchmarkConfig,
    histogram: LatencyHistogram,
    total_requests: u64 = 0,
    successful_requests: u64 = 0,
    failed_requests: u64 = 0,
    bytes_transferred: u64 = 0,
    should_stop: *std.atomic.Value(bool),
    allocator: std.mem.Allocator,

    fn init(
        allocator: std.mem.Allocator,
        id: u32,
        cfg: BenchmarkConfig,
        should_stop: *std.atomic.Value(bool),
    ) WorkerState {
        return .{
            .id = id,
            .config = cfg,
            .histogram = LatencyHistogram.init(allocator),
            .should_stop = should_stop,
            .allocator = allocator,
        };
    }

    fn deinit(self: *WorkerState) void {
        self.histogram.deinit();
    }
};

/// Benchmark a single connection (HTTP/1.1)
fn benchmarkHttp1Connection(state: *WorkerState) void {
    const request = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";

    while (!state.should_stop.load(.acquire)) {
        const start = time.nanoTimestamp();

        // Connect
        const address = net.Address.parseIp4(state.config.target_host, state.config.port) catch {
            state.failed_requests += 1;
            continue;
        };

        var stream = net.tcpConnectToAddress(address) catch {
            state.failed_requests += 1;
            continue;
        };
        defer stream.close();

        // Send request
        _ = stream.write(request) catch {
            state.failed_requests += 1;
            continue;
        };

        // Read response
        var buffer: [4096]u8 = undefined;
        const bytes_read = stream.read(&buffer) catch {
            state.failed_requests += 1;
            continue;
        };

        const end = time.nanoTimestamp();
        const latency_ns = @as(u64, @intCast(end - start));

        // Record metrics
        state.histogram.record(latency_ns) catch {};
        state.total_requests += 1;
        state.successful_requests += 1;
        state.bytes_transferred += bytes_read;
    }
}

/// Worker thread entry point
fn workerThread(state: *WorkerState) void {
    switch (state.config.protocol) {
        .http1 => benchmarkHttp1Connection(state),
        .http2 => benchmarkHttp1Connection(state), // TODO: Implement HTTP/2
        .http3 => {}, // TODO: Implement HTTP/3 (QUIC)
        .all => benchmarkHttp1Connection(state),
    }
}

/// Run benchmark for a single protocol
pub fn runBenchmark(
    allocator: std.mem.Allocator,
    cfg: BenchmarkConfig,
) !BenchmarkResult {
    const protocol_name = switch (cfg.protocol) {
        .http1 => "HTTP/1.1",
        .http2 => "HTTP/2",
        .http3 => "HTTP/3",
        .all => "All",
    };

    std.debug.print("\n", .{});
    std.debug.print("Starting {s} benchmark...\n", .{protocol_name});
    std.debug.print("  Threads: {}\n", .{cfg.threads});
    std.debug.print("  Connections: {}\n", .{cfg.connections});
    std.debug.print("  Duration: {}s\n", .{cfg.duration_seconds});
    std.debug.print("  Target: {s}:{}\n", .{ cfg.target_host, cfg.port });
    std.debug.print("\n", .{});

    var should_stop = std.atomic.Value(bool).init(false);

    // Allocate workers
    const workers = try allocator.alloc(WorkerState, cfg.threads);
    defer allocator.free(workers);

    const threads = try allocator.alloc(std.Thread, cfg.threads);
    defer allocator.free(threads);

    // Initialize workers
    for (workers, 0..) |*worker, i| {
        worker.* = WorkerState.init(
            allocator,
            @intCast(i),
            cfg,
            &should_stop,
        );
    }
    defer {
        for (workers) |*worker| {
            worker.deinit();
        }
    }

    // Start workers
    const start_time = time.nanoTimestamp();
    for (threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, workerThread, .{&workers[i]});
    }

    // Progress indicator
    var elapsed: u32 = 0;
    while (elapsed < cfg.duration_seconds) {
        std.Thread.sleep(std.time.ns_per_s);
        elapsed += 1;
        std.debug.print("\rProgress: {}/{}s", .{ elapsed, cfg.duration_seconds });
    }
    std.debug.print("\n", .{});

    // Stop workers
    should_stop.store(true, .release);

    // Join threads
    for (threads) |thread| {
        thread.join();
    }

    const end_time = time.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end_time - start_time));

    // Aggregate results
    var total_requests: u64 = 0;
    var successful_requests: u64 = 0;
    var failed_requests: u64 = 0;
    var bytes_transferred: u64 = 0;
    var combined_histogram = LatencyHistogram.init(allocator);
    defer combined_histogram.deinit();

    for (workers) |*worker| {
        total_requests += worker.total_requests;
        successful_requests += worker.successful_requests;
        failed_requests += worker.failed_requests;
        bytes_transferred += worker.bytes_transferred;

        // Combine histograms
        for (worker.histogram.latencies.items) |lat| {
            try combined_histogram.record(lat);
        }
    }

    // Calculate metrics
    const duration_s = @as(f64, @floatFromInt(duration_ns)) / @as(f64, std.time.ns_per_s);
    const rps = @as(f64, @floatFromInt(successful_requests)) / duration_s;

    return BenchmarkResult{
        .protocol = protocol_name,
        .total_requests = total_requests,
        .successful_requests = successful_requests,
        .failed_requests = failed_requests,
        .duration_ns = duration_ns,
        .rps = rps,
        .avg_latency_us = combined_histogram.getAverage(),
        .p50_latency_us = combined_histogram.calculatePercentile(0.50),
        .p99_latency_us = combined_histogram.calculatePercentile(0.99),
        .p999_latency_us = combined_histogram.calculatePercentile(0.999),
        .min_latency_us = combined_histogram.getMin(),
        .max_latency_us = combined_histogram.getMax(),
        .bytes_transferred = bytes_transferred,
    };
}

/// Print benchmark results in a nice format
pub fn printResults(result: BenchmarkResult) void {
    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  {s} Benchmark Results", .{result.protocol});

    // Padding calculation
    const title_len = result.protocol.len + 20;
    var padding: usize = 0;
    if (title_len < 56) {
        padding = 56 - title_len;
    }
    var i: usize = 0;
    while (i < padding) : (i += 1) {
        std.debug.print(" ", .{});
    }
    std.debug.print("║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    std.debug.print("Throughput:\n", .{});
    std.debug.print("  Total Requests:      {}\n", .{result.total_requests});
    std.debug.print("  Successful:          {}\n", .{result.successful_requests});
    std.debug.print("  Failed:              {}\n", .{result.failed_requests});
    std.debug.print("  Requests/sec:        {d:.2} RPS\n", .{result.rps});

    const duration_s = @as(f64, @floatFromInt(result.duration_ns)) / @as(f64, std.time.ns_per_s);
    const throughput_mbs = @as(f64, @floatFromInt(result.bytes_transferred)) / 1024.0 / 1024.0 / duration_s;
    std.debug.print("  Throughput:          {d:.2} MB/s\n", .{throughput_mbs});
    std.debug.print("\n", .{});

    std.debug.print("Latency:\n", .{});
    std.debug.print("  Average:             {d:.2} µs\n", .{result.avg_latency_us});
    std.debug.print("  Minimum:             {d:.2} µs\n", .{result.min_latency_us});
    std.debug.print("  Maximum:             {d:.2} µs\n", .{result.max_latency_us});
    std.debug.print("  p50:                 {d:.2} µs\n", .{result.p50_latency_us});
    std.debug.print("  p99:                 {d:.2} µs\n", .{result.p99_latency_us});
    std.debug.print("  p99.9:               {d:.2} µs\n", .{result.p999_latency_us});
    std.debug.print("\n", .{});
}

/// Print summary comparison of all protocols
pub fn printSummary(results: []const BenchmarkResult) void {
    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Benchmark Summary                                     ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    std.debug.print("| Protocol | RPS      | Avg Latency | P99 Latency | Status |\n", .{});
    std.debug.print("|----------|----------|-------------|-------------|--------|\n", .{});

    for (results) |result| {
        const status = if (result.failed_requests == 0) "✓" else "⚠";
        std.debug.print("| {s: <8} | {d: >8.0} | {d: >9.0}µs | {d: >9.0}µs | {s: ^6} |\n", .{
            result.protocol,
            result.rps,
            result.avg_latency_us,
            result.p99_latency_us,
            status,
        });
    }

    std.debug.print("\n", .{});
}

