// Unit tests for QUIC packet generation

const std = @import("std");
const packet = @import("packet.zig");
const frames = @import("frames.zig");

test "generate INITIAL packet with CRYPTO frame" {
    const dest_conn_id = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const src_conn_id = &[_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 };

    // Generate CRYPTO frame
    const tls_data = "ClientHello TLS 1.3 handshake";
    var crypto_frame_buf: [1024]u8 = undefined;
    const crypto_frame_len = try frames.CryptoFrame.generate(0, tls_data, &crypto_frame_buf);

    // Generate INITIAL packet
    var packet_buf: [2048]u8 = undefined;
    const packet_len = try packet.generateInitialPacket(
        dest_conn_id,
        src_conn_id,
        crypto_frame_buf[0..crypto_frame_len],
        &packet_buf,
    );

    // Verify packet structure
    try std.testing.expect(packet_len > 0);
    try std.testing.expect(packet.isLongHeader(packet_buf[0]));

    // Parse it back (conn_id_len parameter only used for short headers, not long)
    const parsed = try packet.Packet.parse(packet_buf[0..packet_len], 8);
    try std.testing.expect(parsed == .long);
    try std.testing.expect(parsed.long.packet_type == packet.PACKET_TYPE_INITIAL);
    try std.testing.expect(parsed.long.version == packet.QUIC_VERSION_1);
    try std.testing.expectEqualSlices(u8, parsed.long.dest_conn_id, dest_conn_id);
    try std.testing.expectEqualSlices(u8, parsed.long.src_conn_id, src_conn_id);

    // Verify CRYPTO frame in payload
    const crypto_frame = try frames.CryptoFrame.parseFromPayload(parsed.long.payload);
    try std.testing.expectEqualSlices(u8, tls_data, crypto_frame.data);
}

test "generate HANDSHAKE packet with CRYPTO frame" {
    const dest_conn_id = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const src_conn_id = &[_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 };

    // Generate CRYPTO frame
    const tls_data = "ServerHello TLS 1.3 handshake";
    var crypto_frame_buf: [1024]u8 = undefined;
    const crypto_frame_len = try frames.CryptoFrame.generate(0, tls_data, &crypto_frame_buf);

    // Generate HANDSHAKE packet
    var packet_buf: [2048]u8 = undefined;
    const packet_len = try packet.generateHandshakePacket(
        dest_conn_id,
        src_conn_id,
        crypto_frame_buf[0..crypto_frame_len],
        &packet_buf,
    );

    // Verify packet structure
    try std.testing.expect(packet_len > 0);
    try std.testing.expect(packet.isLongHeader(packet_buf[0]));

    // Parse it back (conn_id_len parameter only used for short headers, not long)
    const parsed = try packet.Packet.parse(packet_buf[0..packet_len], 8);
    try std.testing.expect(parsed == .long);
    try std.testing.expect(parsed.long.packet_type == packet.PACKET_TYPE_HANDSHAKE);
    try std.testing.expect(parsed.long.version == packet.QUIC_VERSION_1);

    // Verify CRYPTO frame in payload
    const crypto_frame = try frames.CryptoFrame.parseFromPayload(parsed.long.payload);
    try std.testing.expectEqualSlices(u8, tls_data, crypto_frame.data);
}

test "packet generation round-trip" {
    const dest_conn_id = &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const src_conn_id = &[_]u8{ 0x11, 0x22, 0x33, 0x44 };
    const tls_data = "Test TLS handshake data";

    // Generate CRYPTO frame
    var crypto_frame_buf: [1024]u8 = undefined;
    const crypto_frame_len = try frames.CryptoFrame.generate(0, tls_data, &crypto_frame_buf);

    // Generate packet
    var packet_buf: [2048]u8 = undefined;
    const packet_len = try packet.generateInitialPacket(
        dest_conn_id,
        src_conn_id,
        crypto_frame_buf[0..crypto_frame_len],
        &packet_buf,
    );

    // Parse back (conn_id_len parameter only used for short headers, not long)
    const parsed = try packet.Packet.parse(packet_buf[0..packet_len], 8);
    try std.testing.expect(parsed == .long);

    // Extract CRYPTO frame
    const crypto_frame = try frames.CryptoFrame.parseFromPayload(parsed.long.payload);
    try std.testing.expectEqualSlices(u8, tls_data, crypto_frame.data);
}

test "packet generation error handling - buffer too small" {
    const dest_conn_id = &[_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const src_conn_id = &[_]u8{ 0x11, 0x12, 0x13, 0x14 };
    const payload = &[_]u8{ 0x06, 0x00, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F }; // CRYPTO frame

    var small_buf: [10]u8 = undefined; // Too small

    const result = packet.generateInitialPacket(dest_conn_id, src_conn_id, payload, &small_buf);
    try std.testing.expectError(error.BufferTooSmall, result);
}
