// Unit tests for QUIC frame parsing and generation

const std = @import("std");
const frames = @import("frames.zig");

test "CRYPTO frame round-trip" {
    const tls_data = "ClientHello TLS 1.3 handshake message data";
    
    // Generate CRYPTO frame
    var buf: [1024]u8 = undefined;
    const len = try frames.CryptoFrame.generate(0, tls_data, &buf);
    
    // Parse it back
    const frame = try frames.CryptoFrame.parseFromPayload(buf[0..len]);
    
    try std.testing.expectEqual(@as(u64, 0), frame.offset);
    try std.testing.expectEqual(@as(u64, tls_data.len), frame.length);
    try std.testing.expectEqualSlices(u8, tls_data, frame.data);
}

test "CRYPTO frame with non-zero offset" {
    const tls_data = "TLS handshake continuation";
    const frame_offset: u64 = 100;
    
    // Generate CRYPTO frame with offset
    var buf: [1024]u8 = undefined;
    const len = try frames.CryptoFrame.generate(frame_offset, tls_data, &buf);
    
    // Parse it back
    const frame = try frames.CryptoFrame.parseFromPayload(buf[0..len]);
    
    try std.testing.expectEqual(frame_offset, frame.offset);
    try std.testing.expectEqual(@as(u64, tls_data.len), frame.length);
    try std.testing.expectEqualSlices(u8, tls_data, frame.data);
}

test "CRYPTO frame with large offset" {
    const tls_data = "Large offset test";
    const frame_offset: u64 = 1000000; // Large offset
    
    var buf: [1024]u8 = undefined;
    const len = try frames.CryptoFrame.generate(frame_offset, tls_data, &buf);
    
    const frame = try frames.CryptoFrame.parseFromPayload(buf[0..len]);
    
    try std.testing.expectEqual(frame_offset, frame.offset);
    try std.testing.expectEqualSlices(u8, tls_data, frame.data);
}

test "CRYPTO frame parsing with frame type prefix" {
    const tls_data = "Test data";
    
    // Generate frame (includes frame type)
    var buf: [1024]u8 = undefined;
    const len = try frames.CryptoFrame.generate(0, tls_data, &buf);
    
    // Parse with frame type already in buffer
    const frame = try frames.CryptoFrame.parse(buf[0..len]);
    
    try std.testing.expectEqual(@as(u64, 0), frame.offset);
    try std.testing.expectEqualSlices(u8, tls_data, frame.data);
}

test "CRYPTO frame error handling - incomplete frame" {
    // Incomplete frame (missing data)
    const incomplete = [_]u8{ 0x06, 0x00, 0x05 }; // Frame type, offset=0, length=5, but no data
    
    const result = frames.CryptoFrame.parseFromPayload(&incomplete);
    try std.testing.expectError(error.IncompleteFrame, result);
}

test "CRYPTO frame error handling - buffer too small" {
    const tls_data = "Test";
    var small_buf: [2]u8 = undefined; // Too small
    
    const result = frames.CryptoFrame.generate(0, tls_data, &small_buf);
    try std.testing.expectError(error.BufferTooSmall, result);
}

