// Minimal QUIC Server for Docker Testing
// This is a simplified version to verify Docker setup works

const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    std.debug.print("Blitz QUIC Server v0.1.0 (Minimal)\n", .{});
    std.debug.print("Starting QUIC server on UDP port 8443...\n", .{});

    if (builtin.os.tag != .linux) {
        std.log.err("QUIC server requires Linux", .{});
        return error.UnsupportedPlatform;
    }

    // Simple UDP socket setup
    const sockfd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch |err| {
        std.log.err("Failed to create socket: {}", .{err});
        return err;
    };
    defer std.posix.close(sockfd);

    // Bind to port 8443
    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 8443);
    std.posix.bind(sockfd, &addr.any, addr.getOsSockLen()) catch |err| {
        std.log.err("Failed to bind to port 8443: {}", .{err});
        return err;
    };

    std.debug.print("✅ QUIC server listening on UDP port 8443\n", .{});
    std.debug.print("Waiting for packets...\n", .{});

    // Simple receive loop
    var buf: [1500]u8 = undefined;
    var packets_received: u64 = 0;

    while (true) {
        var src_addr: std.posix.sockaddr = undefined;
        var src_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        const bytes = std.posix.recvfrom(sockfd, &buf, 0, &src_addr, &src_len) catch |err| {
            std.log.warn("recvfrom error: {}", .{err});
            continue;
        };

        packets_received += 1;
        std.debug.print("Received {} bytes (total packets: {})\n", .{ bytes, packets_received });

        // Simple echo response for testing
        _ = std.posix.sendto(sockfd, buf[0..bytes], 0, &src_addr, src_len) catch {};
    }
}
