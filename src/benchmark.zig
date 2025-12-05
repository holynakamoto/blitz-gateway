//! Built-in benchmark module for Blitz Gateway
//!
//! Provides self-contained performance testing without external tools.
//! All three protocols (HTTP/1.1, HTTP/2, HTTP/3) are built into the binary.
//!
//! Usage:
//!   ./blitz --bench              # Run all protocol benchmarks
//!   ./blitz --bench http1        # Benchmark HTTP/1.1 only
//!   ./blitz --bench http2        # Benchmark HTTP/2 (h2c cleartext)
//!   ./blitz --bench http3        # Benchmark HTTP/3 (QUIC)
//!   ./blitz --bench --duration 60  # Custom duration

const std = @import("std");
const net = std.net;
const time = std.time;
const posix = std.posix;

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

        return @as(f64, @floatFromInt(self.latencies.items[clamped_index])) / 1000.0;
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

//═══════════════════════════════════════════════════════════════════════════════
// HTTP/1.1 BENCHMARK CLIENT
//═══════════════════════════════════════════════════════════════════════════════

fn benchmarkHttp1Connection(state: *WorkerState) void {
    const request = "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";

    while (!state.should_stop.load(.acquire)) {
        const start = time.nanoTimestamp();

        const address = net.Address.parseIp4(state.config.target_host, state.config.port) catch {
            state.failed_requests += 1;
            continue;
        };

        var stream = net.tcpConnectToAddress(address) catch {
            state.failed_requests += 1;
            continue;
        };
        defer stream.close();

        // Send multiple requests per connection (keep-alive)
        var requests_on_conn: u32 = 0;
        const max_per_conn: u32 = 100;

        while (requests_on_conn < max_per_conn and !state.should_stop.load(.acquire)) {
            const req_start = time.nanoTimestamp();

            _ = stream.write(request) catch {
                state.failed_requests += 1;
                break;
            };

            var buffer: [4096]u8 = undefined;
            const bytes_read = stream.read(&buffer) catch {
                state.failed_requests += 1;
                break;
            };

            if (bytes_read == 0) break;

            const req_end = time.nanoTimestamp();
            const latency_ns = @as(u64, @intCast(req_end - req_start));

            state.histogram.record(latency_ns) catch {};
            state.total_requests += 1;
            state.successful_requests += 1;
            state.bytes_transferred += bytes_read;
            requests_on_conn += 1;
        }

        _ = start;
    }
}

//═══════════════════════════════════════════════════════════════════════════════
// HTTP/2 BENCHMARK CLIENT (h2c cleartext)
//═══════════════════════════════════════════════════════════════════════════════

const HTTP2_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

fn benchmarkHttp2Connection(state: *WorkerState) void {
    while (!state.should_stop.load(.acquire)) {
        const address = net.Address.parseIp4(state.config.target_host, state.config.port) catch {
            state.failed_requests += 1;
            continue;
        };

        var stream = net.tcpConnectToAddress(address) catch {
            state.failed_requests += 1;
            continue;
        };
        defer stream.close();

        // Send HTTP/2 connection preface
        _ = stream.write(HTTP2_PREFACE) catch {
            state.failed_requests += 1;
            continue;
        };

        // Send empty SETTINGS frame
        const settings_frame = [_]u8{
            0x00, 0x00, 0x00, // Length: 0
            0x04, // Type: SETTINGS
            0x00, // Flags: none
            0x00, 0x00, 0x00, 0x00, // Stream ID: 0
        };
        _ = stream.write(&settings_frame) catch {
            state.failed_requests += 1;
            continue;
        };

        // Read server's SETTINGS
        var settings_buf: [64]u8 = undefined;
        _ = stream.read(&settings_buf) catch {
            state.failed_requests += 1;
            continue;
        };

        // Send SETTINGS ACK
        const settings_ack = [_]u8{
            0x00, 0x00, 0x00, // Length: 0
            0x04, // Type: SETTINGS
            0x01, // Flags: ACK
            0x00, 0x00, 0x00, 0x00, // Stream ID: 0
        };
        _ = stream.write(&settings_ack) catch {
            state.failed_requests += 1;
            continue;
        };

        // Send requests on multiplexed streams
        var stream_id: u32 = 1;
        const max_streams: u32 = 50;

        while (stream_id <= max_streams * 2 and !state.should_stop.load(.acquire)) {
            const req_start = time.nanoTimestamp();

            // HEADERS frame: :method GET, :path /, :scheme http, :authority localhost
            const headers_payload = [_]u8{
                0x82, // :method GET (indexed)
                0x86, // :scheme http (indexed)
                0x84, // :path / (indexed)
                0x41, 0x09, 'l', 'o', 'c', 'a', 'l', 'h', 'o', 's', 't', // :authority
            };

            var headers_frame: [9 + headers_payload.len]u8 = undefined;
            headers_frame[0] = 0;
            headers_frame[1] = 0;
            headers_frame[2] = @intCast(headers_payload.len);
            headers_frame[3] = 0x01; // HEADERS
            headers_frame[4] = 0x05; // END_HEADERS | END_STREAM
            headers_frame[5] = @intCast((stream_id >> 24) & 0x7F);
            headers_frame[6] = @intCast((stream_id >> 16) & 0xFF);
            headers_frame[7] = @intCast((stream_id >> 8) & 0xFF);
            headers_frame[8] = @intCast(stream_id & 0xFF);
            @memcpy(headers_frame[9..], &headers_payload);

            _ = stream.write(&headers_frame) catch {
                state.failed_requests += 1;
                break;
            };

            // Read response
            var response_buf: [1024]u8 = undefined;
            const bytes_read = stream.read(&response_buf) catch {
                state.failed_requests += 1;
                break;
            };

            if (bytes_read == 0) break;

            const req_end = time.nanoTimestamp();
            const latency_ns = @as(u64, @intCast(req_end - req_start));

            state.histogram.record(latency_ns) catch {};
            state.total_requests += 1;
            state.successful_requests += 1;
            state.bytes_transferred += bytes_read;

            stream_id += 2; // Client streams are odd
        }
    }
}

//═══════════════════════════════════════════════════════════════════════════════
// HTTP/3 BENCHMARK CLIENT (QUIC/UDP)
//═══════════════════════════════════════════════════════════════════════════════

fn benchmarkHttp3Connection(state: *WorkerState) void {
    while (!state.should_stop.load(.acquire)) {
        const req_start = time.nanoTimestamp();

        // Create UDP socket
        const sock = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0) catch {
            state.failed_requests += 1;
            std.Thread.sleep(1 * std.time.ns_per_ms);
            continue;
        };
        defer posix.close(sock);

        // Parse target address
        const addr = net.Address.parseIp4(state.config.target_host, state.config.port) catch {
            state.failed_requests += 1;
            continue;
        };

        // Build QUIC Initial packet
        var initial_packet: [1200]u8 = undefined;
        var pkt_len: usize = 0;

        // Long header: Initial packet
        initial_packet[0] = 0xC0; // Long header + Initial
        pkt_len += 1;

        // Version (QUIC v1)
        initial_packet[1] = 0x00;
        initial_packet[2] = 0x00;
        initial_packet[3] = 0x00;
        initial_packet[4] = 0x01;
        pkt_len += 4;

        // DCID
        initial_packet[5] = 8;
        pkt_len += 1;
        std.crypto.random.bytes(initial_packet[6..14]);
        pkt_len += 8;

        // SCID
        initial_packet[14] = 8;
        pkt_len += 1;
        std.crypto.random.bytes(initial_packet[15..23]);
        pkt_len += 8;

        // Token length (0)
        initial_packet[23] = 0;
        pkt_len += 1;

        // Packet length
        const remaining = 1200 - pkt_len - 2;
        initial_packet[24] = 0x40 | @as(u8, @intCast((remaining >> 8) & 0x3F));
        initial_packet[25] = @intCast(remaining & 0xFF);
        pkt_len += 2;

        // Packet number
        initial_packet[26] = 0x00;
        pkt_len += 1;

        // Minimal CRYPTO frame
        initial_packet[27] = 0x06; // CRYPTO
        initial_packet[28] = 0x00; // Offset
        initial_packet[29] = 0x40;
        initial_packet[30] = 0x05; // Length = 5
        pkt_len += 4;

        // Dummy ClientHello
        initial_packet[31] = 0x01;
        initial_packet[32] = 0x00;
        initial_packet[33] = 0x00;
        initial_packet[34] = 0x01;
        initial_packet[35] = 0x00;
        pkt_len += 5;

        // Pad to 1200 bytes
        @memset(initial_packet[pkt_len..1200], 0);

        // Send packet
        _ = posix.sendto(sock, &initial_packet, 0, &addr.any, addr.getOsSockLen()) catch {
            state.failed_requests += 1;
            continue;
        };

        // Set receive timeout (100ms)
        const timeout = posix.timeval{ .sec = 0, .usec = 100000 };
        posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

        // Try to receive
        var recv_buf: [2048]u8 = undefined;
        var from_addr: posix.sockaddr = undefined;
        var from_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const recvd = posix.recvfrom(sock, &recv_buf, 0, &from_addr, &from_len) catch |err| {
            if (err == error.WouldBlock) {
                state.total_requests += 1;
                state.failed_requests += 1;
                continue;
            }
            state.failed_requests += 1;
            continue;
        };

        const req_end = time.nanoTimestamp();
        const latency_ns = @as(u64, @intCast(req_end - req_start));

        if (recvd > 0) {
            state.histogram.record(latency_ns) catch {};
            state.total_requests += 1;
            state.successful_requests += 1;
            state.bytes_transferred += recvd;
        } else {
            state.total_requests += 1;
            state.failed_requests += 1;
        }

        // Small delay between UDP packets
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

/// Worker thread entry point
fn workerThread(state: *WorkerState) void {
    switch (state.config.protocol) {
        .http1 => benchmarkHttp1Connection(state),
        .http2 => benchmarkHttp2Connection(state),
        .http3 => benchmarkHttp3Connection(state),
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
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Starting {s} Benchmark", .{protocol_name});
    var pad: usize = 45 - protocol_name.len;
    while (pad > 0) : (pad -= 1) {
        std.debug.print(" ", .{});
    }
    std.debug.print("║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Threads:     {}\n", .{cfg.threads});
    std.debug.print("  Connections: {}\n", .{cfg.connections});
    std.debug.print("  Duration:    {}s\n", .{cfg.duration_seconds});
    std.debug.print("  Target:      {s}:{}\n", .{ cfg.target_host, cfg.port });
    std.debug.print("\n", .{});

    var should_stop = std.atomic.Value(bool).init(false);

    const workers = try allocator.alloc(WorkerState, cfg.threads);
    defer allocator.free(workers);

    const threads = try allocator.alloc(std.Thread, cfg.threads);
    defer allocator.free(threads);

    for (workers, 0..) |*worker, i| {
        worker.* = WorkerState.init(allocator, @intCast(i), cfg, &should_stop);
    }
    defer {
        for (workers) |*worker| {
            worker.deinit();
        }
    }

    const start_time = time.nanoTimestamp();
    for (threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, workerThread, .{&workers[i]});
    }

    // Progress
    var elapsed: u32 = 0;
    while (elapsed < cfg.duration_seconds) {
        std.Thread.sleep(std.time.ns_per_s);
        elapsed += 1;

        var current_requests: u64 = 0;
        for (workers) |*worker| {
            current_requests += worker.successful_requests;
        }
        const current_rps = @as(f64, @floatFromInt(current_requests)) / @as(f64, @floatFromInt(elapsed));

        std.debug.print("\r  Progress: {}/{:>2}s | Requests: {:>10} | RPS: {:>10.0}  ", .{
            elapsed,
            cfg.duration_seconds,
            current_requests,
            current_rps,
        });
    }
    std.debug.print("\n", .{});

    should_stop.store(true, .release);

    for (threads) |thread| {
        thread.join();
    }

    const end_time = time.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end_time - start_time));

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

        for (worker.histogram.latencies.items) |lat| {
            try combined_histogram.record(lat);
        }
    }

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

/// Print benchmark results
pub fn printResults(result: BenchmarkResult) void {
    std.debug.print("\n", .{});
    std.debug.print("┌──────────────────────────────────────────────────────────┐\n", .{});
    std.debug.print("│  {s} Results", .{result.protocol});

    const title_len = result.protocol.len + 10;
    var padding: usize = 0;
    if (title_len < 58) {
        padding = 58 - title_len;
    }
    var i: usize = 0;
    while (i < padding) : (i += 1) {
        std.debug.print(" ", .{});
    }
    std.debug.print("│\n", .{});
    std.debug.print("└──────────────────────────────────────────────────────────┘\n", .{});
    std.debug.print("\n", .{});

    std.debug.print("  Throughput:\n", .{});
    std.debug.print("    Total Requests:      {:>15}\n", .{result.total_requests});
    std.debug.print("    Successful:          {:>15}\n", .{result.successful_requests});
    std.debug.print("    Failed:              {:>15}\n", .{result.failed_requests});
    std.debug.print("    Requests/sec:        {:>15.2} RPS\n", .{result.rps});

    const duration_s = @as(f64, @floatFromInt(result.duration_ns)) / @as(f64, std.time.ns_per_s);
    const throughput_mbs = @as(f64, @floatFromInt(result.bytes_transferred)) / 1024.0 / 1024.0 / duration_s;
    std.debug.print("    Throughput:          {:>15.2} MB/s\n", .{throughput_mbs});
    std.debug.print("\n", .{});

    std.debug.print("  Latency:\n", .{});
    std.debug.print("    Average:             {:>15.2} µs\n", .{result.avg_latency_us});
    std.debug.print("    Minimum:             {:>15.2} µs\n", .{result.min_latency_us});
    std.debug.print("    Maximum:             {:>15.2} µs\n", .{result.max_latency_us});
    std.debug.print("    p50:                 {:>15.2} µs\n", .{result.p50_latency_us});
    std.debug.print("    p99:                 {:>15.2} µs\n", .{result.p99_latency_us});
    std.debug.print("    p99.9:               {:>15.2} µs\n", .{result.p999_latency_us});
    std.debug.print("\n", .{});
}

/// Print summary comparison
pub fn printSummary(results: []const BenchmarkResult) void {
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                         BENCHMARK SUMMARY                                ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    std.debug.print("┌──────────┬──────────────┬─────────────┬─────────────┬────────┐\n", .{});
    std.debug.print("│ Protocol │     RPS      │ Avg Latency │ P99 Latency │ Status │\n", .{});
    std.debug.print("├──────────┼──────────────┼─────────────┼─────────────┼────────┤\n", .{});

    for (results) |result| {
        const status: []const u8 = if (result.failed_requests == 0) "  ✓   " else "  ⚠   ";
        std.debug.print("│ {s: <8} │ {d: >12.0} │ {d: >9.0}µs │ {d: >9.0}µs │{s}│\n", .{
            result.protocol,
            result.rps,
            result.avg_latency_us,
            result.p99_latency_us,
            status,
        });
    }

    std.debug.print("└──────────┴──────────────┴─────────────┴─────────────┴────────┘\n", .{});
    std.debug.print("\n", .{});

    // Best performer
    var best_rps: f64 = 0;
    var best_protocol: []const u8 = "";
    for (results) |result| {
        if (result.rps > best_rps) {
            best_rps = result.rps;
            best_protocol = result.protocol;
        }
    }

    if (best_protocol.len > 0) {
        std.debug.print("  🏆 Best performer: {s} at {d:.0} RPS\n", .{ best_protocol, best_rps });
    }
    std.debug.print("\n", .{});
}
