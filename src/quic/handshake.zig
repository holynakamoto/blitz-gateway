// QUIC Handshake Implementation (RFC 9000 + RFC 9001)
// Phase 1: 1-RTT handshake with TLS 1.3 integration

const std = @import("std");
const packet = @import("packet.zig");
const connection = @import("connection.zig");
// const tls = @import("../tls/tls.zig"); // Temporarily disabled for picotls migration
const frames = @import("frames.zig");

// QUIC Handshake State Machine (RFC 9000 Section 10)
pub const HandshakeState = enum {
    idle,
    client_hello_sent, // Server: received ClientHello
    server_hello_sent, // Server: sent ServerHello
    handshake_complete, // Server: sent Finished, handshake complete
    connected, // Ready for application data
    error_state, // Handshake error occurred
};

// QUIC Handshake Manager
pub const QuicHandshake = struct {
    state: HandshakeState,
    quic_conn: *connection.QuicConnection,
    tls_conn: ?*anyopaque = null, // Disabled for PicoTLS migration
    tls_conn_cleanup: ?*const fn (*anyopaque) void = null, // Optional cleanup function for tls_conn
    allocator: std.mem.Allocator,

    // Crypto stream tracking (RFC 9000 Section 7.2)
    // In QUIC, TLS handshake messages are sent over dedicated crypto streams
    initial_crypto_stream: CryptoStream,
    handshake_crypto_stream: CryptoStream,

    // Connection IDs
    local_conn_id: []u8,
    remote_conn_id: []u8,

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
    };

    pub fn init(
        allocator: std.mem.Allocator,
        quic_conn: *connection.QuicConnection,
        local_conn_id: []u8,
        remote_conn_id: []u8,
    ) QuicHandshake {
        // Initialize crypto streams
        // Initial stream: stream ID 0 (client) or 1 (server)
        // Handshake stream: stream ID 2 (client) or 3 (server)
        const initial_stream_id: u64 = 1; // Server initial crypto stream
        const handshake_stream_id: u64 = 3; // Server handshake crypto stream

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
        // Defensively clean up tls_conn if it was assigned
        if (self.tls_conn) |tls_conn| {
            if (self.tls_conn_cleanup) |cleanup_fn| {
                cleanup_fn(tls_conn);
            }
            self.tls_conn = null;
        }
        self.tls_conn_cleanup = null;
        self.initial_crypto_stream.deinit();
        self.handshake_crypto_stream.deinit();
    }

    // Process incoming INITIAL packet payload - extract and process CRYPTO frames
    // This starts the 1-RTT handshake
    pub fn processInitialPacket(
        self: *QuicHandshake,
        packet_payload: []const u8,
        ssl: ?*anyopaque, // OpenSSL SSL* type (opaque pointer)
    ) !void {
        // Extract CRYPTO frames from packet payload
        var crypto_frames = try extractCryptoFrames(packet_payload, self.allocator);
        defer crypto_frames.deinit(self.allocator);

        // Process each CRYPTO frame
        for (crypto_frames.items) |frame| {
            // Append CRYPTO frame data to initial crypto stream at correct offset
            // TODO: Handle offset properly (reassemble fragmented TLS messages)
            try self.initial_crypto_stream.append(frame.data);

            // Initialize TLS connection if not already done
            if (self.tls_conn == null and ssl != null) {
                // Create TLS connection with memory BIOs (already set up in ssl)
                // Note: In QUIC, we use a dummy fd since we use memory BIOs
                // TLS disabled for PicoTLS migration
                // const tls_conn = try tls.TlsConnection.init(ssl, -1);
                // self.tls_conn = tls_conn;
                self.state = .client_hello_sent;
            }

            // Feed CRYPTO data to TLS
            // TODO: Re-enable when PicoTLS integration is complete
            // if (self.tls_conn) |*tls_conn| {
            //     try tls_conn.feedData(frame.data);
            //     const ret = blitz_ssl_accept(tls_conn.ssl);
            //     _ = ret; // Handle errors later
            // }
            _ = self.tls_conn; // Suppress unused warning
        }
    }

    // Extract CRYPTO frames from packet payload
    fn extractCryptoFrames(payload: []const u8, allocator: std.mem.Allocator) !std.ArrayList(frames.CryptoFrame) {
        var result = std.ArrayList(frames.CryptoFrame).initCapacity(allocator, 4) catch return error.OutOfMemory;
        errdefer result.deinit(allocator);
        var offset: usize = 0;

        while (offset < payload.len) {
            // Check frame type
            if (payload[offset] == @intFromEnum(frames.FrameType.crypto)) {
                // Parse CRYPTO frame
                const frame = try frames.CryptoFrame.parseFromPayload(payload[offset..]);
                try result.append(allocator, frame);

                // Calculate frame size to advance offset
                var frame_size: usize = 1; // Frame type
                const offset_result = try readVarIntForSize(payload[offset + frame_size ..]);
                frame_size += offset_result.bytes_read;
                const length_result = try readVarIntForSize(payload[offset + frame_size ..]);
                frame_size += length_result.bytes_read;
                frame_size += @intCast(length_result.value);

                offset += frame_size;
            } else {
                // Skip other frame types for now
                // TODO: Parse other frames or skip them properly
                offset += 1;
            }
        }

        return result;
    }

    // Helper to read VarInt for size calculation only
    fn readVarIntForSize(data: []const u8) !struct { value: u64, bytes_read: usize } {
        if (data.len == 0) return error.IncompleteVarInt;
        const first_byte = data[0];
        const prefix = (first_byte & 0xC0) >> 6;

        return switch (prefix) {
            0 => .{ .value = @as(u64, first_byte & 0x3F), .bytes_read = 1 },
            1 => blk: {
                if (data.len < 2) return error.IncompleteVarInt;
                break :blk .{ .value = @as(u64, first_byte & 0x3F) << 8 | @as(u64, data[1]), .bytes_read = 2 };
            },
            2 => blk: {
                if (data.len < 4) return error.IncompleteVarInt;
                break :blk .{ .value = @as(u64, first_byte & 0x3F) << 24 | @as(u64, data[1]) << 16 | @as(u64, data[2]) << 8 | @as(u64, data[3]), .bytes_read = 4 };
            },
            3 => blk: {
                if (data.len < 8) return error.IncompleteVarInt;
                break :blk .{ .value = @as(u64, first_byte & 0x3F) << 56 | @as(u64, data[1]) << 48 | @as(u64, data[2]) << 40 | @as(u64, data[3]) << 32 | @as(u64, data[4]) << 24 | @as(u64, data[5]) << 16 | @as(u64, data[6]) << 8 | @as(u64, data[7]), .bytes_read = 8 };
            },
            else => return error.InvalidVarIntPrefix,
        };
    }

    // Generate ServerHello wrapped in CRYPTO frame
    // Returns the CRYPTO frame bytes ready to be put in a QUIC packet
    pub fn generateServerHello(self: *QuicHandshake, out_buf: []u8) !usize {
        if (self.tls_conn == null) {
            return error.NoTlsConnection;
        }

        // Get TLS handshake output from write_bio
        // TODO: Re-enable when PicoTLS integration is complete
        // const tls_conn = self.tls_conn.?;
        // if (!tls_conn.hasEncryptedOutput()) {
        //     return error.NoTlsOutput;
        // }
        // var tls_output_buf: [4096]u8 = undefined;
        // const tls_output_len = try tls_conn.getAllEncryptedOutput(&tls_output_buf);
        _ = self.tls_conn;
        _ = out_buf;
        return error.NoTlsOutput; // Temporarily disabled for PicoTLS migration
    }

    // Process HANDSHAKE packet payload - extract and process CRYPTO frames
    pub fn processHandshakePacket(
        self: *QuicHandshake,
        packet_payload: []const u8,
    ) !void {
        // Extract CRYPTO frames from packet payload
        var crypto_frames = try extractCryptoFrames(packet_payload, self.allocator);
        defer crypto_frames.deinit(self.allocator);

        // Process each CRYPTO frame
        for (crypto_frames.items) |frame| {
            // Append to handshake crypto stream at correct offset
            // TODO: Handle offset properly (reassemble fragmented TLS messages)
            try self.handshake_crypto_stream.append(frame.data);

            // Feed to TLS
            // TODO: Re-enable when PicoTLS integration is complete
            // if (self.tls_conn) |*tls_conn| {
            //     try tls_conn.feedData(frame.data);
            //     _ = blitz_ssl_accept(tls_conn.ssl);
            //     if (tls_conn.state == .connected) {
            //         self.state = .handshake_complete;
            //     }
            // }
            _ = self.tls_conn; // Suppress unused warning
        }
    }

    // Check if handshake is complete
    pub fn isComplete(self: *const QuicHandshake) bool {
        return self.state == .handshake_complete or self.state == .connected;
    }

    // Get next CRYPTO frame to send (for handshake continuation)
    // Returns the number of bytes written to out_buf
    pub fn getNextCryptoFrame(
        self: *QuicHandshake,
        stream_type: CryptoStreamType,
        out_buf: []u8,
    ) !?usize {
        // TODO: Re-enable when PicoTLS integration is complete
        // if (self.tls_conn == null) {
        //     return null;
        // }
        // const tls_conn = self.tls_conn.?;
        // if (!tls_conn.hasEncryptedOutput()) {
        //     return null;
        // }
        // var tls_output_buf: [4096]u8 = undefined;
        // const tls_output_len = try tls_conn.getAllEncryptedOutput(&tls_output_buf);
        // if (tls_output_len == 0) {
        //     return null;
        // }
        // const crypto_stream = switch (stream_type) {
        //     .initial => &self.initial_crypto_stream,
        //     .handshake => &self.handshake_crypto_stream,
        // };
        _ = self.tls_conn;
        _ = out_buf;
        _ = stream_type;
        return null; // Temporarily disabled for PicoTLS migration
    }

    pub const CryptoStreamType = enum {
        initial,
        handshake,
    };
};
