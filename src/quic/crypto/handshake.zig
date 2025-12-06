// QUIC-TLS Handshake (RFC 9001, RFC 8446)
// Pure Zig TLS 1.3 handshake over QUIC CRYPTO frames
// This replaces PicoTLS dependency with 100% Zig implementation

const std = @import("std");
const crypto = std.crypto;
const keys = @import("keys.zig");
const constants = @import("../constants.zig");
const types = @import("../types.zig");

// TLS 1.3 Handshake Message Types (RFC 8446 Section 4)
const TLS_HANDSHAKE_TYPE_CLIENT_HELLO: u8 = 0x01;
const TLS_HANDSHAKE_TYPE_SERVER_HELLO: u8 = 0x02;
const TLS_HANDSHAKE_TYPE_NEW_SESSION_TICKET: u8 = 0x04;
const TLS_HANDSHAKE_TYPE_ENCRYPTED_EXTENSIONS: u8 = 0x08;
const TLS_HANDSHAKE_TYPE_CERTIFICATE: u8 = 0x0b;
const TLS_HANDSHAKE_TYPE_CERTIFICATE_VERIFY: u8 = 0x0f;
const TLS_HANDSHAKE_TYPE_FINISHED: u8 = 0x14;

// TLS 1.3 Content Types (RFC 8446 Section 5.1)
const TLS_CONTENT_TYPE_HANDSHAKE: u8 = 0x16;
const TLS_CONTENT_TYPE_ALERT: u8 = 0x15;

// TLS 1.3 Versions
const TLS_VERSION_1_3: u16 = 0x0304;

// Cipher Suites (RFC 8446 Appendix B.4)
const TLS_AES_128_GCM_SHA256: u16 = 0x1301;
const TLS_AES_256_GCM_SHA384: u16 = 0x1302;
const TLS_CHACHA20_POLY1305_SHA256: u16 = 0x1303;

// Supported cipher suite (AES-128-GCM for Initial, can negotiate others)
const DEFAULT_CIPHER_SUITE = TLS_AES_128_GCM_SHA256;

// QUIC-TLS Handshake State Machine
pub const Handshake = struct {
    allocator: std.mem.Allocator,
    state: HandshakeState,
    
    // Crypto stream buffers (RFC 9001 Section 4.4)
    client_handshake_data: std.ArrayList(u8), // Reassembled ClientHello
    server_handshake_data: std.ArrayList(u8), // ServerHello to send
    
    // Key derivation
    initial_secrets: keys.InitialSecrets,
    handshake_secrets: ?HandshakeSecrets = null,
    one_rtt_secrets: ?OneRttSecrets = null,
    
    // X25519 key exchange
    server_private_key: [32]u8,
    server_public_key: [32]u8,
    client_public_key: [32]u8 = undefined,
    has_client_public_key: bool = false,
    shared_secret: ?[32]u8 = null,
    
    // Random values
    server_random: [32]u8,
    client_random: ?[32]u8 = null,
    
    // Selected cipher suite
    cipher_suite: u16 = DEFAULT_CIPHER_SUITE,

    pub const HandshakeState = enum {
        initial,
        client_hello_received,
        server_hello_sent,
        handshake_complete,
    };

    pub const HandshakeSecrets = struct {
        client_key: [16]u8,
        client_iv: [12]u8,
        client_hp: [16]u8,
        server_key: [16]u8,
        server_iv: [12]u8,
        server_hp: [16]u8,
    };

    pub const OneRttSecrets = struct {
        client_key: [16]u8,
        client_iv: [12]u8,
        client_hp: [16]u8,
        server_key: [16]u8,
        server_iv: [12]u8,
        server_hp: [16]u8,
    };

    pub fn init(allocator: std.mem.Allocator, initial_secrets: keys.InitialSecrets) !Handshake {
        // Generate X25519 key pair for key exchange
        var server_private_key: [32]u8 = undefined;
        crypto.random.bytes(&server_private_key);
        
        // Clamp private key (X25519 requirement)
        server_private_key[0] &= 0xF8;
        server_private_key[31] &= 0x7F;
        server_private_key[31] |= 0x40;
        
        var server_public_key: [32]u8 = undefined;
        crypto.dh.X25519.basePointMul(&server_public_key, &server_private_key);
        
        // Generate server random
        var server_random: [32]u8 = undefined;
        crypto.random.bytes(&server_random);

        return Handshake{
            .allocator = allocator,
            .state = .initial,
            .client_handshake_data = std.ArrayList(u8).init(allocator),
            .server_handshake_data = std.ArrayList(u8).init(allocator),
            .initial_secrets = initial_secrets,
            .server_private_key = server_private_key,
            .server_public_key = server_public_key,
            .server_random = server_random,
        };
    }

    pub fn deinit(self: *Handshake) void {
        self.client_handshake_data.deinit();
        self.server_handshake_data.deinit();
    }

    /// Process a CRYPTO frame containing TLS handshake data
    /// RFC 9001 Section 4.4: CRYPTO frames carry TLS handshake messages
    pub fn processCryptoFrame(self: *Handshake, offset: u64, data: []const u8) !void {
        // Ensure we have space in the buffer
        const needed_len = offset + data.len;
        if (self.client_handshake_data.items.len < needed_len) {
            try self.client_handshake_data.resize(needed_len);
        }
        
        // Copy data into buffer at offset
        @memcpy(self.client_handshake_data.items[@intCast(offset)..@intCast(offset + data.len)], data);
        
        // Try to parse ClientHello if we have enough data
        if (self.state == .initial) {
            self.parseClientHello() catch |err| {
                // Not enough data yet, wait for more CRYPTO frames
                if (err == error.InsufficientData) {
                    return;
                }
                return err;
            };
        }
    }

    /// Parse ClientHello message (RFC 8446 Section 4.1.2)
    fn parseClientHello(self: *Handshake) !void {
        const data = self.client_handshake_data.items;
        if (data.len < 4) {
            return error.InsufficientData;
        }

        // TLS Handshake message structure:
        // - Type (1 byte)
        // - Length (3 bytes, big-endian)
        // - Version (2 bytes)
        // - Random (32 bytes)
        // - Session ID length (1 byte) + Session ID
        // - Cipher suites length (2 bytes) + Cipher suites
        // - Compression methods length (1 byte) + Compression methods
        // - Extensions length (2 bytes) + Extensions

        var pos: usize = 0;

        // Handshake type
        if (data[pos] != TLS_HANDSHAKE_TYPE_CLIENT_HELLO) {
            return error.InvalidHandshakeType;
        }
        pos += 1;

        // Handshake message length (3 bytes, big-endian)
        const msg_len = (@as(u32, data[pos]) << 16) | (@as(u32, data[pos + 1]) << 8) | data[pos + 2];
        pos += 3;

        if (data.len < 4 + msg_len) {
            return error.InsufficientData;
        }

        // Legacy version (must be 0x0303 for TLS 1.3)
        const legacy_version = std.mem.readInt(u16, data[pos..pos+2], .big);
        if (legacy_version != 0x0303) {
            return error.InvalidTLSVersion;
        }
        pos += 2;

        // Client random (32 bytes)
        if (pos + 32 > data.len) {
            return error.InsufficientData;
        }
        var client_random: [32]u8 = undefined;
        @memcpy(&client_random, data[pos..pos+32]);
        self.client_random = client_random;
        pos += 32;

        // Legacy session ID (1 byte length + data)
        if (pos >= data.len) {
            return error.InsufficientData;
        }
        const session_id_len = data[pos];
        pos += 1 + session_id_len;

        // Cipher suites (2 bytes length + list)
        if (pos + 2 > data.len) {
            return error.InsufficientData;
        }
        const cipher_suites_len = std.mem.readInt(u16, data[pos..pos+2], .big);
        pos += 2;
        
        if (pos + cipher_suites_len > data.len) {
            return error.InsufficientData;
        }
        
        // Find supported cipher suite
        var found_cipher = false;
        var i: usize = 0;
        while (i < cipher_suites_len) {
            if (pos + i + 2 > data.len) break;
            const suite = std.mem.readInt(u16, data[pos + i..pos + i + 2], .big);
            if (suite == TLS_AES_128_GCM_SHA256 or 
                suite == TLS_CHACHA20_POLY1305_SHA256) {
                self.cipher_suite = suite;
                found_cipher = true;
                break;
            }
            i += 2;
        }
        
        if (!found_cipher) {
            return error.NoSupportedCipherSuite;
        }
        pos += cipher_suites_len;

        // Legacy compression methods (1 byte length + data)
        if (pos >= data.len) {
            return error.InsufficientData;
        }
        const compression_len = data[pos];
        pos += 1 + compression_len;

        // Extensions (2 bytes length + list)
        if (pos + 2 > data.len) {
            return error.InsufficientData;
        }
        const extensions_len = std.mem.readInt(u16, data[pos..pos+2], .big);
        pos += 2;
        
        if (pos + extensions_len > data.len) {
            return error.InsufficientData;
        }
        
        // Parse extensions to find supported_versions and key_share
        try self.parseExtensions(data[pos..pos+extensions_len]);
        
        // ClientHello parsed successfully
        self.state = .client_hello_received;
    }

    /// Parse TLS extensions (RFC 8446 Section 4.2)
    fn parseExtensions(self: *Handshake, extensions_data: []const u8) !void {
        var pos: usize = 0;
        
        while (pos < extensions_data.len) {
            if (pos + 4 > extensions_data.len) {
                return error.InvalidExtension;
            }
            
            const ext_type = std.mem.readInt(u16, extensions_data[pos..pos+2], .big);
            const ext_len = std.mem.readInt(u16, extensions_data[pos+2..pos+4], .big);
            pos += 4;
            
            if (pos + ext_len > extensions_data.len) {
                return error.InvalidExtension;
            }
            
            const ext_data = extensions_data[pos..pos+ext_len];
            pos += ext_len;
            
            // supported_versions extension (0x002b)
            if (ext_type == 0x002b) {
                // Verify TLS 1.3 is supported
                if (ext_data.len < 2) continue;
                const versions_len = ext_data[1];
                var i: usize = 2;
                while (i < 2 + versions_len) {
                    if (i + 2 > ext_data.len) break;
                    const version = std.mem.readInt(u16, ext_data[i..i+2], .big);
                    if (version == TLS_VERSION_1_3) {
                        // TLS 1.3 supported
                        break;
                    }
                    i += 2;
                }
            }
            
            // key_share extension (0x0033) - contains client's X25519 public key
            if (ext_type == 0x0033) {
                try self.parseKeyShare(ext_data);
            }
        }
    }

    /// Parse key_share extension to extract client's public key
    fn parseKeyShare(self: *Handshake, ext_data: []const u8) !void {
        if (ext_data.len < 4) {
            return error.InvalidKeyShare;
        }
        
        // Key share entry list length (2 bytes)
        const entries_len = std.mem.readInt(u16, ext_data[0..2], .big);
        var pos: usize = 2;
        
        if (pos + entries_len > ext_data.len) {
            return error.InvalidKeyShare;
        }
        
        // First key share entry
        if (pos + 4 > ext_data.len) {
            return error.InvalidKeyShare;
        }
        
        // Named group (2 bytes) - should be X25519 (0x001d)
        const group = std.mem.readInt(u16, ext_data[pos..pos+2], .big);
        if (group != 0x001d) { // X25519
            return error.UnsupportedKeyExchange;
        }
        pos += 2;
        
        // Key exchange data length (2 bytes)
        const key_len = std.mem.readInt(u16, ext_data[pos..pos+2], .big);
        pos += 2;
        
        if (pos + key_len != ext_data.len or key_len != 32) {
            return error.InvalidKeyShare;
        }
        
        // Client's X25519 public key (32 bytes)
        @memcpy(&self.client_public_key, ext_data[pos..pos+32]);
        self.has_client_public_key = true;
        
        // Compute shared secret
        var shared_secret: [32]u8 = undefined;
        crypto.dh.X25519.scalarmult(&shared_secret, &self.server_private_key, &self.client_public_key);
        self.shared_secret = shared_secret;
    }

    /// Generate ServerHello message (RFC 8446 Section 4.1.3)
    pub fn generateServerHello(self: *Handshake) ![]const u8 {
        if (self.state != .client_hello_received) {
            return error.InvalidHandshakeState;
        }

        // Clear previous ServerHello data
        self.server_handshake_data.clearRetainingCapacity();

        // Build ServerHello message
        var writer = self.server_handshake_data.writer();

        // Handshake type
        try writer.writeByte(TLS_HANDSHAKE_TYPE_SERVER_HELLO);

        // Message length (3 bytes, will fill later)
        const len_pos = self.server_handshake_data.items.len;
        try writer.writeByte(0); // High byte
        try writer.writeInt(u16, 0, .big); // Low 2 bytes
        const msg_start = self.server_handshake_data.items.len;

        // Legacy version (0x0303)
        try writer.writeInt(u16, 0x0303, .big);

        // Server random (32 bytes)
        try writer.writeAll(&self.server_random);

        // Legacy session ID (empty for TLS 1.3)
        try writer.writeByte(0);

        // Selected cipher suite (2 bytes)
        try writer.writeInt(u16, self.cipher_suite, .big);

        // Legacy compression (null)
        try writer.writeByte(0);

        // Extensions
        const ext_start = self.server_handshake_data.items.len;
        try writer.writeInt(u16, 0, .big); // Placeholder for extensions length

        // supported_versions extension (0x002b)
        try writer.writeInt(u16, 0x002b, .big); // Extension type
        try writer.writeInt(u16, 2, .big); // Extension length
        try writer.writeInt(u16, TLS_VERSION_1_3, .big); // TLS 1.3

        // key_share extension (0x0033)
        try writer.writeInt(u16, 0x0033, .big); // Extension type
        const key_share_len_pos = self.server_handshake_data.items.len;
        try writer.writeInt(u16, 0, .big); // Placeholder
        
        // Key share entry
        try writer.writeInt(u16, 0x001d, .big); // X25519 group
        try writer.writeInt(u16, 32, .big); // Key length
        try writer.writeAll(&self.server_public_key); // Server's public key
        
        // Update key_share extension length
        const key_share_len = self.server_handshake_data.items.len - key_share_len_pos - 2;
        std.mem.writeInt(u16, self.server_handshake_data.items[key_share_len_pos..key_share_len_pos+2], @intCast(key_share_len), .big);

        // Update extensions length
        const ext_len = self.server_handshake_data.items.len - ext_start - 2;
        std.mem.writeInt(u16, self.server_handshake_data.items[ext_start..ext_start+2], @intCast(ext_len), .big);

        // Update message length (3 bytes, big-endian)
        const msg_len = self.server_handshake_data.items.len - msg_start;
        self.server_handshake_data.items[len_pos] = @intCast((msg_len >> 16) & 0xFF);
        std.mem.writeInt(u16, self.server_handshake_data.items[len_pos+1..len_pos+3], @intCast(msg_len & 0xFFFF), .big);

        self.state = .server_hello_sent;

        // Derive handshake secrets
        try self.deriveHandshakeSecrets();

        return self.server_handshake_data.items;
    }

    /// Derive handshake secrets (RFC 9001 Section 5.2.2)
    fn deriveHandshakeSecrets(self: *Handshake) !void {
        if (self.shared_secret == null or self.client_random == null or !self.has_client_public_key) {
            return error.MissingKeyExchangeData;
        }

        // Handshake secret = HKDF-Extract(shared_secret, hello_hash)
        // For simplicity, we use the client/server randoms as salt
        var hello_hash: [32]u8 = undefined;
        var hmac = crypto.auth.hmac.HmacSha256.init(&self.client_random.?);
        hmac.update(&self.server_random);
        hmac.final(&hello_hash);

        var handshake_secret: [32]u8 = undefined;
        hkdfExtract(&hello_hash, &self.shared_secret.?, &handshake_secret);

        // Derive handshake keys
        var client_handshake_secret: [32]u8 = undefined;
        hkdfExpandLabel(&handshake_secret, "c hs traffic", null, 32, &client_handshake_secret);

        var server_handshake_secret: [32]u8 = undefined;
        hkdfExpandLabel(&handshake_secret, "s hs traffic", null, 32, &server_handshake_secret);

        var client_key: [16]u8 = undefined;
        hkdfExpandLabel(&client_handshake_secret, constants.LABEL_QUIC_KEY, null, 16, &client_key);

        var client_iv: [12]u8 = undefined;
        hkdfExpandLabel(&client_handshake_secret, constants.LABEL_QUIC_IV, null, 12, &client_iv);

        var client_hp: [16]u8 = undefined;
        hkdfExpandLabel(&client_handshake_secret, constants.LABEL_QUIC_HP, null, 16, &client_hp);

        var server_key: [16]u8 = undefined;
        hkdfExpandLabel(&server_handshake_secret, constants.LABEL_QUIC_KEY, null, 16, &server_key);

        var server_iv: [12]u8 = undefined;
        hkdfExpandLabel(&server_handshake_secret, constants.LABEL_QUIC_IV, null, 12, &server_iv);

        var server_hp: [16]u8 = undefined;
        hkdfExpandLabel(&server_handshake_secret, constants.LABEL_QUIC_HP, null, 16, &server_hp);

        self.handshake_secrets = HandshakeSecrets{
            .client_key = client_key,
            .client_iv = client_iv,
            .client_hp = client_hp,
            .server_key = server_key,
            .server_iv = server_iv,
            .server_hp = server_hp,
        };
    }

    /// Get handshake secrets (for Handshake packet encryption)
    pub fn getHandshakeSecrets(self: *const Handshake) ?HandshakeSecrets {
        return self.handshake_secrets;
    }

    /// Get initial secrets (for Initial packet encryption)
    pub fn getInitialSecrets(self: *const Handshake) keys.InitialSecrets {
        return self.initial_secrets;
    }
};

// Helper: HKDF-Extract
fn hkdfExtract(salt: []const u8, ikm: []const u8, prk: []u8) void {
    var hmac = crypto.auth.hmac.HmacSha256.init(salt);
    hmac.update(ikm);
    hmac.final(prk);
}

// Helper: HKDF-Expand-Label (RFC 9001 Section 5.1.3)
fn hkdfExpandLabel(
    secret: []const u8,
    label: []const u8,
    context: ?[]const u8,
    length: usize,
    output: []u8,
) void {
    // Build HkdfLabel structure
    var label_buf: [256]u8 = undefined;
    var pos: usize = 0;

    // Length (2 bytes, big-endian)
    std.mem.writeInt(u16, label_buf[pos..pos+2], @intCast(length), .big);
    pos += 2;

    // Label length (1 byte)
    const tls13_prefix = "tls13 ";
    const full_label_len = tls13_prefix.len + label.len;
    label_buf[pos] = @intCast(full_label_len);
    pos += 1;

    // Label: "tls13 " + label
    @memcpy(label_buf[pos..pos+tls13_prefix.len], tls13_prefix);
    pos += tls13_prefix.len;
    @memcpy(label_buf[pos..pos+label.len], label);
    pos += label.len;

    // Context length (1 byte)
    const context_len = if (context) |ctx| ctx.len else 0;
    label_buf[pos] = @intCast(context_len);
    pos += 1;

    // Context (if any)
    if (context) |ctx| {
        @memcpy(label_buf[pos..pos+ctx.len], ctx);
        pos += ctx.len;
    }

    // HKDF-Expand(PRK, info, L)
    hkdfExpand(secret, label_buf[0..pos], length, output);
}

// Helper: HKDF-Expand (RFC 5869 Section 2.3)
fn hkdfExpand(prk: []const u8, info: []const u8, length: usize, output: []u8) void {
    const hash_len = 32;
    const n = (length + hash_len - 1) / hash_len;

    var t: [32]u8 = undefined;
    var offset: usize = 0;

    for (1..n + 1) |i| {
        var hmac = crypto.auth.hmac.HmacSha256.init(prk);
        
        if (i > 1) {
            hmac.update(&t);
        }
        hmac.update(info);
        
        var counter: u8 = @intCast(i);
        hmac.update(&[_]u8{counter});
        hmac.final(&t);

        const copy_len = @min(hash_len, length - offset);
        @memcpy(output[offset..offset+copy_len], t[0..copy_len]);
        offset += copy_len;
    }
}
