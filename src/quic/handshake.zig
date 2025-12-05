// QUIC Handshake Implementation (RFC 9000 + RFC 9001)
// Phase 1: 1-RTT handshake with TLS 1.3 integration via PicoTLS

const std = @import("std");
const packet = @import("packet.zig");
const connection = @import("connection.zig");
const frames = @import("frames.zig");
const picotls = @import("picotls.zig");
const crypto = @import("crypto.zig");

// QUIC Handshake State Machine (RFC 9000 Section 10)
pub const HandshakeState = enum {
    idle,
    client_hello_received, // Server: received ClientHello
    server_hello_sent, // Server: sent ServerHello
    handshake_sent, // Server: sent encrypted handshake
    handshake_complete, // Server: received client Finished
    connected, // Ready for application data
    error_state, // Handshake error occurred
};

// QUIC Handshake Manager - integrates TLS 1.3 with QUIC
pub const QuicHandshake = struct {
    state: HandshakeState,
    quic_conn: *connection.QuicConnection,
    allocator: std.mem.Allocator,

    // TLS context (PicoTLS)
    tls_ctx: ?picotls.TlsContext = null,

    // Crypto stream tracking (RFC 9000 Section 7.2)
    initial_crypto_stream: CryptoStream,
    handshake_crypto_stream: CryptoStream,

    // Connection IDs
    local_conn_id: []u8,
    remote_conn_id: []u8,

    // Initial secrets (derived from DCID)
    initial_secrets: ?crypto.InitialSecrets = null,

    // Packet numbers
    initial_pn: u32 = 0,
    handshake_pn: u32 = 0,

    pub const CryptoStream = struct {
        stream_id: u64,
        offset: u64 = 0,
        data: std.ArrayList(u8),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, stream_id: u64) CryptoStream {
            return CryptoStream{
                .stream_id = stream_id,
                .allocator = allocator,
                .data = std.ArrayList(u8).initCapacity(allocator, 1024) catch @panic("Failed to init crypto stream"),
            };
        }

        pub fn deinit(self: *CryptoStream) void {
            self.data.deinit(self.allocator);
        }

        pub fn append(self: *CryptoStream, data: []const u8) !void {
            try self.data.appendSlice(self.allocator, data);
        }

        pub fn getData(self: *const CryptoStream) []const u8 {
            return self.data.items;
        }

        pub fn clear(self: *CryptoStream) void {
            self.data.clearRetainingCapacity();
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        quic_conn: *connection.QuicConnection,
        local_conn_id: []u8,
        remote_conn_id: []u8,
    ) QuicHandshake {
        const initial_stream_id: u64 = 1;
        const handshake_stream_id: u64 = 3;

        return QuicHandshake{
            .state = .idle,
            .quic_conn = quic_conn,
            .allocator = allocator,
            .initial_crypto_stream = CryptoStream.init(allocator, initial_stream_id),
            .handshake_crypto_stream = CryptoStream.init(allocator, handshake_stream_id),
            .local_conn_id = local_conn_id,
            .remote_conn_id = remote_conn_id,
        };
    }

    pub fn deinit(self: *QuicHandshake) void {
        if (self.tls_ctx) |*tls| {
            tls.deinit();
        }
        self.initial_crypto_stream.deinit();
        self.handshake_crypto_stream.deinit();
    }

    /// Derive Initial secrets from DCID
    pub fn deriveInitialSecrets(self: *QuicHandshake, dcid: []const u8) !void {
        self.initial_secrets = try crypto.deriveInitialSecrets(dcid);
    }

    /// Process incoming INITIAL packet payload
    /// Extracts CRYPTO frames and feeds them to TLS
    /// ptls_ctx is the global PicoTLS context (initialized with certs)
    pub fn processInitialPacket(self: *QuicHandshake, packet_payload: []const u8, ptls_ctx: ?*anyopaque) !void {
        // Extract CRYPTO frames from packet payload
        var crypto_frames = try extractCryptoFrames(packet_payload, self.allocator);
        defer crypto_frames.deinit(self.allocator);

        // Process each CRYPTO frame
        for (crypto_frames.items) |frame| {
            // Append to crypto stream (handles reassembly)
            try self.initial_crypto_stream.append(frame.data);
        }

        // Initialize TLS context if needed
        if (self.tls_ctx == null) {
            self.tls_ctx = try picotls.TlsContext.init(self.allocator);
        }

        // Feed accumulated crypto data to TLS
        const crypto_data = self.initial_crypto_stream.getData();
        if (crypto_data.len > 0) {
            // ═══════════════════════════════════════════════════════════════
            // THIS IS THE CALL - FINAL FORM
            // Feed ClientHello to PicoTLS and generate ServerHello
            // ═══════════════════════════════════════════════════════════════
            if (self.tls_ctx) |*tls| {
                if (ptls_ctx) |ctx| {
                    // Create server TLS connection if not exists
                    try tls.newServerConnection(@ptrCast(ctx));
                }
                
                // THE CALL: Feed ClientHello, get ServerHello + handshake
                const complete = tls.feedClientHello(crypto_data) catch |err| {
                    std.log.err("[TLS] feedClientHello failed: {}", .{err});
                    self.state = .error_state;
                    return err;
                };

                if (complete) {
                    self.state = .handshake_complete;
                    std.log.info("[TLS] Handshake complete!", .{});
                } else {
                    self.state = .server_hello_sent;
                    std.log.info("[TLS] ServerHello sent, waiting for client Finished", .{});
                }

                // Clear processed crypto data
                self.initial_crypto_stream.clear();
            } else {
                self.state = .client_hello_received;
            }
        }
    }

    /// Generate ServerHello response (Initial packet CRYPTO frame)
    pub fn generateServerHello(self: *QuicHandshake, out_buf: []u8) !usize {
        // If we have TLS output, use it
        if (self.tls_ctx) |*tls| {
            if (tls.getHandshakeOutput(.initial)) |output| {
                return buildCryptoFrame(output.data, output.offset, out_buf);
            }
        }

        // If no TLS output yet but we received ClientHello, send ACK frame
        // This proves the server is processing packets and responding
        if (self.state == .client_hello_received or self.state == .server_hello_sent) {
            // Build a minimal ACK frame (frame type 0x02)
            // ACK frame: type(1) + largest_acked(varint) + delay(varint) + range_count(varint) + first_range(varint)
            if (out_buf.len < 10) return error.BufferTooSmall;

            out_buf[0] = 0x02; // ACK frame type
            out_buf[1] = 0x00; // Largest Acknowledged = 0 (varint)
            out_buf[2] = 0x00; // ACK Delay = 0 (varint)
            out_buf[3] = 0x00; // ACK Range Count = 0 (varint)
            out_buf[4] = 0x00; // First ACK Range = 0 (varint)

            std.log.info("[QUIC] Sending ACK frame (TLS handshake in progress)", .{});
            return 5;
        }

        return 0;
    }

    /// Generate Handshake response (encrypted extensions, cert, finished)
    pub fn generateHandshakeResponse(self: *QuicHandshake, out_buf: []u8) !usize {
        if (self.tls_ctx == null) return error.NoTlsConnection;

        if (self.tls_ctx.?.getHandshakeOutput(.handshake)) |output| {
            return buildCryptoFrame(output.data, output.offset, out_buf);
        }

        return 0;
    }

    /// Process HANDSHAKE packet payload
    pub fn processHandshakePacket(self: *QuicHandshake, packet_payload: []const u8) !void {
        var crypto_frames = try extractCryptoFrames(packet_payload, self.allocator);
        defer crypto_frames.deinit(self.allocator);

        for (crypto_frames.items) |frame| {
            try self.handshake_crypto_stream.append(frame.data);
        }

        // Check if handshake complete
        if (self.tls_ctx) |*tls| {
            if (tls.isHandshakeComplete()) {
                self.state = .handshake_complete;
            }
        }
    }

    /// Check if handshake is complete
    pub fn isComplete(self: *const QuicHandshake) bool {
        return self.state == .handshake_complete or self.state == .connected;
    }

    /// Get next packet number for Initial packets
    pub fn getNextInitialPN(self: *QuicHandshake) u32 {
        const pn = self.initial_pn;
        self.initial_pn += 1;
        return pn;
    }

    /// Get next packet number for Handshake packets
    pub fn getNextHandshakePN(self: *QuicHandshake) u32 {
        const pn = self.handshake_pn;
        self.handshake_pn += 1;
        return pn;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// Build a CRYPTO frame from TLS data
    fn buildCryptoFrame(data: []const u8, offset: u64, out: []u8) !usize {
        if (out.len < 3 + data.len) return error.BufferTooSmall;

        var pos: usize = 0;

        // Frame type (0x06 = CRYPTO)
        out[pos] = 0x06;
        pos += 1;

        // Offset (variable-length integer)
        pos += writeVarInt(offset, out[pos..]);

        // Length (variable-length integer)
        pos += writeVarInt(data.len, out[pos..]);

        // Data
        @memcpy(out[pos..][0..data.len], data);
        pos += data.len;

        return pos;
    }

    /// Write a variable-length integer (RFC 9000)
    fn writeVarInt(value: u64, out: []u8) usize {
        if (value < 64) {
            out[0] = @intCast(value);
            return 1;
        } else if (value < 16384) {
            out[0] = @intCast((value >> 8) | 0x40);
            out[1] = @intCast(value & 0xFF);
            return 2;
        } else if (value < 1073741824) {
            out[0] = @intCast((value >> 24) | 0x80);
            out[1] = @intCast((value >> 16) & 0xFF);
            out[2] = @intCast((value >> 8) & 0xFF);
            out[3] = @intCast(value & 0xFF);
            return 4;
        } else {
            out[0] = @intCast((value >> 56) | 0xC0);
            out[1] = @intCast((value >> 48) & 0xFF);
            out[2] = @intCast((value >> 40) & 0xFF);
            out[3] = @intCast((value >> 32) & 0xFF);
            out[4] = @intCast((value >> 24) & 0xFF);
            out[5] = @intCast((value >> 16) & 0xFF);
            out[6] = @intCast((value >> 8) & 0xFF);
            out[7] = @intCast(value & 0xFF);
            return 8;
        }
    }

    /// Extract CRYPTO frames from packet payload
    fn extractCryptoFrames(payload: []const u8, allocator: std.mem.Allocator) !std.ArrayList(frames.CryptoFrame) {
        var result = std.ArrayList(frames.CryptoFrame).initCapacity(allocator, 4) catch return error.OutOfMemory;
        errdefer result.deinit(allocator);
        var offset: usize = 0;

        while (offset < payload.len) {
            if (payload[offset] == @intFromEnum(frames.FrameType.crypto)) {
                const frame = try frames.CryptoFrame.parseFromPayload(payload[offset..]);
                try result.append(allocator, frame);

                // Calculate frame size
                var frame_size: usize = 1;
                const offset_result = try readVarInt(payload[offset + frame_size ..]);
                frame_size += offset_result.bytes_read;
                const length_result = try readVarInt(payload[offset + frame_size ..]);
                frame_size += length_result.bytes_read;
                frame_size += @intCast(length_result.value);

                offset += frame_size;
            } else if (payload[offset] == 0x00) {
                // PADDING frame
                offset += 1;
            } else if (payload[offset] == 0x01) {
                // PING frame
                offset += 1;
            } else {
                // Skip unknown frame
                offset += 1;
            }
        }

        return result;
    }

    fn readVarInt(data: []const u8) !struct { value: u64, bytes_read: usize } {
        if (data.len == 0) return error.IncompleteVarInt;
        const first_byte = data[0];
        const prefix = (first_byte & 0xC0) >> 6;

        return switch (prefix) {
            0 => .{ .value = @as(u64, first_byte & 0x3F), .bytes_read = 1 },
            1 => blk: {
                if (data.len < 2) return error.IncompleteVarInt;
                break :blk .{
                    .value = @as(u64, first_byte & 0x3F) << 8 | @as(u64, data[1]),
                    .bytes_read = 2,
                };
            },
            2 => blk: {
                if (data.len < 4) return error.IncompleteVarInt;
                break :blk .{
                    .value = @as(u64, first_byte & 0x3F) << 24 |
                        @as(u64, data[1]) << 16 |
                        @as(u64, data[2]) << 8 |
                        @as(u64, data[3]),
                    .bytes_read = 4,
                };
            },
            3 => blk: {
                if (data.len < 8) return error.IncompleteVarInt;
                break :blk .{
                    .value = @as(u64, first_byte & 0x3F) << 56 |
                        @as(u64, data[1]) << 48 |
                        @as(u64, data[2]) << 40 |
                        @as(u64, data[3]) << 32 |
                        @as(u64, data[4]) << 24 |
                        @as(u64, data[5]) << 16 |
                        @as(u64, data[6]) << 8 |
                        @as(u64, data[7]),
                    .bytes_read = 8,
                };
            },
            else => return error.InvalidVarIntPrefix,
        };
    }

    pub const CryptoStreamType = enum {
        initial,
        handshake,
    };

    // Legacy compatibility
    pub fn getNextCryptoFrame(self: *QuicHandshake, stream_type: CryptoStreamType, out_buf: []u8) !?usize {
        return switch (stream_type) {
            .initial => self.generateServerHello(out_buf) catch null,
            .handshake => self.generateHandshakeResponse(out_buf) catch null,
        };
    }
};
