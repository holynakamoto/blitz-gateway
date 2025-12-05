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

                // Always process Initial packets with CRYPTO frames through handshake manager
                // The handshake manager will reassemble fragmented frames and detect ClientHello
                // Derive Initial secrets if not already done
                if (self.handshake_mgr.initial_secrets == null) {
                    try self.handshake_mgr.deriveInitialSecrets(self.quic_conn.remote_conn_id);
                }

                // Process through handshake manager (handles reassembly and ClientHello detection)
                try self.handshake_mgr.processInitialPacket(payload, @ptrCast(ssl));
                
                // Check if we have handshake output to send
                if (self.handshake_mgr.tls_ctx) |*tls_ctx| {
                    if (tls_ctx.getHandshakeOutput(.initial)) |output| {
                        std.log.info("[TLS] ServerHello generated ({} bytes)", .{output.data.len});
                    }
                }
                
                return;
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
    // This builds a complete encrypted Initial packet with ServerHello
    pub fn generateResponsePacket(
        self: *QuicServerConnection,
        packet_type: PacketType,
        buf: []u8,
    ) !usize {
        const picotls = @import("picotls.zig");
        const crypto_mod = @import("crypto.zig");
        const frames_mod = @import("frames.zig");

        // Determine encryption level
        const encryption_level = switch (packet_type) {
            .initial => picotls.EncryptionLevel.initial,
            .handshake => picotls.EncryptionLevel.handshake,
        };

        // Get handshake output from PicoTLS
        if (self.handshake_mgr.tls_ctx) |*tls_ctx| {
            const output = tls_ctx.getHandshakeOutput(encryption_level) orelse {
                std.log.info("[TLS] No handshake output for level {}", .{encryption_level});
                return 0;
            };

            std.log.info("[TLS] Building response with {} bytes of handshake data", .{output.data.len});

            // Build CRYPTO frame
            var crypto_frame_buf: [8192]u8 = undefined;
            const crypto_frame_len = try frames_mod.CryptoFrame.generate(
                output.offset,
                output.data,
                &crypto_frame_buf,
            );

            const crypto_frame_data = crypto_frame_buf[0..crypto_frame_len];

            // Derive Initial secrets (for encryption)
            if (self.handshake_mgr.initial_secrets == null) {
                std.log.err("[CRYPTO] Initial secrets not derived", .{});
                return error.NoInitialSecrets;
            }
            const secrets = self.handshake_mgr.initial_secrets.?;

            // Get packet number
            const pn = self.handshake_mgr.getNextInitialPN();
            const pn_len: usize = 1; // 1-byte packet number

            // Build packet header (unprotected)
            var header: [256]u8 = undefined;
            var header_pos: usize = 0;

            // Long header: Initial packet with 1-byte packet number
            // 0xC0 = 11000000 (long header, Initial, PN length = 1)
            header[header_pos] = 0xC0;
            header_pos += 1;

            // Version (QUIC v1 = 0x00000001)
            std.mem.writeInt(u32, header[header_pos..][0..4], 0x00000001, .big);
            header_pos += 4;

            // DCID length + DCID (client's connection ID)
            header[header_pos] = @intCast(self.quic_conn.remote_conn_id.len);
            header_pos += 1;
            @memcpy(header[header_pos..][0..self.quic_conn.remote_conn_id.len], self.quic_conn.remote_conn_id);
            header_pos += self.quic_conn.remote_conn_id.len;

            // SCID length + SCID (server's connection ID)
            header[header_pos] = @intCast(self.quic_conn.local_conn_id.len);
            header_pos += 1;
            @memcpy(header[header_pos..][0..self.quic_conn.local_conn_id.len], self.quic_conn.local_conn_id);
            header_pos += self.quic_conn.local_conn_id.len;

            // Token length (0 for server Initial)
            header_pos += writeVarInt(header[header_pos..], 0);

            // Calculate total length: PN + encrypted payload + tag
            const payload_len = crypto_frame_data.len + crypto_mod.TAG_LEN;
            const total_len = pn_len + payload_len;

            // Length field (varint) - includes PN + encrypted payload
            header_pos += writeVarInt(header[header_pos..], total_len);

            // Packet number offset (for header protection)
            const pn_offset = header_pos;

            // Packet number (1 byte)
            header[header_pos] = @intCast(pn & 0xFF);
            header_pos += pn_len;

            // AAD = header up to and including packet number
            const header_aad = header[0..header_pos];

            // Encrypt the CRYPTO frame
            var encrypted: [8192]u8 = undefined;
            const encrypted_len = try crypto_mod.encryptPayload(
                crypto_frame_data,
                &secrets.server_key, // CRITICAL: Use SERVER key for server→client
                &secrets.server_iv,
                pn,
                header_aad,
                &encrypted,
            );

            // Build complete packet
            @memcpy(buf[0..header_pos], header[0..header_pos]);
            @memcpy(buf[header_pos..][0..encrypted_len], encrypted[0..encrypted_len]);
            const packet_len = header_pos + encrypted_len;

            // Apply header protection
            try crypto_mod.applyHeaderProtection(
                buf[0..packet_len],
                &secrets.server_hp,
                pn_offset,
                pn_len,
            );

            // Mark handshake output as sent
            tls_ctx.clearOutput(encryption_level, output.data.len);

            std.log.info("[QUIC] Generated {} byte Server Initial packet", .{packet_len});

            return packet_len;
        } else {
            std.log.warn("[TLS] No TLS context available for response", .{});
            return 0;
        }
    }

    // Helper: Write variable-length integer (QUIC varint encoding)
    fn writeVarInt(buf: []u8, value: u64) usize {
        if (value < 64) {
            buf[0] = @intCast(value);
            return 1;
        } else if (value < 16384) {
            buf[0] = @intCast(0x40 | (value >> 8));
            buf[1] = @intCast(value & 0xFF);
            return 2;
        } else if (value < 1073741824) {
            buf[0] = @intCast(0x80 | (value >> 24));
            buf[1] = @intCast((value >> 16) & 0xFF);
            buf[2] = @intCast((value >> 8) & 0xFF);
            buf[3] = @intCast(value & 0xFF);
            return 4;
        } else {
            buf[0] = @intCast(0xC0 | (value >> 56));
            buf[1] = @intCast((value >> 48) & 0xFF);
            buf[2] = @intCast((value >> 40) & 0xFF);
            buf[3] = @intCast((value >> 32) & 0xFF);
            buf[4] = @intCast((value >> 24) & 0xFF);
            buf[5] = @intCast((value >> 16) & 0xFF);
            buf[6] = @intCast((value >> 8) & 0xFF);
            buf[7] = @intCast(value & 0xFF);
            return 8;
        }
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
