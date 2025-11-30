// TLS 1.3 support - temporarily disabled for PicoTLS migration
// All TLS operations now handled by PicoTLS directly

const std = @import("std");

// Empty module to avoid import errors during transition
pub const TlsContext = struct {
    pub fn init() !TlsContext {
        return TlsContext{};
    }
    pub fn deinit(self: *TlsContext) void {
        _ = self;
    }
};

// Stub extern functions to avoid compilation errors during transition
extern fn blitz_openssl_init() c_int;
extern fn blitz_ssl_ctx_new() ?*c_int;
extern fn blitz_ssl_ctx_set_alpn(ctx: ?*c_int) void;
extern fn blitz_ssl_ctx_use_certificate_file(ctx: ?*c_int, cert_file: [*c]const u8) c_int;
extern fn blitz_ssl_ctx_use_privatekey_file(ctx: ?*c_int, key_file: [*c]const u8) c_int;
extern fn blitz_ssl_new(ctx: ?*c_int) ?*c_int;
extern fn blitz_ssl_set_fd(ssl: ?*c_int, fd: c_int) c_int;
extern fn blitz_ssl_accept(ssl: ?*c_int) c_int;
extern fn blitz_ssl_get_error(ssl: ?*c_int, ret: c_int) c_int;
extern fn blitz_ssl_want_read(err: c_int) c_int;
extern fn blitz_ssl_want_write(err: c_int) c_int;
extern fn blitz_ssl_read(ssl: ?*c_int, buf: ?*anyopaque, num: c_int) c_int;
extern fn blitz_ssl_write(ssl: ?*c_int, buf: ?*const anyopaque, num: c_int) c_int;
extern fn blitz_ssl_pending(ssl: ?*c_int) c_int;
extern fn blitz_ssl_shutdown(ssl: ?*c_int) c_int;
extern fn blitz_ssl_free(ssl: ?*c_int) void;
extern fn blitz_ssl_ctx_free(ctx: ?*c_int) void;
