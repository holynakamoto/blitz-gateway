// QUIC Server Implementation
// Handles UDP packets, connection management, and handshake orchestration

const std = @import("std");
const builtin = @import("builtin");
const packet = @import("packet.zig");
const connection = @import("connection.zig");
const handshake = @import("handshake.zig");
const udp = @import("udp.zig");
// const tls = @import("../tls/tls.zig"); // Temporarily disabled for picotls migration
const frames = @import("frames.zig");

// QUIC Server Connection
pub const QuicServerConnection = struct {
    quic_conn: connection.QuicConnection,
    handshake_mgr: handshake.QuicHandshake,
    client_addr: std.net.Ip4Address,
    allocator: std.mem.Allocator,
    state: ConnectionState,

    pub const ConnectionState = enum {
        handshaking,
        connected,
        closed,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        local_conn_id: []const u8,
        remote_conn_id: []const u8,
        client_addr: std.net.Ip4Address,
    ) !QuicServerConnection {
        const local_conn_id_mut = try allocator.dupe(u8, local_conn_id);
        errdefer allocator.free(local_conn_id_mut);
        
        const remote_conn_id_mut = try allocator.dupe(u8, remote_conn_id);
        errdefer allocator.free(remote_conn_id_mut);
        
        var quic_conn = connection.QuicConnection.init(allocator, local_conn_id_mut, remote_conn_id_mut);
        const handshake_mgr = handshake.QuicHandshake.init(allocator, &quic_conn, local_conn_id_mut, remote_conn_id_mut);

        return QuicServerConnection{
            .quic_conn = quic_conn,
            .handshake_mgr = handshake_mgr,
            .client_addr = client_addr,
            .allocator = allocator,
            .state = .handshaking,
        };
    }

    pub fn deinit(self: *QuicServerConnection) void {
        self.handshake_mgr.deinit();
        self.quic_conn.deinit();
        // Free the duplicated connection IDs
        self.allocator.free(self.quic_conn.local_conn_id);
        self.allocator.free(self.quic_conn.remote_conn_id);
    }

    // Process incoming QUIC packet
    pub fn processPacket(
        self: *QuicServerConnection,
        data: []const u8,
        ssl: ?*anyopaque, // SSL* for TLS (created from SSL_CTX)
    ) !void {
        // Parse packet
        const parsed = try packet.Packet.parse(data, self.quic_conn.local_conn_id.len);

        switch (parsed) {
            .long => |long_pkt| {
                switch (long_pkt.packet_type) {
                    packet.PACKET_TYPE_INITIAL => {
                        // Extract CRYPTO frames from payload
                        // For now, assume payload contains CRYPTO frame data
                        try self.handshake_mgr.processInitialPacket(long_pkt.payload, @ptrCast(ssl));
                    },
                    packet.PACKET_TYPE_HANDSHAKE => {
                        // Process handshake packet
                        try self.handshake_mgr.processHandshakePacket(long_pkt.payload);
                    },
                    else => {
                        // Other packet types (0-RTT, RETRY)
                        return error.UnsupportedPacketType;
                    },
                }
            },
            .short => |_| {
                // Short header packets are used after handshake
                if (self.state != .connected) {
                    return error.InvalidPacketState;
                }
                // Process application data
                // TODO: Handle application data
            },
        }
    }

    /// Process already-decrypted payload (from UDP server after header protection removal)
    /// This is the correct flow: decrypt first, then process frames
    pub fn processDecryptedPayload(
        self: *QuicServerConnection,
        payload: []const u8,
        ssl: ?*anyopaque,
    ) !void {
        std.log.info("[QUIC] Processing decrypted payload ({} bytes)", .{payload.len});

        // Parse frames in decrypted payload
        var offset: usize = 0;
        while (offset < payload.len) {
            const frame_type = payload[offset];

            if (frame_type == 0x00) {
                // PADDING frame
                offset += 1;
                continue;
            } else if (frame_type == 0x06) {
                // CRYPTO frame!
                std.log.info("[FRAME] Found CRYPTO frame at offset {}", .{offset});

                // Parse CRYPTO frame
                const crypto_frame = frames.CryptoFrame.parse(payload[offset..]) catch |err| {
                    std.log.err("[FRAME] Failed to parse CRYPTO: {any}", .{err});
                    return;
                };

                std.log.info("[FRAME] CRYPTO offset={}, length={}", .{ crypto_frame.offset, crypto_frame.length });

                // Check if this is ClientHello (first byte = 0x01)
                if (crypto_frame.data.len > 0 and crypto_frame.data[0] == 0x01) {
                    std.log.info("[TLS] Found ClientHello ({} bytes)", .{crypto_frame.data.len});

                    // Process ClientHello through handshake manager
                    try self.handshake_mgr.processInitialPacket(payload, @ptrCast(ssl));
                    return;
                } else if (crypto_frame.data.len > 0) {
                    std.log.info("[TLS] CRYPTO frame content type: 0x{X:0>2}", .{crypto_frame.data[0]});
                }

                break;
            } else if (frame_type == 0x01) {
                // PING frame
                offset += 1;
                continue;
            } else if (frame_type == 0x02 or frame_type == 0x03) {
                // ACK frame - skip for now
                std.log.debug("[FRAME] ACK frame at offset {}", .{offset});
                break;
            } else {
                std.log.debug("[FRAME] Unknown frame type 0x{X:0>2} at offset {}", .{ frame_type, offset });
                break;
            }
        }
    }

    // Generate response packet (for handshake)
    // Returns the number of bytes written to buf (QUIC packet ready to send)
    pub fn generateResponsePacket(
        self: *QuicServerConnection,
        packet_type: PacketType,
        buf: []u8,
    ) !usize {
        // Generate ServerHello wrapped in CRYPTO frame
        var crypto_frame_buf: [4096]u8 = undefined;
        const crypto_frame_len = try self.handshake_mgr.generateServerHello(&crypto_frame_buf);

        // Wrap CRYPTO frame in QUIC packet
        return switch (packet_type) {
            .initial => try packet.generateInitialPacket(
                self.quic_conn.remote_conn_id,
                self.quic_conn.local_conn_id,
                crypto_frame_buf[0..crypto_frame_len],
                buf,
            ),
            .handshake => try packet.generateHandshakePacket(
                self.quic_conn.remote_conn_id,
                self.quic_conn.local_conn_id,
                crypto_frame_buf[0..crypto_frame_len],
                buf,
            ),
        };
    }

    pub const PacketType = enum {
        initial,
        handshake,
    };
};

// QUIC Server
pub const QuicServer = struct {
    udp_fd: c_int,
    connections: std.HashMap([]const u8, *QuicServerConnection, ConnectionIdContext, std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,
    ssl_ctx: ?*anyopaque = null, // SSL_CTX* for TLS (context for creating SSL connections)

    const ConnectionIdContext = struct {
        pub fn hash(self: @This(), key: []const u8) u64 {
            _ = self;
            return std.hash_map.hashString(key);
        }
        pub fn eql(self: @This(), a: []const u8, b: []const u8) bool {
            _ = self;
            return std.mem.eql(u8, a, b);
        }
    };

    pub fn init(allocator: std.mem.Allocator, port: u16) !QuicServer {
        const udp_fd = try udp.createUdpSocket(port);

        return QuicServer{
            .udp_fd = udp_fd,
            .connections = std.HashMap([]const u8, *QuicServerConnection, ConnectionIdContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QuicServer) void {
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit();
        _ = c.close(self.udp_fd);
    }

    // Process incoming UDP packet
    pub fn handlePacket(
        self: *QuicServer,
        data: []const u8,
        client_addr: std.net.Ip4Address,
    ) !void {
        // Parse packet to get connection ID
        if (data.len == 0) {
            return;
        }

        const parsed = packet.Packet.parse(data, 8) catch |err| {
            std.log.debug("Failed to parse QUIC packet: {any}", .{err});
            return;
        };

        const remote_conn_id = switch (parsed) {
            .long => |p| p.src_conn_id,
            .short => |p| p.dest_conn_id,
        };

        // Look up or create connection
        const conn = try self.getOrCreateConnection(remote_conn_id, client_addr);

        // Pass the PicoTLS context (if available) to enable TLS handshake
        try conn.processPacket(data, self.ssl_ctx);
    }

    pub fn getOrCreateConnection(
        self: *QuicServer,
        remote_conn_id: []const u8,
        client_addr: std.net.Ip4Address,
    ) !*QuicServerConnection {
        // Check if connection exists
        if (self.connections.get(remote_conn_id)) |existing| {
            return existing;
        }

        // Generate local connection ID
        var local_conn_id: [8]u8 = undefined;
        std.crypto.random.bytes(&local_conn_id);

        // Create new connection
        const conn = try self.allocator.create(QuicServerConnection);
        conn.* = try QuicServerConnection.init(
            self.allocator,
            &local_conn_id,
            remote_conn_id,
            client_addr,
        );

        // Store connection (using remote_conn_id as key)
        const conn_id_copy = try self.allocator.dupe(u8, remote_conn_id);
        try self.connections.put(conn_id_copy, conn);

        return conn;
    }
};

const c = @cImport({
    @cInclude("unistd.h");
});
