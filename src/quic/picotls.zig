// picotls bindings for QUIC TLS 1.3 handshake
// picotls is specifically designed for QUIC - it outputs raw handshake messages
// at the correct encryption level, not TLS records!
//
// Uses ptls_server_handle_message() which provides epoch_offsets[5] to tell us
// exactly where each encryption level's data starts/ends in the output buffer.

const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("picotls.h");
    @cInclude("picotls/openssl.h");
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

// TLS Context for a single connection
pub const TlsContext = struct {
    ctx: c.ptls_context_t,
    tls: ?*c.ptls_t,
    sign_cert: c.ptls_openssl_sign_certificate_t,

    // Buffers for handshake output
    handshake_buffer: [16384]u8,
    epoch_offsets: [5]usize, // [initial_start, initial_end, handshake_start, handshake_end, total]

    // CRYPTO frame offsets for each level
    crypto_offset_initial: u64,
    crypto_offset_handshake: u64,

    pub fn init(cert_pem: []const u8, key_pem: []const u8) !TlsContext {
        var self = TlsContext{
            .ctx = std.mem.zeroes(c.ptls_context_t),
            .tls = null,
            .sign_cert = std.mem.zeroes(c.ptls_openssl_sign_certificate_t),
            .handshake_buffer = undefined,
            .epoch_offsets = [_]usize{0} ** 5,
            .crypto_offset_initial = 0,
            .crypto_offset_handshake = 0,
        };

        // Set up crypto using OpenSSL backend
        self.ctx.random_bytes = c.ptls_openssl_random_bytes;
        self.ctx.get_time = &c.ptls_get_time;
        self.ctx.key_exchanges = &c.ptls_openssl_key_exchanges[0];
        self.ctx.cipher_suites = &c.ptls_openssl_cipher_suites[0];

        // Load certificate using OpenSSL
        try self.loadCertificate(cert_pem, key_pem);

        return self;
    }

    fn loadCertificate(self: *TlsContext, cert_pem: []const u8, key_pem: []const u8) !void {
        // Use OpenSSL to load PEM certificate and key
        const openssl = @cImport({
            @cInclude("openssl/ssl.h");
            @cInclude("openssl/pem.h");
            @cInclude("openssl/err.h");
        });

        // Load certificate
        const cert_bio = openssl.BIO_new_mem_buf(cert_pem.ptr, @intCast(cert_pem.len));
        if (cert_bio == null) return error.CertLoadFailed;
        defer openssl.BIO_free(cert_bio);

        const cert = openssl.PEM_read_bio_X509(cert_bio, null, null, null);
        if (cert == null) return error.CertParseFailed;
        // Don't free cert yet - picotls needs it

        // Load private key
        const key_bio = openssl.BIO_new_mem_buf(key_pem.ptr, @intCast(key_pem.len));
        if (key_bio == null) {
            openssl.X509_free(cert);
            return error.KeyLoadFailed;
        }
        defer openssl.BIO_free(key_bio);

        const key = openssl.PEM_read_bio_PrivateKey(key_bio, null, null, null);
        if (key == null) {
            openssl.X509_free(cert);
            return error.KeyParseFailed;
        }
        // Don't free key yet - picotls needs it

        // Set up sign certificate callback (picotls will use this for signing)
        const ret = c.ptls_openssl_init_sign_certificate(&self.sign_cert, key);
        if (ret != 0) {
            openssl.EVP_PKEY_free(key);
            openssl.X509_free(cert);
            return error.SignCertInitFailed;
        }

        // Set certificate chain in context
        self.ctx.sign_certificate = &self.sign_cert.super;

        // Load certificate into picotls context
        const load_ret = c.ptls_openssl_load_certificates(&self.ctx, cert, null);
        if (load_ret != 0) {
            c.ptls_openssl_dispose_sign_certificate(&self.sign_cert);
            openssl.EVP_PKEY_free(key);
            openssl.X509_free(cert);
            return error.CertLoadFailed;
        }

        // Note: cert and key are now owned by picotls context
    }

    // Start a new TLS connection (server mode)
    pub fn newConnection(self: *TlsContext) !void {
        self.tls = c.ptls_new(&self.ctx, 1); // 1 = server mode
        if (self.tls == null) {
            return error.PicotlsNewFailed;
        }

        // Reset offsets
        self.crypto_offset_initial = 0;
        self.crypto_offset_handshake = 0;
        self.epoch_offsets = [_]usize{0} ** 5;
    }

    // Process ClientHello and generate server response (QUIC-specific API)
    // Returns handshake data split by encryption level
    pub fn handleClientHello(self: *TlsContext, client_hello: []const u8) !void {
        if (self.tls == null) {
            try self.newConnection();
        }

        // Reset buffer and offsets
        var sendbuf = c.ptls_buffer_t{
            .base = &self.handshake_buffer,
            .capacity = self.handshake_buffer.len,
            .off = 0,
            .is_allocated = 0,
        };

        // epoch_offsets[5]: [initial_start, initial_end, handshake_start, handshake_end, total]
        var epoch_offsets: [5]usize = [_]usize{0} ** 5;

        // Use QUIC-specific API: ptls_server_handle_message
        // in_epoch = 0 (INITIAL) since ClientHello comes in INITIAL packet
        const ret = c.ptls_server_handle_message(
            self.tls,
            &sendbuf,
            &epoch_offsets,
            0, // in_epoch = INITIAL
            client_hello.ptr,
            client_hello.len,
            null, // handshake_properties
        );

        if (ret != 0 and ret != c.PTLS_ERROR_IN_PROGRESS) {
            std.log.err("[picotls] Handshake error: {d}", .{ret});
            return error.TlsHandshakeFailed;
        }

        // Store epoch offsets
        self.epoch_offsets = epoch_offsets;

        std.debug.print("[picotls] Generated {} bytes total\n", .{sendbuf.off});
        std.debug.print("[picotls] Epoch offsets: initial=[{}..{}], handshake=[{}..{}], total={}\n", .{ epoch_offsets[0], epoch_offsets[1], epoch_offsets[2], epoch_offsets[3], epoch_offsets[4] });
    }

    // Get handshake data for a specific encryption level
    pub fn getHandshakeOutput(self: *TlsContext, level: EncryptionLevel) ?HandshakeOutput {
        const epoch: usize = @intFromEnum(level);

        // epoch_offsets format: [initial_start, initial_end, handshake_start, handshake_end, total]
        const start = switch (level) {
            .initial => self.epoch_offsets[0],
            .handshake => self.epoch_offsets[2],
            else => return null,
        };

        const end = switch (level) {
            .initial => self.epoch_offsets[1],
            .handshake => self.epoch_offsets[3],
            else => return null,
        };

        if (start >= end) return null;

        const data = self.handshake_buffer[start..end];
        const offset = switch (level) {
            .initial => blk: {
                const off = self.crypto_offset_initial;
                self.crypto_offset_initial += data.len;
                break :blk off;
            },
            .handshake => blk: {
                const off = self.crypto_offset_handshake;
                self.crypto_offset_handshake += data.len;
                break :blk off;
            },
            else => return null,
        };

        return HandshakeOutput{
            .level = level,
            .data = data,
            .offset = offset,
        };
    }

    // Process incoming handshake data (e.g., client Finished in HANDSHAKE packet)
    pub fn receiveHandshake(self: *TlsContext, data: []const u8, in_epoch: EncryptionLevel) !bool {
        var plaintext_buf = c.ptls_buffer_t{
            .base = &self.handshake_buffer,
            .capacity = self.handshake_buffer.len,
            .off = 0,
            .is_allocated = 0,
        };

        var sendbuf = c.ptls_buffer_t{
            .base = &self.handshake_buffer[self.epoch_offsets[4]..],
            .capacity = self.handshake_buffer.len - self.epoch_offsets[4],
            .off = 0,
            .is_allocated = 0,
        };

        var epoch_offsets: [5]usize = self.epoch_offsets;
        epoch_offsets[0] = self.epoch_offsets[4]; // Start from where we left off

        const epoch: usize = @intFromEnum(in_epoch);
        const ret = c.ptls_server_handle_message(
            self.tls,
            &sendbuf,
            &epoch_offsets,
            epoch,
            data.ptr,
            data.len,
            null,
        );

        if (ret != 0 and ret != c.PTLS_ERROR_IN_PROGRESS) {
            return error.TlsReceiveFailed;
        }

        // Update epoch offsets
        self.epoch_offsets = epoch_offsets;

        return self.isHandshakeComplete();
    }

    // Check if handshake is complete
    pub fn isHandshakeComplete(self: *TlsContext) bool {
        if (self.tls) |tls| {
            return c.ptls_handshake_is_complete(tls) != 0;
        }
        return false;
    }

    // Get traffic secrets for QUIC key derivation
    pub fn getTrafficSecrets(self: *TlsContext, level: EncryptionLevel) ?struct { client: []const u8, server: []const u8 } {
        if (self.tls) |tls| {
            const epoch: usize = @intFromEnum(level);

            // Get secrets - picotls provides these via callbacks or direct access
            // For now, we'll need to use the keylog callback or similar
            // This is a placeholder - actual implementation depends on picotls API
            _ = tls;
            _ = epoch;
        }
        return null;
    }

    pub fn deinit(self: *TlsContext) void {
        if (self.tls) |tls| {
            c.ptls_free(tls);
            self.tls = null;
        }
    }
};

// Minimal test
test "picotls context init" {
    // Skip test - requires actual cert/key
    // var ctx = try TlsContext.init("", "");
    // defer ctx.deinit();
}
