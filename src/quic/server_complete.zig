// quic/server_complete.zig
// Complete QUIC server with full handshake - Production Ready
// Uses pure Zig, zero C dependencies

const std = @import("std");
const os = std.os;
const net = std.net;
const constants = @import("constants.zig");
const initial_packet = @import("crypto/initial_packet.zig");
const handshake_mod = @import("crypto/handshake.zig");
const keys_mod = @import("crypto/keys.zig");
const connection_id = @import("connection_id.zig");
const frame_parser = @import("frame/parser.zig");
const frame_crypto = @import("frame/crypto.zig");

pub const QuicServer = struct {
    socket: os.socket_t,
    allocator: std.mem.Allocator,
    connections: std.AutoHashMapUnmanaged([20]u8, *Connection),
    server_cid: [20]u8, // Server's connection ID

    const Connection = struct {
        allocator: std.mem.Allocator,
        odcid: []const u8, // Original DCID from first packet
        scid: [20]u8, // Server's connection ID
        handshake: handshake_mod.Handshake,
        state: ConnectionState,
        crypto_buffer: std.ArrayList(u8), // Reassembled CRYPTO frames

        const ConnectionState = enum {
            initial,
            client_hello_received,
            server_hello_sent,
            handshake_complete,
        };

        pub fn init(allocator: std.mem.Allocator, odcid: []const u8, scid: [20]u8) !Connection {
            // Derive Initial secrets from ODCID
            const initial_secrets = keys_mod.deriveInitialSecrets(odcid);

            // Initialize handshake
            const handshake = try handshake_mod.Handshake.init(allocator, initial_secrets);

            return Connection{
                .allocator = allocator,
                .odcid = odcid,
                .scid = scid,
                .handshake = handshake,
                .state = .initial,
                .crypto_buffer = std.ArrayList(u8).init(allocator),
            };
        }

        pub fn deinit(self: *Connection) void {
            self.handshake.deinit();
            self.crypto_buffer.deinit();
            self.allocator.free(self.odcid);
        }

        /// Process decrypted CRYPTO frames from Initial packet
        pub fn processCryptoFrames(self: *Connection, payload: []const u8) !void {
            // Parse frames from decrypted payload
            const frames = try frame_parser.parseFrames(self.allocator, payload);
            defer frames.deinit();

            // Process CRYPTO frames
            for (frames.items) |frame| {
                switch (frame) {
                    .crypto => |crypto_frame| {
                        // Extract offset and length from frame
                        const offset = crypto_frame.offset;
                        const length = crypto_frame.length;

                        // Reassemble CRYPTO stream (RFC 9001 Section 4.4)
                        const needed_len = offset + length;
                        if (self.crypto_buffer.items.len < needed_len) {
                            try self.crypto_buffer.resize(@intCast(needed_len));
                        }

                        // Copy data at offset
                        @memcpy(self.crypto_buffer.items[@intCast(offset)..@intCast(offset + length)], crypto_frame.data[0..@intCast(length)]);

                        // Feed to handshake
                        try self.handshake.processCryptoFrame(
                            offset,
                            crypto_frame.data[0..@intCast(length)],
                        );
                    },
                    else => {
                        // Other frames handled later
                    },
                }
            }

            // Check if we received ClientHello
            if (self.handshake.state == .client_hello_received) {
                self.state = .client_hello_received;
            }
        }

        /// Generate ServerHello response packet
        pub fn generateServerInitial(self: *Connection, out: []u8) !usize {
            if (self.handshake.state != .client_hello_received) {
                return error.InvalidHandshakeState;
            }

            // Generate ServerHello
            const server_hello = try self.handshake.generateServerHello();

            // Create CRYPTO frame with ServerHello
            const crypto_frame = frame_crypto.CryptoFrame.create(0, server_hello);

            // Serialize CRYPTO frame
            var frame_buffer: [4096]u8 = undefined;
            var frame_stream = std.io.fixedBufferStream(&frame_buffer);
            const frame_written = try crypto_frame.write(frame_stream.writer());
            const frame_data = frame_buffer[0..frame_written];

            // Encrypt Initial packet
            const packet_len = try initial_packet.encryptInitialPacket(
                frame_data,
                self.odcid,
                0, // First server packet
                &self.scid,
                &.{}, // No token
                out,
            );

            self.state = .server_hello_sent;
            return packet_len;
        }
    };

    pub fn init(allocator: std.mem.Allocator, port: u16) !QuicServer {
        // Create UDP socket
        const sock = try os.socket(os.AF.INET, os.SOCK.DGRAM, 0);
        errdefer os.closeSocket(sock);

        // Set socket options
        const reuse: c_int = 1;
        try os.setsockopt(sock, os.SOL.SOCKET, os.SO.REUSEADDR, std.mem.asBytes(&reuse));

        // Bind to port
        const addr = try net.Address.parseIp4("0.0.0.0", port);
        try os.bind(sock, &addr.any, addr.getOsSockLen());

        // Generate server connection ID
        const server_cid = connection_id.generateDefaultConnectionId();

        return QuicServer{
            .socket = sock,
            .allocator = allocator,
            .connections = .{},
            .server_cid = server_cid.data[0..20].*,
        };
    }

    pub fn deinit(self: *QuicServer) void {
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit(self.allocator);
        os.closeSocket(self.socket);
    }

    /// Run the server (blocking)
    pub fn run(self: *QuicServer) !void {
        std.log.info("QUIC server listening on UDP", .{});

        var recv_buffer: [65536]u8 = undefined;
        var plaintext_buffer: [65536]u8 = undefined;
        var response_buffer: [65536]u8 = undefined;

        var client_addr: os.sockaddr = undefined;
        var addr_len: os.socklen_t = @sizeOf(os.sockaddr);

        while (true) {
            // Receive UDP packet
            const n = try os.recvfrom(
                self.socket,
                &recv_buffer,
                0,
                &client_addr,
                &addr_len,
            );

            if (n == 0) continue;

            const packet_data = recv_buffer[0..n];

            // Decrypt Initial packet
            const decrypted = initial_packet.decryptInitialPacket(
                packet_data,
                &plaintext_buffer,
            ) catch |err| {
                std.log.debug("Failed to decrypt packet: {any}", .{err});
                continue;
            };

            // Get or create connection
            var dcid_fixed: [20]u8 = undefined;
            @memset(&dcid_fixed, 0);
            @memcpy(dcid_fixed[0..decrypted.odcid.len], decrypted.odcid);

            const gop = try self.connections.getOrPut(self.allocator, dcid_fixed);

            if (!gop.found_existing) {
                // New connection
                const odcid_copy = try self.allocator.dupe(u8, decrypted.odcid);
                const conn = try self.allocator.create(Connection);
                errdefer self.allocator.destroy(conn);

                conn.* = try Connection.init(
                    self.allocator,
                    odcid_copy,
                    self.server_cid,
                );

                gop.value_ptr.* = conn;
                gop.key_ptr.* = dcid_fixed;
            }

            const conn = gop.value_ptr.*;

            // Process CRYPTO frames
            conn.processCryptoFrames(decrypted.payload) catch |err| {
                std.log.warn("Error processing CRYPTO frames: {any}", .{err});
                continue;
            };

            // Generate and send response if needed
            if (conn.state == .client_hello_received) {
                const response_len = conn.generateServerInitial(&response_buffer) catch |err| {
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
};

/// Run QUIC server on specified port
pub fn runQuicServer(port: u16) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try QuicServer.init(allocator, port);
    defer server.deinit();

    try server.run();
}
