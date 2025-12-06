// QUIC Connection State Machine (RFC 9000)
// Manages packet number spaces, encryption levels, and connection state
// Integrates TLS 1.3 handshake over QUIC

const std = @import("std");
const types = @import("types.zig");
const varint = @import("varint.zig");
const pn_space = @import("pn_space.zig");
const constants = @import("constants.zig");
const packet = @import("packet.zig");
const crypto_keys = @import("crypto/keys.zig");
const crypto_aead = @import("crypto/aead.zig");
const crypto_hp = @import("crypto/hp.zig");
const crypto_handshake = @import("crypto/handshake.zig");
const frame_parser = @import("frame/parser.zig");
const frame_crypto = @import("frame/crypto.zig");
const connection_id = @import("connection_id.zig");
const net = std.net;

pub const ConnectionState = enum {
    idle,
    handshaking,
    established,
    closing,
    drained,
    closed,
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    state: ConnectionState,

    // Connection IDs
    local_conn_id: types.ConnectionId,
    remote_conn_id: types.ConnectionId,
    original_dcid: ?types.ConnectionId, // ODCID for Initial secret derivation

    // Packet number spaces
    initial_pn_space: pn_space.PacketNumberSpace,
    handshake_pn_space: pn_space.PacketNumberSpace,
    application_pn_space: pn_space.PacketNumberSpace,

    // Encryption levels and keys
    current_encryption_level: types.EncryptionLevel,
    initial_secrets: crypto_keys.InitialSecrets,
    handshake: crypto_handshake.Handshake,

    // AEAD contexts for each encryption level
    initial_aead_client: ?crypto_aead.Aead = null,
    initial_aead_server: ?crypto_aead.Aead = null,
    handshake_aead_client: ?crypto_aead.Aead = null,
    handshake_aead_server: ?crypto_aead.Aead = null,

    // Header protection contexts
    initial_hp_client: ?crypto_hp.Hp = null,
    initial_hp_server: ?crypto_hp.Hp = null,
    handshake_hp_client: ?crypto_hp.Hp = null,
    handshake_hp_server: ?crypto_hp.Hp = null,

    // Peer address
    peer_address: net.Address,

    /// Initialize a new connection (server-side)
    pub fn initServer(
        allocator: std.mem.Allocator,
        local_conn_id: types.ConnectionId,
        remote_conn_id: types.ConnectionId,
        peer_address: net.Address,
    ) !Connection {
        // Derive Initial secrets from ODCID (which is the remote_conn_id for first packet)
        const initial_secrets = crypto_keys.deriveInitialSecrets(remote_conn_id.slice());

        // Initialize handshake
        const handshake = try crypto_handshake.Handshake.init(allocator, initial_secrets);

        // Initialize AEAD contexts for Initial packets
        const initial_aead_client = crypto_aead.Aead{
            .key = initial_secrets.client_key,
            .iv = initial_secrets.client_iv,
            .algorithm = .aes_128_gcm,
        };

        const initial_aead_server = crypto_aead.Aead{
            .key = initial_secrets.server_key,
            .iv = initial_secrets.server_iv,
            .algorithm = .aes_128_gcm,
        };

        // Initialize header protection
        const initial_hp_client = crypto_hp.Hp{
            .key = initial_secrets.client_hp,
            .algorithm = .aes_128_ecb,
        };

        const initial_hp_server = crypto_hp.Hp{
            .key = initial_secrets.server_hp,
            .algorithm = .aes_128_ecb,
        };

        return Connection{
            .allocator = allocator,
            .state = .idle,
            .local_conn_id = local_conn_id,
            .remote_conn_id = remote_conn_id,
            .original_dcid = null,
            .initial_pn_space = pn_space.PacketNumberSpace.init(.initial),
            .handshake_pn_space = pn_space.PacketNumberSpace.init(.handshake),
            .application_pn_space = pn_space.PacketNumberSpace.init(.application),
            .current_encryption_level = .initial,
            .initial_secrets = initial_secrets,
            .handshake = handshake,
            .initial_aead_client = initial_aead_client,
            .initial_aead_server = initial_aead_server,
            .initial_hp_client = initial_hp_client,
            .initial_hp_server = initial_hp_server,
            .peer_address = peer_address,
        };
    }

    /// Get the packet number space for an encryption level
    pub fn getPacketNumberSpace(self: *Connection, level: types.EncryptionLevel) *pn_space.PacketNumberSpace {
        return switch (level) {
            .initial => &self.initial_pn_space,
            .handshake => &self.handshake_pn_space,
            .zero_rtt, .one_rtt => &self.application_pn_space,
        };
    }

    /// Store original DCID (ODCID) for Initial secret derivation
    pub fn setOriginalDcid(self: *Connection, dcid: types.ConnectionId) !void {
        if (self.original_dcid == null) {
            const dcid_copy = try self.allocator.dupe(u8, dcid.slice());
            self.original_dcid = types.ConnectionId.init(dcid_copy);
        }
    }

    /// Handle an incoming packet
    /// This is the main entry point for processing received packets
    pub fn handleIncomingPacket(self: *Connection, data: []const u8) !void {
        // Parse packet header (unprotected part)
        const parsed = try packet.Packet.parse(data, null);

        switch (parsed) {
            .long => |long_header| {
                try self.handleLongHeaderPacket(long_header, data);
            },
            .short => |short_header| {
                try self.handleShortHeaderPacket(short_header, data);
            },
        }
    }

    /// Handle a Long Header packet (Initial, Handshake, 0-RTT, Retry)
    fn handleLongHeaderPacket(self: *Connection, header: packet.LongHeader, raw_data: []const u8) !void {
        switch (header.packet_type) {
            constants.PACKET_TYPE_INITIAL => {
                try self.handleInitialPacket(header, raw_data);
            },
            constants.PACKET_TYPE_HANDSHAKE => {
                try self.handleHandshakePacket(header, raw_data);
            },
            else => {
                // TODO: Handle 0-RTT and Retry packets
                return error.UnsupportedPacketType;
            },
        }
    }

    /// Handle an Initial packet
    fn handleInitialPacket(self: *Connection, header: packet.LongHeader, raw_data: []const u8) !void {
        // Store ODCID if this is the first Initial packet
        if (self.original_dcid == null) {
            try self.setOriginalDcid(header.dest_conn_id);
        }

        // Find packet number offset
        const pn_offset = try packet.LongHeader.findPacketNumberOffset(raw_data);
        const sample_offset = pn_offset + constants.HP_SAMPLE_OFFSET;

        // Remove header protection
        var packet_copy: [65536]u8 = undefined;
        if (raw_data.len > packet_copy.len) {
            return error.PacketTooLarge;
        }
        @memcpy(packet_copy[0..raw_data.len], raw_data);

        if (self.initial_hp_client) |*hp| {
            hp.remove(packet_copy[0..raw_data.len], pn_offset, sample_offset);
        }

        // Re-parse packet with unprotected headers
        const unprotected = try packet.LongHeader.parse(packet_copy[0..raw_data.len]);

        // Decrypt payload
        const aad = packet_copy[0 .. pn_offset + unprotected.packet_number_len];
        const encrypted_payload = unprotected.payload;

        var plaintext: [65536]u8 = undefined;
        const plaintext_len = if (self.initial_aead_client) |*aead|
            try aead.decrypt(unprotected.packet_number, aad, encrypted_payload, &plaintext)
        else
            return error.NoEncryptionContext;

        // Record received packet number
        self.initial_pn_space.recordReceived(unprotected.packet_number);

        // Parse frames from decrypted payload
        const frames = try frame_parser.parseFrames(self.allocator, plaintext[0..plaintext_len]);
        defer frames.deinit();

        // Process CRYPTO frames (TLS handshake)
        for (frames.items) |frame| {
            switch (frame) {
                .crypto => |crypto_frame| {
                    try self.handshake.processCryptoFrame(
                        crypto_frame.offset,
                        crypto_frame.data,
                    );
                },
                else => {
                    // Other frames handled later
                },
            }
        }

        // If we received ClientHello, generate ServerHello
        if (self.handshake.state == .client_hello_received) {
            self.state = .handshaking;
            // ServerHello will be sent in response packet
        }
    }

    /// Handle a Handshake packet
    fn handleHandshakePacket(self: *Connection, header: packet.LongHeader, raw_data: []const u8) !void {
        _ = self;
        _ = header;
        _ = raw_data;
        // TODO: Implement Handshake packet processing (keys from handshake secrets)
    }

    /// Handle a Short Header packet (1-RTT)
    fn handleShortHeaderPacket(self: *Connection, header: packet.ShortHeader, raw_data: []const u8) !void {
        _ = self;
        _ = header;
        _ = raw_data;
        // TODO: Implement 1-RTT packet processing (application data)
    }

    /// Generate a response packet (Initial with ServerHello)
    pub fn generateResponsePacket(self: *Connection, buffer: []u8) !usize {
        if (self.handshake.state != .client_hello_received) {
            return error.InvalidHandshakeState;
        }

        // Generate ServerHello
        const server_hello = try self.handshake.generateServerHello();

        // Create CRYPTO frame with ServerHello
        const crypto_frame = frame_crypto.CryptoFrame{
            .offset = 0,
            .length = @intCast(server_hello.len),
            .data = server_hello,
        };

        // Serialize CRYPTO frame
        var frame_buffer: [4096]u8 = undefined;
        var frame_stream = std.io.fixedBufferStream(&frame_buffer);
        const frame_written = try crypto_frame.write(frame_stream.writer());
        const frame_data = frame_buffer[0..frame_written];

        // Get next packet number
        const pn = self.initial_pn_space.getNext();
        const pn_len = if (pn < 256) 1 else if (pn < 65536) 2 else if (pn < 16777216) 3 else 4;

        // Build Initial packet header
        const packet_header = packet.LongHeader{
            .packet_type = constants.PACKET_TYPE_INITIAL,
            .version = constants.VERSION_1,
            .dest_conn_id = self.remote_conn_id,
            .src_conn_id = self.local_conn_id,
            .token = &[_]u8{}, // No token in response
            .length = 0, // Will be calculated
            .packet_number = pn,
            .packet_number_len = pn_len,
            .payload = frame_data, // Will be encrypted
        };

        // Build packet (unencrypted)
        var packet_buf: [65536]u8 = undefined;
        const header_len = try packet_header.build(&packet_buf);

        // Find packet number offset
        const pn_offset = try packet.LongHeader.findPacketNumberOffset(packet_buf[0..header_len]);

        // Encrypt payload
        const aad = packet_buf[0 .. pn_offset + pn_len];
        const plaintext = frame_data;

        var encrypted_payload: [4096]u8 = undefined;
        const encrypted_len = if (self.initial_aead_server) |*aead|
            try aead.encrypt(pn, aad, plaintext, &encrypted_payload)
        else
            return error.NoEncryptionContext;

        // Update packet with encrypted payload
        @memcpy(packet_buf[header_len - frame_data.len .. header_len], encrypted_payload[0..encrypted_len]);

        // Recalculate length field
        const total_payload_len = pn_len + encrypted_len;
        const length_varint = types.VarInt{ .value = @intCast(total_payload_len) };
        var length_buf: [8]u8 = undefined;
        const length_vint_len = varint.encode(length_varint, &length_buf);
        const length_offset = pn_offset - length_vint_len;
        @memcpy(packet_buf[length_offset .. length_offset + length_vint_len], length_buf[0..length_vint_len]);

        // Apply header protection
        const sample_offset = pn_offset + constants.HP_SAMPLE_OFFSET;
        if (self.initial_hp_server) |*hp| {
            hp.apply(packet_buf[0 .. header_len - frame_data.len + encrypted_len], pn_offset, sample_offset);
        }

        // Copy to output buffer
        const final_len = header_len - frame_data.len + encrypted_len;
        if (final_len > buffer.len) {
            return error.BufferTooSmall;
        }
        @memcpy(buffer[0..final_len], packet_buf[0..final_len]);

        return final_len;
    }

    pub fn deinit(self: *Connection) void {
        self.handshake.deinit();
        if (self.original_dcid) |odcid| {
            self.allocator.free(odcid.slice());
        }
    }
};
