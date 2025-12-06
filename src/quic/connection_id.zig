// Connection ID Management (RFC 9000 Section 5.1)
// Production-grade CID generation and validation

const std = @import("std");
const types = @import("types.zig");
const crypto = std.crypto;
const constants = @import("constants.zig");

/// Generate a random connection ID of specified length
/// RFC 9000 Section 5.1: Connection IDs are 0-20 bytes
pub fn generateConnectionId(len: u8) types.ConnectionId {
    if (len == 0) {
        return types.ConnectionId.init(&[_]u8{});
    }
    if (len > constants.MAX_CONNECTION_ID_LEN) {
        @panic("Connection ID length exceeds maximum");
    }

    var data: [20]u8 = undefined;
    crypto.random.bytes(data[0..len]);

    return types.ConnectionId.init(data[0..len]);
}

/// Generate a random connection ID with default length (8 bytes)
/// This is a common default for QUIC implementations
pub fn generateDefaultConnectionId() types.ConnectionId {
    return generateConnectionId(8);
}

/// Create a connection ID from bytes
pub fn fromBytes(data: []const u8) types.ConnectionId {
    return types.ConnectionId.init(data);
}

/// Validate connection ID length
pub fn isValidLength(len: usize) bool {
    return len <= constants.MAX_CONNECTION_ID_LEN;
}

// Test helpers
test "connection id generation" {
    const cid1 = generateConnectionId(8);
    try std.testing.expectEqual(@as(u8, 8), cid1.len);
    
    const cid2 = generateConnectionId(20);
    try std.testing.expectEqual(@as(u8, 20), cid2.len);
    
    const cid3 = generateDefaultConnectionId();
    try std.testing.expectEqual(@as(u8, 8), cid3.len);
}

test "connection id from bytes" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const cid = fromBytes(&data);
    try std.testing.expectEqual(@as(u8, 8), cid.len);
    try std.testing.expectEqualSlices(u8, &data, cid.slice());
}

