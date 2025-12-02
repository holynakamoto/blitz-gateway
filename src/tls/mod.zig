//! TLS Module
//! Public API for TLS connection handling and session management

pub const TlsConnection = @import("tls.zig").TlsConnection;
pub const TlsState = @import("tls.zig").TlsState;

// Re-export TLS session management if needed
pub const SessionCache = @import("../tls_session.zig").SessionCache;
pub const SessionTicket = @import("../tls_session.zig").SessionTicket;
pub const TokenCache = @import("../tls_session.zig").TokenCache;

