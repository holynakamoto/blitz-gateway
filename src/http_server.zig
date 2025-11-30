//! HTTP/1.1 Server with JWT Authentication Middleware
//! Demonstrates JWT authentication integration

const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const http = @import("http/parser.zig");
const middleware = @import("middleware.zig");
const jwt = @import("jwt.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("🔐 Blitz HTTP Server with JWT Authentication\n", .{});
    std.debug.print("==========================================\n", .{});

    // Create JWT validator configuration
    var jwt_config = jwt.ValidatorConfig.init(allocator);
    defer jwt_config.deinit(allocator);

    // Configure JWT validation
    jwt_config.algorithm = .HS256;
    jwt_config.secret = try allocator.dupe(u8, "your-super-secret-jwt-key-change-this-in-production");
    jwt_config.issuer = try allocator.dupe(u8, "blitz-gateway");
    jwt_config.audience = try allocator.dupe(u8, "blitz-api");

    // Create JWT authentication middleware
    var jwt_auth = try middleware.JWTAuthMiddleware.init(allocator, jwt_config);
    defer jwt_auth.deinit();

    // Create middleware chain
    var chain = middleware.MiddlewareChain.init(allocator);
    defer chain.deinit();

    // Add middleware to chain
    try chain.use(middleware.corsMiddleware);
    try chain.use(middleware.loggingMiddleware);
    try chain.use(jwt_auth.handler());
    try chain.use(middleware.requireRole("user"));
    try chain.use(requestHandler);

    // Start HTTP server
    const address = try net.Address.parseIp("127.0.0.1", 8080);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("🚀 Server listening on http://127.0.0.1:8080\n", .{});
    std.debug.print("📝 Test endpoints:\n", .{});
    std.debug.print("   GET  /health        - Health check (no auth required)\n", .{});
    std.debug.print("   GET  /api/profile   - Protected endpoint (requires JWT)\n", .{});
    std.debug.print("   POST /api/data      - Protected endpoint (requires JWT)\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("🔑 Sample JWT token (expires in 1 hour):\n", .{});

    // Generate a sample JWT token for testing
    var creator = jwt.Creator.init(allocator);
    defer creator.deinit();

    var header = jwt.Header{ .alg = .HS256 };
    var payload = jwt.Payload.init(allocator);
    defer payload.deinit(allocator);

    payload.iss = try allocator.dupe(u8, "blitz-gateway");
    payload.sub = try allocator.dupe(u8, "user123");
    payload.aud = try allocator.dupe(u8, "blitz-api");
    payload.exp = std.time.timestamp() + 3600; // 1 hour from now
    payload.iat = std.time.timestamp();

    // Add custom claims
    var roles_claim = std.json.Value{ .Array = std.json.Array.initCapacity(allocator, 2) };
    roles_claim.Array.appendAssumeCapacity(.{ .String = try allocator.dupe(u8, "user") });
    roles_claim.Array.appendAssumeCapacity(.{ .String = try allocator.dupe(u8, "admin") });

    try payload.custom_claims.put(try allocator.dupe(u8, "roles"), roles_claim);
    try payload.custom_claims.put(try allocator.dupe(u8, "department"), .{ .String = try allocator.dupe(u8, "engineering") });

    const sample_token = try creator.createToken(header, payload, jwt_config.secret.?);
    defer allocator.free(sample_token);

    std.debug.print("   {s}\n", .{sample_token});
    std.debug.print("\n", .{});
    std.debug.print("📋 Use in curl:\n", .{});
    std.debug.print("   curl -H \"Authorization: Bearer {s}\" http://localhost:8080/api/profile\n", .{sample_token});
    std.debug.print("\n", .{});

    // Accept connections
    while (true) {
        const conn = try server.accept();
        defer conn.stream.close();

        std.debug.print("[CONN] New connection from {any}\n", .{conn.address});

        // Handle connection in a separate thread or coroutine
        try handleConnection(allocator, conn.stream, &chain);
    }
}

fn handleConnection(allocator: std.mem.Allocator, stream: net.Stream, chain: *middleware.MiddlewareChain) !void {
    var buffer: [8192]u8 = undefined;

    // Read HTTP request
    const bytes_read = try stream.read(&buffer);
    if (bytes_read == 0) return;

    const request_data = buffer[0..bytes_read];

    // Parse HTTP request
    var request = try http.parseRequest(request_data);
    defer request.deinit();

    // Convert headers to hashmap for middleware
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = headers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        headers.deinit();
    }

    for (request.headers) |header| {
        const name_copy = try allocator.dupe(u8, header.name);
        const value_copy = try allocator.dupe(u8, header.value);
        try headers.put(name_copy, value_copy);
    }

    // Create middleware contexts
    var req_ctx = middleware.RequestContext.init(allocator, @tagName(request.method), request.path, &headers);
    defer req_ctx.deinit();

    req_ctx.body = request.body;
    req_ctx.remote_addr = "127.0.0.1"; // In real implementation, get from connection

    var res_ctx = middleware.ResponseContext.init(allocator);
    defer res_ctx.deinit();

    // Process through middleware chain
    chain.process(&req_ctx, &res_ctx) catch |err| {
        std.debug.print("[ERROR] Middleware processing failed: {}\n", .{err});

        res_ctx.setStatus(500);
        res_ctx.json(.{
            .error = "Internal Server Error",
            .message = "Request processing failed",
        }) catch {};
    };

    // Send HTTP response
    try sendHttpResponse(stream, &res_ctx);
}

fn sendHttpResponse(stream: net.Stream, res: *middleware.ResponseContext) !void {
    // Status line
    const status_text = switch (res.status_code) {
        200 => "OK",
        201 => "Created",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        500 => "Internal Server Error",
        else => "Unknown",
    };

    try stream.writer().print("HTTP/1.1 {} {}\r\n", .{ res.status_code, status_text });

    // Headers
    var it = res.headers.iterator();
    while (it.next()) |entry| {
        try stream.writer().print("{}: {}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    // Content-Length header
    try stream.writer().print("Content-Length: {}\r\n", .{res.body.items.len});

    // End of headers
    try stream.writer().print("\r\n", .{});

    // Body
    _ = try stream.write(res.body.items);
}

fn requestHandler(req: *middleware.RequestContext, res: *middleware.ResponseContext) !middleware.MiddlewareResult {
    // Route requests
    if (std.mem.eql(u8, req.path, "/health")) {
        try res.json(.{
            .status = "healthy",
            .timestamp = std.time.timestamp(),
        });
    } else if (std.mem.eql(u8, req.path, "/api/profile")) {
        if (!req.isAuthenticated()) {
            res.setStatus(401);
            try res.json(.{ .error = "Authentication required" });
            return .respond;
        }

        const user_id = req.getUserId() orelse "unknown";
        try res.json(.{
            .user_id = user_id,
            .profile = .{
                .name = "John Doe",
                .email = "john@example.com",
            },
            .authenticated = true,
        });
    } else if (std.mem.eql(u8, req.path, "/api/data") and std.mem.eql(u8, req.method, "POST")) {
        if (!req.isAuthenticated()) {
            res.setStatus(401);
            try res.json(.{ .error = "Authentication required" });
            return .respond;
        }

        try res.json(.{
            .message = "Data received successfully",
            .method = req.method,
            .timestamp = std.time.timestamp(),
        });
    } else if (std.mem.eql(u8, req.path, "/api/admin")) {
        if (!req.hasRole("admin")) {
            res.setStatus(403);
            try res.json(.{ .error = "Admin role required" });
            return .respond;
        }

        try res.json(.{
            .message = "Admin access granted",
            .secret_data = "This is confidential information",
        });
    } else {
        res.setStatus(404);
        try res.json(.{ .error = "Not found" });
    }

    return .respond;
}
