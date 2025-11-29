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
extern fn blitz_ssl_ctx_use_certificate_file(ctx: ?*c.SSL_CTX, cert_file: [*c]const u8) c_int;
extern fn blitz_ssl_ctx_use_privatekey_file(ctx: ?*c.SSL_CTX, key_file: [*c]const u8) c_int;
extern fn blitz_ssl_new(ctx: ?*c.SSL_CTX) ?*c.SSL;
extern fn blitz_ssl_set_fd(ssl: ?*c.SSL, fd: c_int) c_int;
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
    read_bio: ?*anyopaque = null, // BIO for reading encrypted data
    write_bio: ?*anyopaque = null, // BIO for writing encrypted data
    
    pub fn init(ssl: ?*c.SSL, fd: c_int) TlsConnection {
        return TlsConnection{
            .ssl = ssl,
            .fd = fd,
            .state = .handshake,
            .protocol = .unknown,
        };
    }
    
    pub fn deinit(self: *TlsConnection) void {
        if (self.ssl) |ssl| {
            blitz_ssl_free(ssl);
        }
        self.ssl = null;
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
            return error.HandshakeFailed;
        }
    }
    
    // Read decrypted data
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
    
    // Write encrypted data
    pub fn write(self: *TlsConnection, buf: []const u8) !usize {
        if (self.ssl == null) {
            return error.NoSsl;
        }
        
        if (self.state != .connected) {
            return error.NotConnected;
        }
        
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
    
    // Create new TLS connection
    pub fn newConnection(self: *TlsContext, fd: c_int) !TlsConnection {
        if (self.ctx == null) {
            return error.NoContext;
        }
        
        const ssl = blitz_ssl_new(self.ctx);
        if (ssl == null) {
            return error.SslCreationFailed;
        }
        
        if (blitz_ssl_set_fd(ssl, fd) != 1) {
            blitz_ssl_free(ssl);
            return error.SetFdFailed;
        }
        
        return TlsConnection.init(ssl, fd);
    }
};

