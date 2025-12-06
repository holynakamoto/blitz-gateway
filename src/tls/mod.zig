//! TLS Module
//! Public API for TLS connection handling and session management

pub const TlsConnection = @import("tls.zig").TlsConnection;
pub const TlsState = @import("tls.zig").TlsState;

// Re-export TLS session management types
pub const SessionCache = @import("session.zig").SessionCache;
pub const SessionTicket = @import("session.zig").SessionTicket;
pub const TokenCache = @import("session.zig").TokenCache;
