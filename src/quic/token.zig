// Retry Token and NEW_TOKEN (RFC 9000 Section 8.1, 19.7)
// Stateless retry token generation and validation

const std = @import("std");
const crypto = std.crypto;

pub const Token = struct {
    data: []const u8,

    /// Generate a retry token (server-side)
    /// RFC 9000 Section 8.1: Retry tokens allow servers to validate client addresses
    /// 
    /// For production, this should include:
    /// - Client IP address (encrypted)
    /// - Timestamp (to prevent replay)
    /// - Server secret (HMAC)
    /// 
    /// For now, we generate a random token. Full implementation would use
    /// AES-GCM encryption with server secret key.
    pub fn generateRetryToken(allocator: std.mem.Allocator, client_addr: []const u8) !Token {
        _ = client_addr; // TODO: Include in token for validation
        
        // Generate 16-byte random token
        var token_data: [16]u8 = undefined;
        crypto.random.bytes(&token_data);
        
        const data = try allocator.dupe(u8, &token_data);
        return Token{ .data = data };
    }

    /// Validate a retry token (server-side)
    /// Returns true if token is valid and not expired
    /// 
    /// Full implementation would:
    /// 1. Decrypt token with server secret
    /// 2. Verify HMAC
    /// 3. Check timestamp (reject if > 10 seconds old)
    /// 4. Verify client IP matches token
    pub fn validate(self: *const Token, client_addr: []const u8) bool {
        _ = client_addr; // TODO: Validate against token contents
        
        // Basic validation: token must be non-empty
        return self.data.len > 0;
    }

    /// Check if token is empty (no token present)
    pub fn isEmpty(self: *const Token) bool {
        return self.data.len == 0;
    }

    pub fn deinit(self: *Token, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Create an empty token (no retry token)
pub fn emptyToken() Token {
    return Token{ .data = &[_]u8{} };
}

// Test helpers
test "retry token generation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const client_addr = "192.168.1.1";
    const token = try Token.generateRetryToken(allocator, client_addr);
    defer token.deinit(allocator);

    try std.testing.expect(token.data.len > 0);
    try std.testing.expect(!token.isEmpty());
}

test "empty token" {
    const token = emptyToken();
    try std.testing.expect(token.isEmpty());
}

