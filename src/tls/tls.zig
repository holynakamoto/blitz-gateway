// TLS 1.3 support using OpenSSL
// Optimized for zero-copy and io_uring integration

const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/conf.h");
});

// C wrapper functions
extern fn blitz_openssl_init() c_int;
extern fn blitz_ssl_ctx_new() ?*c.SSL_CTX;
extern fn blitz_ssl_ctx_set_alpn(ctx: ?*c.SSL_CTX) void;
extern fn blitz_ssl_ctx_use_certificate_file(ctx: ?*c.SSL_CTX, cert_file: [*c]const u8) c_int;
extern fn blitz_ssl_ctx_use_privatekey_file(ctx: ?*c.SSL_CTX, key_file: [*c]const u8) c_int;
extern fn blitz_ssl_new(ctx: ?*c.SSL_CTX) ?*c.SSL;
extern fn blitz_ssl_set_fd(ssl: ?*c.SSL, fd: c_int) c_int; // Deprecated - use memory BIOs
extern fn blitz_ssl_accept(ssl: ?*c.SSL) c_int;
extern fn blitz_ssl_get_error(ssl: ?*c.SSL, ret: c_int) c_int;
extern fn blitz_ssl_want_read(err: c_int) c_int;
extern fn blitz_ssl_want_write(err: c_int) c_int;
extern fn blitz_ssl_read(ssl: ?*c.SSL, buf: ?*anyopaque, num: c_int) c_int;
extern fn blitz_ssl_write(ssl: ?*c.SSL, buf: ?*const anyopaque, num: c_int) c_int;
extern fn blitz_ssl_get_alpn_selected(ssl: ?*c.SSL, data: *?*const u8, len: *c_uint) void;
extern fn blitz_ssl_free(ssl: ?*c.SSL) void;
extern fn blitz_ssl_ctx_free(ctx: ?*c.SSL_CTX) void;
extern fn blitz_ssl_error_string() [*c]const u8;

// Memory BIO functions for io_uring integration
extern fn blitz_bio_new() ?*anyopaque; // Returns BIO*
extern fn blitz_bio_new_mem_buf(buf: ?*const anyopaque, len: c_int) ?*anyopaque; // Returns BIO*
extern fn blitz_ssl_set_bio(ssl: ?*c.SSL, rbio: ?*anyopaque, wbio: ?*anyopaque) void;
extern fn blitz_bio_write(bio: ?*anyopaque, buf: ?*const anyopaque, len: c_int) c_int;
extern fn blitz_bio_read(bio: ?*anyopaque, buf: ?*anyopaque, len: c_int) c_int;
extern fn blitz_bio_ctrl_pending(bio: ?*anyopaque) c_int;
extern fn blitz_bio_free(bio: ?*anyopaque) void;

pub const Protocol = enum {
    http1_1,
    http2,
    unknown,
};

pub const TlsState = enum {
    handshake,
    connected,
    tls_error,
    closed,
};

pub const TlsConnection = struct {
    ssl: ?*c.SSL,
    fd: c_int,
    state: TlsState,
    protocol: Protocol,
    read_bio: ?*anyopaque = null, // Memory BIO for reading encrypted data from io_uring
    write_bio: ?*anyopaque = null, // Memory BIO for writing encrypted data to io_uring
    
    pub fn init(ssl: ?*c.SSL, fd: c_int) !TlsConnection {
        // Create memory BIOs for io_uring integration
        const rbio = blitz_bio_new() orelse return error.BioCreationFailed;
        const wbio = blitz_bio_new() orelse {
            blitz_bio_free(rbio);
            return error.BioCreationFailed;
        };
        
        // Set memory BIOs instead of socket BIO
        blitz_ssl_set_bio(ssl, rbio, wbio);
        
        return TlsConnection{
            .ssl = ssl,
            .fd = fd,
            .state = .handshake,
            .protocol = .unknown,
            .read_bio = rbio,
            .write_bio = wbio,
        };
    }
    
    pub fn deinit(self: *TlsConnection) void {
        if (self.ssl) |ssl| {
            // SSL_free automatically frees the BIOs set with SSL_set_bio
            // Do NOT call blitz_bio_free() separately - that would be a double-free!
            blitz_ssl_free(ssl);
        }
        self.ssl = null;
        self.read_bio = null; // BIOs already freed by SSL_free
        self.write_bio = null; // BIOs already freed by SSL_free
    }
    
    // Feed encrypted data from io_uring to OpenSSL (for handshake and reading)
    pub fn feedData(self: *TlsConnection, data: []const u8) !void {
        if (self.read_bio == null) {
            return error.NoBio;
        }
        const written = blitz_bio_write(self.read_bio, data.ptr, @intCast(data.len));
        if (written != data.len) {
            return error.BioWriteFailed;
        }
    }
    
    // Get encrypted output from OpenSSL for io_uring write
    // Note: This drains the write_bio - call multiple times if needed to get all data
    pub fn getEncryptedOutput(self: *TlsConnection, buf: []u8) !usize {
        if (self.write_bio == null) {
            return error.NoBio;
        }
        const pending = blitz_bio_ctrl_pending(self.write_bio);
        if (pending == 0) {
            return 0; // No data to read
        }
        const to_read = @min(@as(usize, @intCast(pending)), buf.len);
        const bytes_read = blitz_bio_read(self.write_bio, buf.ptr, @intCast(to_read));
        if (bytes_read < 0) {
            return error.BioReadFailed;
        }
        return @intCast(bytes_read);
    }
    
    // Get ALL encrypted output, ensuring we read everything from write_bio
    // Returns the total bytes read. If the buffer is too small, returns error.BufferTooSmall
    // This is critical to prevent "bad record mac" errors from incomplete TLS records
    pub fn getAllEncryptedOutput(self: *TlsConnection, buf: []u8) !usize {
        if (self.write_bio == null) {
            return error.NoBio;
        }
        const total_pending = blitz_bio_ctrl_pending(self.write_bio);
        if (total_pending == 0) {
            return 0; // No data to read
        }
        
        // Check if all data fits in the buffer
        if (total_pending > buf.len) {
            // Buffer too small - this should not happen with normal TLS records
            // TLS records are typically < 16KB, and our buffer is 4KB
            // But if it does happen, we need to handle it
            return error.BufferTooSmall;
        }
        
        // Read all pending data
        const bytes_read = blitz_bio_read(self.write_bio, buf.ptr, @intCast(total_pending));
        if (bytes_read < 0) {
            return error.BioReadFailed;
        }
        
        // Verify we read everything
        const remaining = blitz_bio_ctrl_pending(self.write_bio);
        if (remaining > 0) {
            // This should not happen if we read correctly
            std.log.warn("Warning: {} bytes still pending in write_bio after read", .{remaining});
        }
        
        return @intCast(bytes_read);
    }
    
    // Check if read_bio has any pending data (should be empty after handshake)
    pub fn hasPendingReadData(self: *TlsConnection) bool {
        if (self.read_bio == null) {
            return false;
        }
        return blitz_bio_ctrl_pending(self.read_bio) > 0;
    }
    
    // Check if there's encrypted output pending
    pub fn hasEncryptedOutput(self: *TlsConnection) bool {
        if (self.write_bio == null) {
            return false;
        }
        return blitz_bio_ctrl_pending(self.write_bio) > 0;
    }
    
    // Clear encrypted output from write_bio (drain all pending data)
    // CRITICAL: Call this after releasing write buffers to prevent BIO state issues
    // This prevents "bad record mac" errors when buffers are reused
    pub fn clearEncryptedOutput(self: *TlsConnection) void {
        if (self.write_bio == null) {
            return;
        }
        // Drain all pending data from write_bio into a temporary buffer
        // This resets the BIO's internal pointers and prevents stale data issues
        var temp_buf: [4096]u8 = undefined;
        while (blitz_bio_ctrl_pending(self.write_bio) > 0) {
            const bytes_read = blitz_bio_read(self.write_bio, &temp_buf, @intCast(temp_buf.len));
            if (bytes_read <= 0) {
                break; // No more data or error
            }
        }
    }
    
    // Perform TLS handshake (non-blocking)
    pub fn doHandshake(self: *TlsConnection) !TlsState {
        if (self.ssl == null) {
            return error.NoSsl;
        }
        
        const ret = blitz_ssl_accept(self.ssl);
        if (ret == 1) {
            // Handshake complete
            self.state = .connected;
            
            // Check negotiated protocol (ALPN)
            var alpn_data: ?*const u8 = null;
            var alpn_len: c_uint = 0;
            blitz_ssl_get_alpn_selected(self.ssl, &alpn_data, &alpn_len);
            if (alpn_data != null and alpn_len > 0) {
                const alpn_ptr = alpn_data.?;
                // Compare byte-by-byte to avoid slice issues
                if (alpn_len == 2 and @as(*const [2]u8, @ptrCast(alpn_ptr))[0] == 'h' and @as(*const [2]u8, @ptrCast(alpn_ptr))[1] == '2') {
                    self.protocol = .http2;
                } else if (alpn_len == 8) {
                    const http11 = @as(*const [8]u8, @ptrCast(alpn_ptr));
                    if (http11[0] == 'h' and http11[1] == 't' and http11[2] == 't' and http11[3] == 'p' and
                        http11[4] == '/' and http11[5] == '1' and http11[6] == '.' and http11[7] == '1') {
                        self.protocol = .http1_1;
                    } else {
                        self.protocol = .unknown;
                    }
                } else {
                    self.protocol = .unknown;
                }
            } else {
                // Default to HTTP/1.1 if no ALPN
                self.protocol = .http1_1;
            }
            
            return .connected;
        }
        
        const err = blitz_ssl_get_error(self.ssl, ret);
        if (blitz_ssl_want_read(err) != 0) {
            // Need more data from client
            return .handshake;
        } else if (blitz_ssl_want_write(err) != 0) {
            // Need to send more data to client
            return .handshake;
        } else {
            // Error
            self.state = .tls_error;
            return .tls_error;
        }
    }
    
    // Read decrypted data
    // Note: Encrypted data must be fed to read_bio via feedData() before calling this
    pub fn read(self: *TlsConnection, buf: []u8) !usize {
        if (self.ssl == null) {
            return error.NoSsl;
        }
        
        if (self.state != .connected) {
            return error.NotConnected;
        }
        
        const ret = blitz_ssl_read(self.ssl, buf.ptr, @intCast(buf.len));
        if (ret > 0) {
            return @intCast(ret);
        } else if (ret == 0) {
            return error.ConnectionClosed;
        }
        
        const err = blitz_ssl_get_error(self.ssl, ret);
        if (blitz_ssl_want_read(err) != 0) {
            return error.WantRead;
        } else if (blitz_ssl_want_write(err) != 0) {
            return error.WantWrite;
        } else {
            return error.ReadFailed;
        }
    }
    
    // Write plaintext data (encrypts and puts result in write_bio)
    // Use getEncryptedOutput() to retrieve encrypted data for io_uring write
    pub fn write(self: *TlsConnection, buf: []const u8) !usize {
        if (self.ssl == null) {
            return error.NoSsl;
        }
        
        if (self.state != .connected) {
            return error.NotConnected;
        }
        
        // SSL_write encrypts data and writes to write_bio (memory BIO)
        const ret = blitz_ssl_write(self.ssl, buf.ptr, @intCast(buf.len));
        if (ret > 0) {
            return @intCast(ret);
        }
        
        const err = blitz_ssl_get_error(self.ssl, ret);
        if (blitz_ssl_want_read(err) != 0) {
            return error.WantRead;
        } else if (blitz_ssl_want_write(err) != 0) {
            return error.WantWrite;
        } else {
            return error.WriteFailed;
        }
    }
};

pub const TlsContext = struct {
    ctx: ?*c.SSL_CTX,
    
    pub fn init() !TlsContext {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedPlatform;
        }
        
        if (blitz_openssl_init() == 0) {
            return error.OpenSslInitFailed;
        }
        
        const ctx = blitz_ssl_ctx_new();
        if (ctx == null) {
            return error.SslCtxCreationFailed;
        }
        
        // Set ALPN callback for HTTP/2 negotiation
        blitz_ssl_ctx_set_alpn(ctx);
        
        return TlsContext{ .ctx = ctx };
    }
    
    pub fn deinit(self: *TlsContext) void {
        if (self.ctx) |ctx| {
            blitz_ssl_ctx_free(ctx);
        }
        self.ctx = null;
    }
    
    // Load certificate and private key
    pub fn loadCertificate(self: *TlsContext, cert_file: []const u8, key_file: []const u8) !void {
        if (self.ctx == null) {
            return error.NoContext;
        }
        
        // Convert to null-terminated strings
        // Use a temporary allocator for C strings
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        
        const cert_cstr = try std.fmt.allocPrintZ(allocator, "{s}", .{cert_file});
        defer allocator.free(cert_cstr);
        
        const key_cstr = try std.fmt.allocPrintZ(allocator, "{s}", .{key_file});
        defer allocator.free(key_cstr);
        
        if (blitz_ssl_ctx_use_certificate_file(self.ctx, cert_cstr.ptr) != 1) {
            return error.CertificateLoadFailed;
        }
        
        if (blitz_ssl_ctx_use_privatekey_file(self.ctx, key_cstr.ptr) != 1) {
            return error.KeyLoadFailed;
        }
    }
    
    // Create new TLS connection with memory BIOs for io_uring
    pub fn newConnection(self: *TlsContext, fd: c_int) !TlsConnection {
        if (self.ctx == null) {
            return error.NoContext;
        }
        
        const ssl = blitz_ssl_new(self.ctx);
        if (ssl == null) {
            return error.SslCreationFailed;
        }
        
        // Use memory BIOs instead of socket BIO for io_uring integration
        return TlsConnection.init(ssl, fd);
    }
};

