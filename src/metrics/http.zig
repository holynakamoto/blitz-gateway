//! Simple HTTP server for metrics exposition
//! Serves Prometheus format metrics on /metrics endpoint

const std = @import("std");
const net = std.net;
const metrics = @import("mod.zig");

pub const MetricsHttpServer = struct {
    allocator: std.mem.Allocator,
    registry: *const metrics.MetricsRegistry,
    server_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    port: u16,
    active_threads: std.ArrayList(std.Thread),
    threads_mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, registry: *const metrics.MetricsRegistry, port: u16) MetricsHttpServer {
        return MetricsHttpServer{
            .allocator = allocator,
            .registry = registry,
            .port = port,
            .active_threads = std.ArrayList(std.Thread).init(allocator),
            .threads_mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *MetricsHttpServer) void {
        self.active_threads.deinit();
    }

    pub fn start(self: *MetricsHttpServer) !void {
        if (self.running.load(.acquire)) return;

        self.running.store(true, .release);
        self.server_thread = try std.Thread.spawn(.{}, serverThread, .{self});
    }

    pub fn stop(self: *MetricsHttpServer) void {
        if (!self.running.load(.acquire)) return;

        self.running.store(false, .release);

        // Create a self-connection to unblock accept()
        const address = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, self.port);
        if (net.tcpConnectToAddress(address)) |stream| {
            stream.close();
        } else |_| {
            // Ignore connection errors - the goal is just to unblock accept()
        }

        if (self.server_thread) |thread| {
            thread.join();
            self.server_thread = null;
        }

        // Join all active handler threads
        {
            self.threads_mutex.lock();
            const threads_to_join = self.active_threads.toOwnedSlice() catch {
                // If we can't allocate, just detach the threads as fallback
                for (self.active_threads.items) |thread| {
                    thread.detach();
                }
                self.active_threads.clearRetainingCapacity();
                self.threads_mutex.unlock();
                return;
            };
            self.threads_mutex.unlock();

            // Join all threads outside of the lock to avoid deadlocks
            for (threads_to_join) |thread| {
                thread.join();
            }

            // Free the slice
            self.allocator.free(threads_to_join);
        }
    }

    fn serverThread(self: *MetricsHttpServer) void {
        const address = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, self.port);

        var server = net.StreamServer.init(.{});
        defer server.deinit();

        server.listen(address) catch |err| {
            std.log.err("Failed to start metrics HTTP server on port {d}: {}", .{ self.port, err });
            return;
        };

        std.log.info("Metrics HTTP server listening on http://127.0.0.1:{d}", .{self.port});

        while (self.running.load(.acquire)) {
            const connection = server.accept() catch |err| {
                // If stop() was called (self-connection unblocked accept), break out of loop
                if (!self.running.load(.acquire)) {
                    break;
                }
                std.log.err("Failed to accept connection: {}", .{err});
                continue;
            };

            // Handle connection in a separate thread
            const handler_thread = std.Thread.spawn(.{}, handleConnectionWrapper, .{ self, connection }) catch |err| {
                std.log.err("Failed to spawn connection handler: {}", .{err});
                connection.stream.close();
                continue;
            };

            // Add thread to active threads collection
            {
                self.threads_mutex.lock();
                defer self.threads_mutex.unlock();
                self.active_threads.append(handler_thread) catch |err| {
                    std.log.err("Failed to track handler thread: {}", .{err});
                    handler_thread.detach(); // Fallback to detach if we can't track
                };
            }
        }
    }

    fn handleConnectionWrapper(self: *MetricsHttpServer, connection: net.StreamServer.Connection) void {
        // Call the actual handler
        self.handleConnection(connection);

        // Remove this thread from the active threads collection
        const current_thread = std.Thread.self();
        self.threads_mutex.lock();
        defer self.threads_mutex.unlock();

        // Find and remove this thread from the active threads list
        for (self.active_threads.items, 0..) |thread, i| {
            if (thread.id == current_thread.id) {
                _ = self.active_threads.swapRemove(i);
                break;
            }
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

        var request = buffer[0..bytes_read];

        // Trim leading whitespace/CRLF
        while (request.len > 0 and (request[0] == ' ' or request[0] == '\t' or request[0] == '\r' or request[0] == '\n')) {
            request = request[1..];
        }

        // Check if request starts with "GET /metrics" (case-sensitive)
        if (std.mem.startsWith(u8, request, "GET /metrics")) {
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

        // HTTP response header
        const header = try std.fmt.allocPrint(self.allocator,
            \\HTTP/1.1 200 OK\r
            \\Content-Type: text/plain; version=0.0.4; charset=utf-8\r
            \\Content-Length: {}\r
            \\Connection: close\r
            \\\r
        , .{metrics_data.len});
        defer self.allocator.free(header);

        // Write response header
        try stream.writeAll(header);
        // Write metrics data
        try stream.writeAll(metrics_data);
    }

    fn serveIndexPage(self: *MetricsHttpServer, stream: net.Stream) !void {
        // Construct the HTML body first
        const body = std.fmt.allocPrint(self.allocator,
            \\<html><head><title>Blitz Metrics</title></head><body>
            \\<h1>Blitz Edge Gateway Metrics</h1>
            \\<p><a href="/metrics">Prometheus Metrics</a></p>
            \\<p><a href="http://localhost:{}/grafana">Grafana Dashboard</a></p>
            \\<p><a href="http://localhost:{}/prometheus">Prometheus UI</a></p>
            \\</body></html>
        , .{ self.port + 1, self.port + 2 }) catch return error.OutOfMemory;
        defer self.allocator.free(body);

        // Get the actual byte length of the body
        const body_len = body.len;

        // Build the HTTP header with the correct Content-Length
        const header = std.fmt.allocPrint(self.allocator,
            \\HTTP/1.1 200 OK\r
            \\Content-Type: text/html\r
            \\Content-Length: {}\r
            \\Connection: close\r
            \\\r
        , .{body_len}) catch return error.OutOfMemory;
        defer self.allocator.free(header);

        // Write header + body to the stream
        try stream.writeAll(header);
        try stream.writeAll(body);
    }
};
