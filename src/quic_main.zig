// Standalone QUIC Server for Testing
// Run with: zig build run-quic

const std = @import("std");
const builtin = @import("builtin");
const io_uring = @import("io_uring.zig");
const udp_server = @import("quic/udp_server.zig");

pub fn main() !void {
    _ = std.heap.GeneralPurposeAllocator(.{});
    
    std.debug.print("Blitz QUIC Server v0.1.0\n", .{});
    std.debug.print("Starting QUIC server on UDP port 8443...\n", .{});
    
    // Initialize io_uring (required for UDP server)
    if (builtin.os.tag != .linux) {
        std.log.err("QUIC server requires Linux (io_uring)", .{});
        return error.UnsupportedPlatform;
    }
    
    try io_uring.init();
    defer io_uring.deinit();
    
    // Run QUIC server (this blocks)
    try udp_server.runQuicServer(&io_uring.ring, 8443);
}

