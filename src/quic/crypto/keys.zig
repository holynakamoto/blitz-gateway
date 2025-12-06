// quic/crypto/keys.zig
// Initial key derivation — RFC 9001 §5.2

const std = @import("std");
const constants = @import("../constants.zig");

const hkdf = std.crypto.hkdf.HkdfSha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const InitialKeys = struct {
    client_secret: [32]u8,
    server_secret: [32]u8,
    client_key: [16]u8,
    client_iv: [12]u8,
    client_hp: [16]u8,
    server_key: [16]u8,
    server_iv: [12]u8,
    server_hp: [16]u8,
};

/// Derive Initial secrets and keys from ODCID (RFC 9001 §5.2)
pub fn deriveInitialKeys(odcid: []const u8) InitialKeys {
    const initial_secret = hkdf.extract(&constants.INITIAL_SALT, odcid);

    var client_secret: [32]u8 = undefined;
    var server_secret: [32]u8 = undefined;

    hkdf.expand(&client_secret, "tls13 client in", &initial_secret);
    hkdf.expand(&server_secret, "tls13 server in", &initial_secret);

    var keys: InitialKeys = undefined;
    keys.client_secret = client_secret;
    keys.server_secret = server_secret;

    // Client keys (client → server)
    hkdf.expand(&keys.client_key, "tls13 quic key", &client_secret);
    hkdf.expand(&keys.client_iv, "tls13 quic iv", &client_secret);
    hkdf.expand(&keys.client_hp, "tls13 quic hp", &client_secret);

    // Server keys (server → client)
    hkdf.expand(&keys.server_key, "tls13 quic key", &server_secret);
    hkdf.expand(&keys.server_iv, "tls13 quic iv", &server_secret);
    hkdf.expand(&keys.server_hp, "tls13 quic hp", &server_secret);

    return keys;
}
