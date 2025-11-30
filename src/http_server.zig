//! HTTP/1.1 Server with JWT Authentication Middleware
//! Demonstrates JWT authentication integration

const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const http = @import("http/parser.zig");
const jwt = @import("jwt.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("🔐 Blitz HTTP Server with JWT Authentication\n", .{});
    std.debug.print("==========================================\n", .{});

    // Create JWT validator configuration
    var jwt_config = jwt.ValidatorConfig.init(allocator);
    defer jwt_config.deinit(allocator);

    // Configure JWT validation - use the same secret as the test token
    jwt_config.algorithm = .HS256;
    jwt_config.secret = try allocator.dupe(u8, "your-256-bit-secret"); // This is the secret used to sign the test token
    jwt_config.issuer = try allocator.dupe(u8, "blitz-gateway");
    jwt_config.audience = try allocator.dupe(u8, "blitz-api");

    // Create JWT validator
    var jwt_validator = jwt.Validator.init(allocator, jwt_config);
    defer jwt_validator.deinit();

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

    std.debug.print("🔑 JWT Configuration:\n", .{});
    std.debug.print("   Algorithm: HS256\n", .{});
    std.debug.print("   Secret: your-256-bit-secret\n", .{});
    std.debug.print("   Expected issuer: blitz-gateway\n", .{});
    std.debug.print("   Expected audience: blitz-api\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("📋 Test endpoints:\n", .{});
    std.debug.print("   GET  /health        - No auth required\n", .{});
    std.debug.print("   GET  /api/profile   - Requires valid JWT token\n", .{});
    std.debug.print("   GET  /api/admin     - Requires JWT token with admin=true claim\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("🧪 Test commands:\n", .{});
    std.debug.print("   curl http://localhost:8080/health\n", .{});
    std.debug.print("   curl -H \"Authorization: Bearer [JWT_TOKEN]\" http://localhost:8080/api/profile\n", .{});
    std.debug.print("   curl -H \"Authorization: Bearer [JWT_TOKEN]\" http://localhost:8080/api/admin\n", .{});
    std.debug.print("   (Get JWT_TOKEN from: zig run src/jwt_demo.zig)\n", .{});

    // Accept connections
    while (true) {
        const conn = try server.accept();
        defer conn.stream.close();

        std.debug.print("[CONN] New connection from {any}\n", .{conn.address});

        // Handle connection in a separate thread or coroutine
        try handleConnection(allocator, conn.stream, &jwt_validator);
    }
}

fn handleConnection(allocator: std.mem.Allocator, stream: net.Stream, jwt_validator: *jwt.Validator) !void {
    var buffer: [8192]u8 = undefined;

    // Read HTTP request
    const bytes_read = try stream.read(&buffer);
    if (bytes_read == 0) return;

    const request_data = buffer[0..bytes_read];

    // Parse HTTP request (simplified)
    const request_str = std.mem.sliceTo(request_data, 0);
    var request_lines = std.mem.splitSequence(u8, request_str, "\r\n");

    // Parse request line
    const request_line = request_lines.next() orelse return;
    var request_parts = std.mem.splitSequence(u8, request_line, " ");
    const method = request_parts.next() orelse return;
    const path = request_parts.next() orelse return;

    // Parse headers
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    while (request_lines.next()) |line| {
        if (line.len == 0) break; // End of headers
        if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
            const name = std.mem.trim(u8, line[0..colon_pos], &std.ascii.whitespace);
            const value = std.mem.trim(u8, line[colon_pos + 1 ..], &std.ascii.whitespace);
            try headers.put(name, value);
        }
    }

    // Handle request with JWT authentication
    try handleSimpleRequest(allocator, method, path, &headers, &jwt_validator, stream);
}

fn handleSimpleRequest(allocator: std.mem.Allocator, _: []const u8, path: []const u8, headers: *std.StringHashMap([]const u8), jwt_validator: *jwt.Validator, stream: net.Stream) !void {
    var status_code: u16 = 200;
    var response_body: []const u8 = "";
    var allocated_response: ?[]u8 = null;

    // Check if authentication is required
    const requires_auth = !std.mem.eql(u8, path, "/health");

    var authenticated = false;
    var user_claims: ?jwt.Token = null;
    if (requires_auth) {
        // Extract Authorization header
        const auth_header = headers.get("authorization") orelse headers.get("Authorization");
        if (auth_header) |auth| {
            if (std.mem.startsWith(u8, auth, "Bearer ")) {
                const token_str = std.mem.trim(u8, auth["Bearer ".len..], &std.ascii.whitespace);
                // Use full JWT validation
                user_claims = jwt_validator.validateToken(token_str) catch null;
                if (user_claims != null) {
                    authenticated = true;
                }
            }
        }

        if (!authenticated) {
            status_code = 401;
            response_body = "{\"error\":\"Unauthorized\",\"message\":\"Valid JWT token required\"}";
        }
    }

    defer if (user_claims) |*claims| allocator.free(claims.signature);

    if (status_code == 200) {
        if (std.mem.eql(u8, path, "/health")) {
            response_body = "{\"status\":\"healthy\",\"server\":\"blitz-jwt\"}";
        } else if (std.mem.eql(u8, path, "/api/profile")) {
            if (user_claims) |claims| {
                // Use actual JWT claims - sub is the user ID
                const user_id = claims.payload.sub orelse "unknown";
                // Check if admin claim exists (boolean true in the test token)
                const is_admin = if (claims.payload.custom_claims.get("admin")) |admin_claim| {
                    admin_claim == .Bool and admin_claim.Bool == true;
                } else false;

                allocated_response = std.fmt.allocPrint(allocator, "{{\"user_id\":\"{s}\",\"profile\":{{\"name\":\"John Doe\",\"email\":\"john@example.com\"}},\"authenticated\":true,\"is_admin\":{}}}", .{ user_id, is_admin }) catch null;
                if (allocated_response) |resp| {
                    response_body = resp;
                } else {
                    response_body = "{\"error\":\"Internal server error\"}";
                }
            } else {
                response_body = "{\"error\":\"Authentication required\"}";
            }
        } else if (std.mem.eql(u8, path, "/api/admin")) {
            // Check for admin claim in JWT
            var is_admin = false;
            if (user_claims) |claims| {
                if (claims.payload.custom_claims.get("admin")) |admin_claim| {
                    is_admin = admin_claim == .Bool and admin_claim.Bool == true;
                }
            }

            if (!is_admin) {
                status_code = 403;
                response_body = "{\"error\":\"Forbidden\",\"message\":\"Admin role required\"}";
            } else {
                response_body = "{\"message\":\"Admin access granted\",\"secret\":\"This is confidential information\"}";
            }
        } else {
            status_code = 404;
            response_body = "{\"error\":\"Not found\"}";
        }
    }

    // Send HTTP response
    try sendHttpResponseSimple(stream, status_code, "application/json", response_body);

    // Clean up allocated response
    if (allocated_response) |resp| {
        allocator.free(resp);
    }
}

fn sendHttpResponseSimple(stream: net.Stream, status_code: u16, content_type: []const u8, body: []const u8) !void {
    const status_text = switch (status_code) {
        200 => "OK",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        500 => "Internal Server Error",
        else => "Unknown",
    };

    var response_buf: [2048]u8 = undefined;
    var response_len: usize = 0;

    // Write status line
    const status_line = try std.fmt.bufPrint(response_buf[response_len..], "HTTP/1.1 {d} {s}\r\n", .{ status_code, status_text });
    response_len += status_line.len;

    // Write headers
    const content_type_header = try std.fmt.bufPrint(response_buf[response_len..], "Content-Type: {s}\r\n", .{content_type});
    response_len += content_type_header.len;

    const content_length_header = try std.fmt.bufPrint(response_buf[response_len..], "Content-Length: {}\r\n\r\n", .{body.len});
    response_len += content_length_header.len;

    // Copy body
    @memcpy(response_buf[response_len .. response_len + body.len], body);
    response_len += body.len;

    // Send response
    _ = try stream.write(response_buf[0..response_len]);
}
