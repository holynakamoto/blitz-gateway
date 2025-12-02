//! Simple HTTP server for metrics exposition
//! Serves Prometheus format metrics on /metrics endpoint

const std = @import("std");
const net = std.net;
const metrics = @import("metrics.zig");

pub const MetricsHttpServer = struct {
    allocator: std.mem.Allocator,
    registry: *const metrics.MetricsRegistry,
    server_thread: ?std.Thread = null,
    running: bool = false,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, registry: *const metrics.MetricsRegistry, port: u16) MetricsHttpServer {
        return MetricsHttpServer{
            .allocator = allocator,
            .registry = registry,
            .port = port,
        };
    }

    pub fn start(self: *MetricsHttpServer) !void {
        if (self.running) return;

        self.running = true;
        self.server_thread = try std.Thread.spawn(.{}, serverThread, .{self});
    }

    pub fn stop(self: *MetricsHttpServer) void {
        if (!self.running) return;

        self.running = false;
        if (self.server_thread) |thread| {
            thread.join();
            self.server_thread = null;
        }
    }

    fn serverThread(self: *MetricsHttpServer) void {
        const address = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, self.port);

        var server = net.StreamServer.init(.{});
        defer server.deinit();

        server.listen(address) catch |err| {
            std.log.err("Failed to start metrics HTTP server on port {d}: {any}", .{ self.port, err });
            return;
        };

        std.log.info("Metrics HTTP server listening on http://127.0.0.1:{}", .{self.port});

        while (self.running) {
            const connection = server.accept() catch |err| {
                std.log.err("Failed to accept connection: {}", .{err});
                continue;
            };

            // Handle connection in a separate thread
            std.Thread.spawn(.{}, handleConnection, .{ self, connection }) catch |err| {
                std.log.err("Failed to spawn connection handler: {}", .{err});
                connection.stream.close();
            };
        }
    }

    fn handleConnection(self: *MetricsHttpServer, connection: net.StreamServer.Connection) void {
        defer connection.stream.close();

        // Read request (simple HTTP/1.0 parsing)
        var buffer: [4096]u8 = undefined;
        const bytes_read = connection.stream.read(&buffer) catch |err| {
            std.log.err("Failed to read HTTP request: {}", .{err});
            return;
        };

        const request = buffer[0..bytes_read];

        // Simple request parsing - look for GET /metrics
        if (std.mem.indexOf(u8, request, "GET /metrics")) |_| {
            // Serve metrics
            self.serveMetrics(connection.stream) catch |err| {
                std.log.err("Failed to serve metrics: {}", .{err});
            };
        } else {
            // Serve simple HTML page with links
            self.serveIndexPage(connection.stream) catch |err| {
                std.log.err("Failed to serve index page: {}", .{err});
            };
        }
    }

    fn serveMetrics(self: *MetricsHttpServer, stream: net.Stream) !void {
        // Generate Prometheus metrics
        var metrics_buffer = std.ArrayList(u8).init(self.allocator);
        defer metrics_buffer.deinit();

        const exporter = metrics.PrometheusExporter.init(self.registry);
        try exporter.writeMetrics(metrics_buffer.writer());

        const metrics_data = metrics_buffer.items;

        // HTTP response
        const response = std.fmt.allocPrint(self.allocator,
            \\HTTP/1.1 200 OK\r
            \\Content-Type: text/plain; version=0.0.4; charset=utf-8\r
            \\Content-Length: {}\r
            \\Connection: close\r
            \\\r
            \\{}
        , .{ metrics_data.len, std.fmt.fmtSliceHexLower("") }) catch "";

        defer self.allocator.free(response);

        // Write response header
        try stream.writeAll(response[0 .. std.mem.indexOf(u8, response, "{}").? + 1]);

        // Write metrics data
        try stream.writeAll(metrics_data);
    }

    fn serveIndexPage(self: *MetricsHttpServer, stream: net.Stream) !void {
        const html = std.fmt.allocPrint(self.allocator,
            \\HTTP/1.1 200 OK\r
            \\Content-Type: text/html\r
            \\Content-Length: {}\r
            \\Connection: close\r
            \\\r
            \\<html><head><title>Blitz Metrics</title></head><body>
            \\<h1>Blitz Edge Gateway Metrics</h1>
            \\<p><a href="/metrics">Prometheus Metrics</a></p>
            \\<p><a href="http://localhost:{}/grafana">Grafana Dashboard</a></p>
            \\<p><a href="http://localhost:{}/prometheus">Prometheus UI</a></p>
            \\</body></html>
        , .{ std.fmt.count("{}{}", .{ self.port + 1, self.port + 2 }), self.port + 1, self.port + 2 }) catch "";

        defer self.allocator.free(html);

        try stream.writeAll(html);
    }
};
