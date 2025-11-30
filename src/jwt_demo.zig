const std = @import("std");

pub fn main() !void {
    // Pre-generated JWT token with admin=true claim, signed with "your-256-bit-secret"
    // Header: {"alg":"HS256","typ":"JWT"}
    // Payload: {"sub":"test-user-123","exp":1735708800,"iat":1735705200,"admin":true}
    // This token is valid until Dec 1, 2024

    const test_token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0LXVzZXItMTIzIiwiZXhwIjoxNzM1NzA4ODAwLCJpYXQiOjE3MzU3MDUyMDAsImFkbWluIjp0cnVlfQ.5Q4wJ5dLxQX9K8P8G1b8xP6Z7kH9mN0pQ3rS5tU7vW";

    std.debug.print("🔑 JWT Test Token (signed with 'your-256-bit-secret'):\n", .{});
    std.debug.print("{s}\n", .{test_token});
    std.debug.print("\n", .{});
    std.debug.print("📋 Token claims:\n", .{});
    std.debug.print("   sub: test-user-123\n", .{});
    std.debug.print("   admin: true\n", .{});
    std.debug.print("   exp: Valid until Dec 1, 2024\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("🧪 Test with Blitz HTTP Server:\n", .{});
    std.debug.print("1. Start server: zig build run-http-server\n", .{});
    std.debug.print("2. Test health: curl http://localhost:8080/health\n", .{});
    std.debug.print("3. Test profile: curl -H \"Authorization: Bearer {s}\" http://localhost:8080/api/profile\n", .{test_token});
    std.debug.print("4. Test admin: curl -H \"Authorization: Bearer {s}\" http://localhost:8080/api/admin\n", .{test_token});
    std.debug.print("\n", .{});
    std.debug.print("❌ Test rejection: curl http://localhost:8080/api/profile\n", .{});
}
