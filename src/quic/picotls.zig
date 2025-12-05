// PicoTLS bindings for QUIC TLS 1.3 handshake (MINICRYPTO - NO OPENSSL)
//
// picotls is specifically designed for QUIC - it outputs raw handshake messages
// at the correct encryption level, not TLS records!
//
// Uses ptls_minicrypto_* backend for pure static builds without OpenSSL.

const std = @import("std");
const builtin = @import("builtin");

// ═══════════════════════════════════════════════════════════════════════════════
// PICOTLS C API DECLARATIONS
// These are extern declarations - actual symbols provided by libpicotls at link time
// ═══════════════════════════════════════════════════════════════════════════════

const c = struct {
    // Opaque types
    pub const ptls_context_t = opaque {};
    pub const ptls_t = opaque {};
    pub const ptls_key_exchange_algorithm_t = opaque {};
    pub const ptls_cipher_suite_t = opaque {};
    pub const ptls_hash_algorithm_t = opaque {};

    // Buffer type for handshake output
    pub const ptls_buffer_t = extern struct {
        base: [*]u8,
        capacity: usize,
        off: usize,
        is_allocated: c_int,
    };

    // Input vector
    pub const ptls_iovec_t = extern struct {
        base: ?[*]const u8,
        len: usize,
    };

    // Minicrypto cipher suites and key exchanges (extern vars)
    pub extern var ptls_minicrypto_secp256r1: ptls_key_exchange_algorithm_t;
    pub extern var ptls_minicrypto_x25519: ptls_key_exchange_algorithm_t;
    pub extern var ptls_minicrypto_aes128gcmsha256: ptls_cipher_suite_t;
    pub extern var ptls_minicrypto_aes256gcmsha384: ptls_cipher_suite_t;
    pub extern var ptls_minicrypto_chacha20poly1305sha256: ptls_cipher_suite_t;
    pub extern var ptls_minicrypto_sha256: ptls_hash_algorithm_t;

    // Core picotls functions
    pub extern fn ptls_new(ctx: *ptls_context_t, is_server: c_int) ?*ptls_t;
    pub extern fn ptls_free(tls: *ptls_t) void;
    pub extern fn ptls_handshake(
        tls: *ptls_t,
        sendbuf: ?*ptls_buffer_t,
        input: ?*const anyopaque,
        inlen: *usize,
        properties: ?*anyopaque,
    ) c_int;
    pub extern fn ptls_is_server(tls: *ptls_t) c_int;
    pub extern fn ptls_handshake_is_complete(tls: *ptls_t) c_int;

    // Buffer operations
    pub extern fn ptls_buffer_init(buf: *ptls_buffer_t, smallbuf: ?[*]u8, smallbuf_size: usize) void;
    pub extern fn ptls_buffer_dispose(buf: *ptls_buffer_t) void;

    // HKDF operations (for key derivation)
    pub extern fn ptls_hkdf_expand_label(
        algo: *const ptls_hash_algorithm_t,
        output: [*]u8,
        outlen: usize,
        secret: ptls_iovec_t,
        label: [*]const u8,
        label_len: usize,
        hash_value: ptls_iovec_t,
        label_prefix: [*]const u8,
    ) c_int;

    // Error codes
    pub const PTLS_ERROR_IN_PROGRESS: c_int = -1;
    pub const PTLS_ALERT_HANDSHAKE_FAILURE: c_int = 40;
};

// ═══════════════════════════════════════════════════════════════════════════════
// ENCRYPTION LEVELS (QUIC epochs)
// ═══════════════════════════════════════════════════════════════════════════════

pub const EncryptionLevel = enum(u8) {
    initial = 0,
    early_data = 1,
    handshake = 2,
    application = 3,
};

// ═══════════════════════════════════════════════════════════════════════════════
// HANDSHAKE OUTPUT
// ═══════════════════════════════════════════════════════════════════════════════

pub const HandshakeOutput = struct {
    level: EncryptionLevel,
    data: []const u8,
    offset: u64,
};

// ═══════════════════════════════════════════════════════════════════════════════
// TLS CONTEXT - Manages PicoTLS connection state
// ═══════════════════════════════════════════════════════════════════════════════

pub const TlsContext = struct {
    allocator: std.mem.Allocator,
    tls: ?*c.ptls_t = null,
    ctx: ?*c.ptls_context_t = null,
    
    // Handshake state
    handshake_complete: bool = false,
    
    // Output buffers per encryption level
    initial_output: std.ArrayList(u8),
    handshake_output: std.ArrayList(u8),
    
    // CRYPTO frame offsets
    initial_offset: u64 = 0,
    handshake_offset: u64 = 0,

    /// Initialize TLS context (server mode)
    pub fn init(allocator: std.mem.Allocator) !TlsContext {
        return TlsContext{
            .allocator = allocator,
            .initial_output = std.ArrayList(u8).init(allocator),
            .handshake_output = std.ArrayList(u8).init(allocator),
        };
    }

    /// Create a new server TLS connection
    /// Call this when receiving the first Initial packet
    pub fn newServerConnection(self: *TlsContext, ptls_ctx: *c.ptls_context_t) !void {
        if (self.tls != null) return; // Already have a connection

        self.ctx = ptls_ctx;
        self.tls = c.ptls_new(ptls_ctx, 1); // 1 = server mode
        if (self.tls == null) {
            std.log.err("[TLS] ptls_new failed", .{});
            return error.TlsInitFailed;
        }
        std.log.info("[TLS] Created new server TLS connection", .{});
    }

    /// Feed ClientHello data and process handshake
    /// Returns true if handshake completed
    pub fn feedClientHello(self: *TlsContext, data: []const u8) !bool {
        if (self.tls == null) return error.NoTlsConnection;

        // Set up output buffer
        var sendbuf: c.ptls_buffer_t = undefined;
        var sendbuf_small: [4096]u8 = undefined;
        c.ptls_buffer_init(&sendbuf, &sendbuf_small, sendbuf_small.len);
        defer c.ptls_buffer_dispose(&sendbuf);

        // Process handshake
        var inlen = data.len;
        const rc = c.ptls_handshake(
            self.tls.?,
            &sendbuf,
            data.ptr,
            &inlen,
            null,
        );

        // Store output (ServerHello + encrypted extensions + cert + finished)
        if (sendbuf.off > 0) {
            // For Initial packets, output goes to initial_output
            // For Handshake packets, output goes to handshake_output
            // The epoch is determined by where we are in the handshake
            try self.initial_output.appendSlice(sendbuf.base[0..sendbuf.off]);
        }

        if (rc == 0) {
            self.handshake_complete = true;
            return true;
        } else if (rc == c.PTLS_ERROR_IN_PROGRESS) {
            return false;
        } else {
            return error.HandshakeFailed;
        }
    }

    /// Get pending handshake output for a specific encryption level
    pub fn getHandshakeOutput(self: *TlsContext, level: EncryptionLevel) ?HandshakeOutput {
        const output_list = switch (level) {
            .initial => &self.initial_output,
            .handshake => &self.handshake_output,
            else => return null,
        };

        if (output_list.items.len == 0) return null;

        const offset = switch (level) {
            .initial => self.initial_offset,
            .handshake => self.handshake_offset,
            else => 0,
        };

        return HandshakeOutput{
            .level = level,
            .data = output_list.items,
            .offset = offset,
        };
    }

    /// Clear output after it's been sent
    pub fn clearOutput(self: *TlsContext, level: EncryptionLevel, bytes_sent: usize) void {
        switch (level) {
            .initial => {
                self.initial_offset += bytes_sent;
                self.initial_output.clearRetainingCapacity();
            },
            .handshake => {
                self.handshake_offset += bytes_sent;
                self.handshake_output.clearRetainingCapacity();
            },
            else => {},
        }
    }

    /// Check if TLS handshake is complete
    pub fn isHandshakeComplete(self: *TlsContext) bool {
        if (self.tls) |tls| {
            return c.ptls_handshake_is_complete(tls) != 0;
        }
        return self.handshake_complete;
    }

    /// Clean up resources
    pub fn deinit(self: *TlsContext) void {
        if (self.tls) |tls| {
            c.ptls_free(tls);
            self.tls = null;
        }
        self.initial_output.deinit(self.allocator);
        self.handshake_output.deinit(self.allocator);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// HKDF USING MINICRYPTO
// ═══════════════════════════════════════════════════════════════════════════════

/// HKDF-Expand-Label using picotls minicrypto SHA256
pub fn hkdfExpandLabel(
    secret: []const u8,
    label: []const u8,
    context: []const u8,
    out: []u8,
) !void {
    const secret_iovec = c.ptls_iovec_t{
        .base = secret.ptr,
        .len = secret.len,
    };
    const context_iovec = c.ptls_iovec_t{
        .base = if (context.len > 0) context.ptr else null,
        .len = context.len,
    };

    const rc = c.ptls_hkdf_expand_label(
        &c.ptls_minicrypto_sha256,
        out.ptr,
        out.len,
        secret_iovec,
        label.ptr,
        label.len,
        context_iovec,
        "tls13 ",
    );

    if (rc != 0) return error.HkdfFailed;
}

// ═══════════════════════════════════════════════════════════════════════════════
// HELPER: Get minicrypto cipher suite
// ═══════════════════════════════════════════════════════════════════════════════

pub fn getMiniCryptoAes128GcmSha256() *c.ptls_cipher_suite_t {
    return &c.ptls_minicrypto_aes128gcmsha256;
}

pub fn getMiniCryptoX25519() *c.ptls_key_exchange_algorithm_t {
    return &c.ptls_minicrypto_x25519;
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "TlsContext init/deinit" {
    var ctx = try TlsContext.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expect(!ctx.isHandshakeComplete());
    try std.testing.expect(ctx.tls == null);
}
