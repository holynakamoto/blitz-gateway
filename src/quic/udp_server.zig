// QUIC UDP Server - Production Integration
// Thin UDP layer that routes packets to connections
// Uses pure Zig std library - no C dependencies

const std = @import("std");
const os = std.os;
const net = std.net;
const constants = @import("constants.zig");
const server_mod = @import("server.zig");

/// High-performance QUIC UDP server
pub const UdpServer = struct {
    socket: os.socket_t,
    server: server_mod.Server,
    allocator: std.mem.Allocator,
    recv_buffer: [65536]u8, // Max QUIC packet size

    pub fn init(allocator: std.mem.Allocator, port: u16) !UdpServer {
        // Create UDP socket
        const sock = try os.socket(os.AF.INET, os.SOCK.DGRAM, 0);
        errdefer os.closeSocket(sock);

        // Set socket options
        const reuse: c_int = 1;
        try os.setsockopt(sock, os.SOL.SOCKET, os.SO.REUSEADDR, std.mem.asBytes(&reuse));

        // Bind to port
        const addr = try net.Address.parseIp4("0.0.0.0", port);
        try os.bind(sock, &addr.any, addr.getOsSockLen());

        // Initialize QUIC server
        const server = try server_mod.Server.init(allocator);

        return UdpServer{
            .socket = sock,
            .server = server,
            .allocator = allocator,
            .recv_buffer = undefined,
        };
    }

    pub fn deinit(self: *UdpServer) void {
        self.server.deinit();
        os.closeSocket(self.socket);
    }

    /// Run the server (blocking)
    pub fn run(self: *UdpServer) !void {
        std.log.info("QUIC server listening on UDP port", .{});

        var client_addr: os.sockaddr = undefined;
        var addr_len: os.socklen_t = @sizeOf(os.sockaddr);

        while (true) {
            // Receive UDP packet
            const n = try os.recvfrom(
                self.socket,
                &self.recv_buffer,
                0,
                &client_addr,
                &addr_len,
            );

            if (n == 0) continue;

            const packet_data = self.recv_buffer[0..n];

            // Parse peer address
            const peer = net.Address{ .in = @bitCast(client_addr.in) };

            // Quick parse to get DCID (for connection lookup)
            const dcid = try self.extractDcid(packet_data);

            // Get or create connection
            const conn = try self.server.getOrCreateConnection(dcid, peer);

            // Handle packet
            conn.handleIncomingPacket(packet_data) catch |err| {
                std.log.warn("Error handling packet from {any}: {any}", .{ peer, err });
                // Remove connection on error
                self.server.removeConnection(dcid);
                continue;
            };

            // Generate response if handshake is in progress
            if (conn.state == .handshaking) {
                var response_buffer: [65536]u8 = undefined;
                const response_len = conn.generateResponsePacket(&response_buffer) catch |err| {
                    std.log.warn("Error generating response: {any}", .{err});
                    continue;
                };

                // Send response
                _ = try os.sendto(
                    self.socket,
                    response_buffer[0..response_len],
                    0,
                    &client_addr,
                    addr_len,
                );

                std.log.info("Sent ServerHello response ({} bytes)", .{response_len});
            }
        }
    }

    /// Extract DCID from packet (fast path for connection lookup)
    fn extractDcid(self: *UdpServer, data: []const u8) ![]const u8 {
        _ = self;

        if (data.len < 7) {
            return error.PacketTooShort;
        }

        const first_byte = data[0];
        const is_long_header = (first_byte & constants.LONG_HEADER_BIT) != 0;

        if (is_long_header) {
            // Long header: DCID is at offset 5 (after version)
            if (data.len < 6) {
                return error.InsufficientData;
            }
            const dcid_len = data[5];
            if (dcid_len > constants.MAX_CONNECTION_ID_LEN or data.len < 6 + dcid_len) {
                return error.InvalidConnectionIdLength;
            }
            return data[6 .. 6 + dcid_len];
        } else {
            // Short header: DCID starts at offset 1
            // For short headers, we need to know the DCID length from connection state
            // For now, assume 8 bytes (common default)
            if (data.len < 9) {
                return error.InsufficientData;
            }
            return data[1..9];
        }
    }
};

/// Run QUIC server on specified port
pub fn runQuicServer(port: u16) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try UdpServer.init(allocator, port);
    defer server.deinit();

    try server.run();
}
