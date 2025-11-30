// Simple packet generation test to debug structure

const std = @import("std");
const packet = @import("packet.zig");

test "simple INITIAL packet generation" {
    const dest_conn_id = &[_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const src_conn_id = &[_]u8{ 0x11, 0x12, 0x13, 0x14 };
    const payload = &[_]u8{ 0x06, 0x00, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F }; // Simple CRYPTO frame
    
    var packet_buf: [1024]u8 = undefined;
    const packet_len = try packet.generateInitialPacket(
        dest_conn_id,
        src_conn_id,
        payload,
        &packet_buf,
    );
    
    std.debug.print("Generated packet length: {}\n", .{packet_len});
    std.debug.print("First 30 bytes: {any}\n", .{packet_buf[0..@min(30, packet_len)]});
    
    // Verify structure manually
    try std.testing.expect(packet_buf[0] == 0x80); // Long header + INITIAL
    try std.testing.expect(packet_buf[5] == 4); // DCID len
    try std.testing.expect(packet_buf[10] == 4); // SCID len (after 1+4+1+4)
    try std.testing.expect(packet_buf[15] == 0); // Token len byte 1
    try std.testing.expect(packet_buf[16] == 0); // Token len byte 2
    
    // Payload length
    const payload_len = std.mem.readInt(u16, packet_buf[17..][0..2], .big);
    std.debug.print("Payload length field: {}\n", .{payload_len});
    std.debug.print("Actual payload length: {}\n", .{payload.len});
    try std.testing.expect(payload_len == payload.len);
    
    // Try parsing
    const parsed = packet.Packet.parse(packet_buf[0..packet_len], 8) catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        std.debug.print("Packet structure:\n", .{});
        std.debug.print("  Header: 0x{X}\n", .{packet_buf[0]});
        std.debug.print("  Version: 0x{X}\n", .{std.mem.readInt(u32, packet_buf[1..][0..4], .big)});
        std.debug.print("  DCID len: {}\n", .{packet_buf[5]});
        std.debug.print("  SCID len: {}\n", .{packet_buf[10]});
        std.debug.print("  Token len: {}\n", .{std.mem.readInt(u16, packet_buf[15..][0..2], .big)});
        std.debug.print("  Payload len: {}\n", .{payload_len});
        std.debug.print("  Total packet: {}\n", .{packet_len});
        return err;
    };
    
    try std.testing.expect(parsed == .long);
    std.debug.print("Parsed successfully!\n", .{});
}

