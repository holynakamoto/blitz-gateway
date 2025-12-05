// PicoTLS bindings for QUIC TLS 1.3 handshake (MINICRYPTO - NO OPENSSL)
//
// picotls is specifically designed for QUIC - it outputs raw handshake messages
// at the correct encryption level, not TLS records!
//
// Uses ptls_minicrypto_* backend for pure static builds without OpenSSL.

const std = @import("std");
const builtin = @import("builtin");

// PicoTLS with minicrypto backend (NO OpenSSL)
const c = @cImport({
    @cInclude("picotls.h");
    @cInclude("picotls/minicrypto.h");
});

// Encryption levels (matching QUIC epochs)
pub const EncryptionLevel = enum(usize) {
    initial = 0, // PTLS_EPOCH_INITIAL
    early_data = 1, // PTLS_EPOCH_0RTT
    handshake = 2, // PTLS_EPOCH_HANDSHAKE
    application = 3, // PTLS_EPOCH_1RTT
};

// Handshake output at a specific encryption level
pub const HandshakeOutput = struct {
    level: EncryptionLevel,
    data: []const u8,
    offset: u64, // CRYPTO frame offset for this data
};

// TLS Context for QUIC connections (minicrypto backend)
// Currently stubbed - will be fully implemented when wiring TLS handshake
pub const TlsContext = struct {
    initialized: bool = false,
    handshake_complete: bool = false,

    // Traffic secrets after handshake
    client_traffic_secret: ?[32]u8 = null,
    server_traffic_secret: ?[32]u8 = null,

    /// Initialize TLS context with certificate and key
    /// For static builds, uses minicrypto backend
    pub fn init(allocator: std.mem.Allocator, cert_path: []const u8, key_path: []const u8) !TlsContext {
        _ = allocator;
        _ = cert_path;
        _ = key_path;

        // TODO: Load certificate using minicrypto
        // For now, return stub context
        return TlsContext{
            .initialized = true,
        };
    }

    /// Create a new TLS connection (server side)
    pub fn newConnection(self: *TlsContext) !void {
        if (!self.initialized) return error.NotInitialized;
        // TODO: Create ptls_t with minicrypto cipher suites
    }

    /// Handle incoming ClientHello
    pub fn handleClientHello(self: *TlsContext, client_hello: []const u8) !void {
        _ = self;
        _ = client_hello;
        // TODO: Feed ClientHello to ptls_handle_message
        // This will generate ServerHello + EncryptedExtensions + Certificate + CertificateVerify + Finished
    }

    /// Get handshake output for a specific encryption level
    pub fn getHandshakeOutput(self: *TlsContext, level: EncryptionLevel) ?HandshakeOutput {
        _ = self;
        _ = level;
        // TODO: Return pending handshake data for this level
        return null;
    }

    /// Receive handshake data from peer (e.g., client Finished)
    pub fn receiveHandshake(self: *TlsContext, data: []const u8, level: EncryptionLevel) !bool {
        _ = self;
        _ = data;
        _ = level;
        // TODO: Feed data to ptls_handle_message
        // Returns true if handshake is complete
        return false;
    }

    /// Check if TLS handshake is complete
    pub fn isHandshakeComplete(self: *TlsContext) bool {
        return self.handshake_complete;
    }

    /// Get traffic secrets after handshake completion
    pub fn getTrafficSecrets(self: *TlsContext, level: EncryptionLevel) ?struct { client: []const u8, server: []const u8 } {
        _ = level;
        if (!self.handshake_complete) return null;

        if (self.client_traffic_secret) |*client| {
            if (self.server_traffic_secret) |*server| {
                return .{
                    .client = client,
                    .server = server,
                };
            }
        }
        return null;
    }

    /// Clean up TLS context
    pub fn deinit(self: *TlsContext) void {
        self.initialized = false;
        self.handshake_complete = false;
        self.client_traffic_secret = null;
        self.server_traffic_secret = null;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// MINICRYPTO CIPHER SUITES
// These are available without OpenSSL
// ═══════════════════════════════════════════════════════════════════════════════

/// Get minicrypto AES-128-GCM-SHA256 cipher suite
pub fn getAes128GcmSha256() ?*const c.ptls_cipher_suite_t {
    // ptls_minicrypto_aes128gcmsha256 is the cipher suite for QUIC
    return &c.ptls_minicrypto_aes128gcmsha256;
}

/// Get minicrypto SHA256 hash algorithm
pub fn getSha256() *const c.ptls_hash_algorithm_t {
    return &c.ptls_minicrypto_sha256;
}

/// Get minicrypto X25519 key exchange
pub fn getX25519() *const c.ptls_key_exchange_algorithm_t {
    return &c.ptls_minicrypto_x25519;
}

// ═══════════════════════════════════════════════════════════════════════════════
// HKDF USING MINICRYPTO
// ═══════════════════════════════════════════════════════════════════════════════

/// HKDF-Expand-Label using picotls minicrypto
pub fn hkdfExpandLabel(
    secret: []const u8,
    label: []const u8,
    context: []const u8,
    out: []u8,
) !void {
    const hash_algo = &c.ptls_minicrypto_sha256;

    // Build "tls13 " prefix
    var full_label_buf: [64]u8 = undefined;
    const prefix = "tls13 ";

    if (prefix.len + label.len > full_label_buf.len)
        return error.LabelTooLarge;

    @memcpy(full_label_buf[0..prefix.len], prefix);
    @memcpy(full_label_buf[prefix.len..][0..label.len], label);

    const full_label = full_label_buf[0 .. prefix.len + label.len];

    // Create iovec structs for PicoTLS API
    const secret_iovec = c.ptls_iovec_t{
        .base = @constCast(secret.ptr),
        .len = secret.len,
    };
    const hash_value_iovec = c.ptls_iovec_t{
        .base = @constCast(context.ptr),
        .len = context.len,
    };

    // Call picotls HKDF-Expand-Label
    const rc = c.ptls_hkdf_expand_label(
        hash_algo,
        out.ptr,
        out.len,
        secret_iovec,
        full_label.ptr,
        hash_value_iovec,
        prefix.ptr,
    );

    if (rc != 0)
        return error.HkdfFailed;
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "TlsContext stub" {
    var ctx = TlsContext{};
    try std.testing.expect(!ctx.initialized);
    try std.testing.expect(!ctx.isHandshakeComplete());
}
