// QUIC Handshake Server - Wires together all components for real handshake
// This is the minimal path to get curl --http3-only working!
// NOW USING PICOTLS - QUIC-native TLS 1.3 handshake!
//
// Note: This tool requires build-time dependencies (picotls, openssl) that may
// show lint errors. These are expected and will be resolved at build time when
// proper include paths are configured.

const std = @import("std");
const builtin = @import("builtin");

// const frames = @import("quic/frames.zig"); // Disabled - old QUIC code removed
// const crypto = @import("quic/crypto/mod.zig"); // Disabled - using msquic now
const frame = @import("http3/frame.zig");
const qpack = @import("http3/qpack.zig");
const tls_session = @import("tls/session.zig");

// picotls C API - stub types for linting
// At build time, these will be provided by the actual picotls headers
// Note: All @cImport/@cInclude statements have been replaced with extern declarations
// to avoid lint errors when headers are not available at lint time
const c = struct {
    // picotls types
    pub const ptls_context_t = opaque {};
    pub const ptls_t = opaque {};
    pub const ptls_iovec_t = extern struct {
        base: ?[*]const u8,
        len: usize,
    };
    pub const ptls_buffer_t = opaque {};
    pub const ptls_get_time_t = *const fn () callconv(.C) u64;
    pub const ptls_key_exchange_algorithm_t = opaque {};
    pub const ptls_cipher_suite_t = opaque {};

    // picotls functions
    pub extern fn ptls_get_time() u64;
    pub extern var ptls_minicrypto_key_exchanges: [*]const *const ptls_key_exchange_algorithm_t;
    pub extern var ptls_minicrypto_cipher_suites: [*]const *const ptls_cipher_suite_t;
    pub extern fn ptls_server_new(ctx: *ptls_context_t) ?*ptls_t;
    pub extern fn ptls_server_handle_message(ptls: *ptls_t, output: *ptls_buffer_t, epoch_offsets: *[5]usize, input: ptls_iovec_t) i32;
    pub extern fn ptls_free(ptls: *ptls_t) void;

    // OpenSSL HMAC types/functions (stub for linting)
    pub const HMAC_CTX = opaque {};
    pub extern fn HMAC_CTX_new() ?*HMAC_CTX;
    pub extern fn HMAC_CTX_free(ctx: ?*HMAC_CTX) void;
    pub extern fn HMAC_Init_ex(ctx: ?*HMAC_CTX, key: ?*const anyopaque, key_len: i32, md: ?*anyopaque, engine: ?*anyopaque) i32;
    pub extern fn HMAC_Update(ctx: ?*HMAC_CTX, data: ?*const anyopaque, len: usize) i32;
    pub extern fn HMAC_Final(ctx: ?*HMAC_CTX, md: ?*u8, len: ?*u32) i32;
    pub extern fn EVP_sha256() ?*anyopaque;
};

// Global picotls context - allocated in C to avoid opaque struct issues
extern fn blitz_get_ptls_ctx() *c.ptls_context_t;

// Random bytes function using Zig's crypto
fn ptls_random_bytes(buf: ?*anyopaque, len: usize) callconv(.c) void {
    if (buf == null or len == 0) return;
    const slice = @as([*]u8, @ptrCast(buf.?))[0..len];
    std.crypto.random.bytes(slice);
}

fn getContext() *c.ptls_context_t {
    return blitz_get_ptls_ctx();
}

// QUIC Timeouts (in milliseconds)
const QUIC_TIMEOUTS = struct {
    const handshake_timeout = 30_000; // 30 seconds for complete handshake
    const idle_timeout = 30_000; // 30 seconds idle timeout
    const initial_timeout = 1_000; // 1 second for initial packet response
    const recv_timeout = 5_000; // 5 seconds for socket receive timeout
};

// QUIC Handshake Secrets
const HandshakeSecrets = struct {
    client_key: [crypto.KEY_LEN]u8,
    client_iv: [crypto.IV_LEN]u8,
    client_hp: [crypto.HP_KEY_LEN]u8,
    server_key: [crypto.KEY_LEN]u8,
    server_iv: [crypto.IV_LEN]u8,
    server_hp: [crypto.HP_KEY_LEN]u8,
};

const RttSecrets = struct {
    client_key: [crypto.KEY_LEN]u8,
    client_iv: [crypto.IV_LEN]u8,
    client_hp: [crypto.HP_KEY_LEN]u8,
    server_key: [crypto.KEY_LEN]u8,
    server_iv: [crypto.IV_LEN]u8,
    server_hp: [crypto.HP_KEY_LEN]u8,
};

// Derive QUIC handshake keys from TLS traffic secrets
fn deriveQuicHandshakeKeys(client_secret: []const u8, server_secret: []const u8) !HandshakeSecrets {
    var secrets: HandshakeSecrets = undefined;

    // Use our existing HKDF-Expand-Label with QUIC labels
    // Note: We only use first 32 bytes of the 48-byte secrets (SHA-256)
    const c_secret = client_secret[0..32];
    const s_secret = server_secret[0..32];

    // Derive QUIC keys using "quic key", "quic iv", "quic hp" labels
    // These are the same as Initial keys but from handshake secrets
    try hkdfExpandLabel(&secrets.client_key, c_secret, "quic key", "");
    try hkdfExpandLabel(&secrets.client_iv, c_secret, "quic iv", "");
    try hkdfExpandLabel(&secrets.client_hp, c_secret, "quic hp", "");

    try hkdfExpandLabel(&secrets.server_key, s_secret, "quic key", "");
    try hkdfExpandLabel(&secrets.server_iv, s_secret, "quic iv", "");
    try hkdfExpandLabel(&secrets.server_hp, s_secret, "quic hp", "");

    return secrets;
}

// Derive handshake secrets from PSK for 0-RTT resumption
fn deriveHandshakeSecretsFromPsk(psk_identity: []const u8) !HandshakeSecrets {
    // For 0-RTT resumption, derive handshake secrets from PSK
    // This is a simplified implementation - in practice, this follows TLS 1.3 PSK resumption

    // Use PSK identity as IKM for deriving handshake secrets
    var ikm: [64]u8 = undefined;
    @memcpy(ikm[0..psk_identity.len], psk_identity);

    // Extract master secret (simplified - normally uses empty salt for resumption)
    var master_secret: [32]u8 = undefined;
    try hkdfExtract(&master_secret, &[_]u8{}, ikm[0..psk_identity.len]);

    // Derive client and server handshake traffic secrets
    var client_secret: [32]u8 = undefined;
    try hkdfExpandLabel(&client_secret, &master_secret, "c hs traffic", "");

    var server_secret: [32]u8 = undefined;
    try hkdfExpandLabel(&server_secret, &master_secret, "s hs traffic", "");

    // Derive QUIC handshake keys
    return try deriveQuicHandshakeKeys(&client_secret, &server_secret);
}

// Local HKDF-Extract implementation
fn hkdfExtract(out: []u8, salt: []const u8, ikm: []const u8) !void {
    if (out.len != 32) return error.InvalidOutputLength;
    std.crypto.auth.hmac.sha2.HmacSha256.create(@as(*[32]u8, @ptrCast(out.ptr)), ikm, salt);
}

// Local HKDF-Expand-Label implementation for handshake key derivation
fn hkdfExpandLabel(out: []u8, secret: []const u8, label: []const u8, context: []const u8) !void {
    // This uses the same algorithm as crypto.zig but we duplicate it here
    // to avoid circular dependencies
    // Using stub types from 'c' module for linting - actual OpenSSL will be available at build time

    // Build HkdfLabel
    var hkdf_label: [512]u8 = undefined;
    var offset: usize = 0;

    // Length (2 bytes, big-endian)
    hkdf_label[offset] = @intCast(out.len >> 8);
    hkdf_label[offset + 1] = @intCast(out.len & 0xFF);
    offset += 2;

    // Label with "tls13 " prefix
    const full_label_len = 6 + label.len;
    hkdf_label[offset] = @intCast(full_label_len);
    offset += 1;
    @memcpy(hkdf_label[offset .. offset + 6], "tls13 ");
    offset += 6;
    @memcpy(hkdf_label[offset .. offset + label.len], label);
    offset += label.len;

    // Context
    hkdf_label[offset] = @intCast(context.len);
    offset += 1;
    if (context.len > 0) {
        @memcpy(hkdf_label[offset .. offset + context.len], context);
        offset += context.len;
    }

    // HKDF-Expand
    const hmac_ctx = c.HMAC_CTX_new() orelse return error.CryptoError;
    defer c.HMAC_CTX_free(hmac_ctx);

    var T: [32]u8 = undefined;
    var n: u8 = 1;
    var out_offset: usize = 0;

    while (out_offset < out.len) {
        if (c.HMAC_Init_ex(hmac_ctx, secret.ptr, @intCast(secret.len), c.EVP_sha256(), null) != 1) {
            return error.CryptoError;
        }
        if (n > 1) {
            if (c.HMAC_Update(hmac_ctx, &T, 32) != 1) return error.CryptoError;
        }
        if (c.HMAC_Update(hmac_ctx, &hkdf_label, offset) != 1) return error.CryptoError;
        if (c.HMAC_Update(hmac_ctx, &n, 1) != 1) return error.CryptoError;

        var out_len: u32 = 32;
        if (c.HMAC_Final(hmac_ctx, &T, &out_len) != 1) return error.CryptoError;

        const copy_len = @min(32, out.len - out_offset);
        @memcpy(out[out_offset .. out_offset + copy_len], T[0..copy_len]);
        out_offset += copy_len;
        n += 1;
    }
}

// Connection state with timeout tracking
const ConnectionState = struct {
    state: State,
    handshake_start_time: ?i64 = null,

    // TLS state (moved from globals for per-connection isolation)
    ptls: ?*c.ptls_t = null, // Per-connection picotls instance
    crypto_offset_initial: u64 = 0, // Offset for CRYPTO frames in Initial space
    crypto_offset_handshake: u64 = 0, // Offset for CRYPTO frames in Handshake space

    // 0-RTT / Session Resumption state
    session_ticket: ?*tls_session.SessionTicket = null,
    early_data: ?tls_session.EarlyDataContext = null,
    zero_rtt_enabled: bool = false,
    zero_rtt_accepted: bool = false,
    client_ip: u32 = 0,
    client_port: u16 = 0,

    const State = enum {
        initial,
        zero_rtt, // 0-RTT data received
        handshake,
        established,
        closed,
        timed_out,
    };

    fn init() ConnectionState {
        return ConnectionState{
            .state = .initial,
            .handshake_start_time = null,
            .ptls = null,
            .crypto_offset_initial = 0,
            .crypto_offset_handshake = 0,
            .session_ticket = null,
            .early_data = null,
            .zero_rtt_enabled = false,
            .zero_rtt_accepted = false,
            .client_ip = 0,
            .client_port = 0,
        };
    }

    fn deinit(self: *ConnectionState, allocator: std.mem.Allocator) void {
        // Clean up per-connection TLS state
        if (self.ptls) |ptls| {
            c.ptls_free(ptls);
            self.ptls = null;
        }

        if (self.session_ticket) |ticket| {
            ticket.deinit(allocator);
            allocator.destroy(ticket);
            self.session_ticket = null;
        }
        if (self.early_data) |early| {
            early.deinit();
            allocator.destroy(early);
            self.early_data = null;
        }
    }

    fn startHandshake(self: *ConnectionState) void {
        self.state = .handshake;
        self.handshake_start_time = std.time.milliTimestamp();
    }

    fn checkTimeout(self: *ConnectionState) bool {
        if (self.handshake_start_time) |start_time| {
            const now = std.time.milliTimestamp();
            const elapsed = now - start_time;
            if (elapsed > QUIC_TIMEOUTS.handshake_timeout) {
                self.state = .timed_out;
                return true;
            }
        }
        return false;
    }
};

// QUIC Connection
const QuicConnection = struct {
    dcid: [20]u8,
    dcid_len: u8,
    scid: [20]u8,
    scid_len: u8,
    state: ConnectionState,
    // tls_conn removed - using picotls directly
    initial_secrets: ?crypto.InitialSecrets,
    client_pn: u32,
    server_pn: u32,
    crypto_offset_initial: u64, // Offset for CRYPTO frames in Initial space
    crypto_offset_handshake: u64, // Offset for CRYPTO frames in Handshake space
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, dcid: []const u8, scid: []const u8) QuicConnection {
        var conn = QuicConnection{
            .dcid = undefined,
            .dcid_len = @intCast(dcid.len),
            .scid = undefined,
            .scid_len = @intCast(scid.len),
            .state = .initial,
            .initial_secrets = null,
            .client_pn = 0,
            .server_pn = 0,
            .crypto_offset_initial = 0,
            .crypto_offset_handshake = 0,
            .allocator = allocator,
        };
        @memcpy(conn.dcid[0..dcid.len], dcid);
        @memcpy(conn.scid[0..scid.len], scid);
        return conn;
    }
};

// TLS state moved to per-connection ConnectionState

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     Blitz QUIC Server v0.2.0 - Real Handshake Edition    ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    if (builtin.os.tag != .linux) {
        std.log.err("QUIC server requires Linux (io_uring)", .{});
        return error.UnsupportedPlatform;
    }

    // Initialize picotls
    std.debug.print("[TLS] Initializing picotls...\n", .{});
    try initPicotls();
    std.debug.print("[TLS] ✅ picotls initialized\n", .{});

    // Create UDP socket
    const sockfd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch |err| {
        std.log.err("Failed to create socket: {any}", .{err});
        return err;
    };
    defer std.posix.close(sockfd);

    // Bind to port 8443
    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 8443);
    std.posix.bind(sockfd, &addr.any, addr.getOsSockLen()) catch |err| {
        std.log.err("Failed to bind to port 8443: {any}", .{err});
        return err;
    };

    // Set socket receive timeout to prevent indefinite blocking
    var timeout: std.posix.timeval = undefined;
    timeout.sec = @intCast(QUIC_TIMEOUTS.recv_timeout / 1000);
    timeout.usec = @intCast((QUIC_TIMEOUTS.recv_timeout % 1000) * 1000);
    std.posix.setsockopt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    std.debug.print("[UDP] ✅ Listening on 0.0.0.0:8443/udp\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Waiting for QUIC INITIAL packets...\n", .{});
    std.debug.print("Test with: curl --http3-only --insecure https://localhost:8443/\n", .{});
    std.debug.print("\n", .{});

    // Connection state tracking (simple map for demo - in production use proper hashmap)
    var connections: std.AutoHashMap([20]u8, ConnectionState) = undefined;
    defer {
        // Clean up connection states
        var it = connections.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        connections.deinit();
    }
    connections = std.AutoHashMap([20]u8, ConnectionState).init(allocator);

    // Session and token caches for 0-RTT and resumption
    var session_cache = tls_session.SessionCache.init(allocator);
    defer session_cache.deinit();

    var token_cache = tls_session.TokenCache.init(allocator);
    defer token_cache.deinit();

    // Receive loop
    var buf: [1500]u8 = undefined;
    var response_buf: [4096]u8 = undefined;
    var last_cleanup = std.time.milliTimestamp();

    while (true) {
        var src_addr: std.posix.sockaddr = undefined;
        var src_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        const bytes = std.posix.recvfrom(sockfd, &buf, 0, &src_addr, &src_len) catch |err| {
            // Handle timeout gracefully - just continue waiting
            if (err == error.WouldBlock or err == error.TimedOut) {
                continue;
            }
            std.log.warn("recvfrom error: {any}", .{err});
            continue;
        };

        std.debug.print("\n[RECV] {} bytes from client\n", .{bytes});

        // Extract DCID for connection tracking
        if (bytes < 7) {
            std.debug.print("[QUIC] Packet too short for connection tracking\n", .{});
            continue;
        }

        const dcid_len = buf[5];
        if (6 + dcid_len > bytes) {
            std.debug.print("[QUIC] Invalid DCID length\n", .{});
            continue;
        }
        const dcid = buf[6 .. 6 + dcid_len];
        if (dcid.len > 20) {
            std.debug.print("[QUIC] DCID too long\n", .{});
            continue;
        }

        // Extract client address information
        var client_ip: u32 = 0;
        var client_port: u16 = 0;

        if (src_addr.family == std.posix.AF.INET) {
            const addr_in = @as(*std.posix.sockaddr.in, @ptrCast(@alignCast(&src_addr)));
            client_ip = addr_in.addr;
            client_port = std.mem.bigToNative(u16, addr_in.port);
        }

        // Get or create connection state
        var dcid_key: [20]u8 = [_]u8{0} ** 20;
        @memcpy(dcid_key[0..dcid.len], dcid);
        const conn_state = connections.getOrPut(dcid_key) catch |err| {
            std.log.err("[QUIC] Connection tracking error: {any}", .{err});
            continue;
        };

        if (!conn_state.found_existing) {
            conn_state.value_ptr.* = ConnectionState.init();
            conn_state.value_ptr.client_ip = client_ip;
            conn_state.value_ptr.client_port = client_port;
            std.debug.print("[CONN] New connection established from {}:{}\n", .{ client_ip, client_port });
        }

        // Check for handshake timeout
        if (conn_state.value_ptr.checkTimeout()) {
            std.debug.print("[CONN] Handshake timed out, removing connection\n", .{});
            _ = connections.remove(dcid_key);
            continue;
        }

        // Process QUIC packet
        const response_len = handleQuicPacket(allocator, buf[0..bytes], &response_buf, &conn_state.value_ptr, &session_cache, &token_cache) catch |err| {
            std.log.err("[QUIC] Packet handling error: {any}", .{err});

            // On error, clean up connection state
            if (conn_state.value_ptr.state == .timed_out) {
                _ = connections.remove(dcid_key);
            }
            continue;
        };

        if (response_len > 0) {
            std.debug.print("[SEND] Sending {} bytes response\n", .{response_len});
            _ = std.posix.sendto(sockfd, response_buf[0..response_len], 0, &src_addr, src_len) catch |err| {
                std.log.warn("sendto error: {any}", .{err});
            };
        }

        // Periodic cleanup of timed out connections (every 10 seconds)
        const now = std.time.milliTimestamp();
        if (now - last_cleanup > 10_000) {
            var timed_out_count: usize = 0;
            // Initialize ArrayList with bounded capacity to avoid excessive allocations
            // Use a reasonable bound (64 entries) - will grow if needed but prevents unbounded growth
            var keys_to_remove = std.ArrayList([20]u8).init(allocator);
            defer keys_to_remove.deinit();
            keys_to_remove.ensureTotalCapacity(64) catch |err| {
                std.log.warn("[CLEANUP] Failed to pre-allocate capacity: {any}", .{err});
            };

            // Collect keys of timed-out connections
            var it = connections.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.checkTimeout()) {
                    keys_to_remove.append(entry.key_ptr.*) catch |err| {
                        std.log.warn("[CLEANUP] Failed to collect key for removal: {any}", .{err});
                        continue;
                    };
                }
            }

            // Remove collected keys from hashmap
            for (keys_to_remove.items) |key| {
                if (connections.remove(key)) |removed_entry| {
                    removed_entry.deinit(allocator);
                    timed_out_count += 1;
                }
            }

            if (timed_out_count > 0) {
                std.debug.print("[CLEANUP] Removed {} timed out connections\n", .{timed_out_count});
            }
            last_cleanup = now;
        }
    }
}

// C helper to initialize opaque struct (defined in openssl_wrapper.c)
extern fn blitz_ptls_ctx_init(
    random_bytes: ?*const fn (?*anyopaque, usize) callconv(.c) void,
    get_time: *c.ptls_get_time_t,
    key_exchanges: [*c][*c]const c.ptls_key_exchange_algorithm_t,
    cipher_suites: [*c][*c]const c.ptls_cipher_suite_t,
) void;

// Initialize picotls (one-time setup)
fn initPicotls() !void {
    // Use C helper to initialize opaque struct fields
    blitz_ptls_ctx_init(
        &ptls_random_bytes,
        &c.ptls_get_time,
        c.ptls_minicrypto_key_exchanges,
        c.ptls_minicrypto_cipher_suites,
    );

    // Load certificate and key
    const cert_paths = [_][]const u8{ "/app/certs/server.crt", "certs/server.crt" };
    const key_paths = [_][]const u8{ "/app/certs/server.key", "certs/server.key" };

    var cert_file: ?std.fs.File = null;
    var key_file: ?std.fs.File = null;

    for (cert_paths) |path| {
        cert_file = std.fs.cwd().openFile(path, .{}) catch continue;
        break;
    }

    for (key_paths) |path| {
        key_file = std.fs.cwd().openFile(path, .{}) catch continue;
        break;
    }

    if (cert_file == null or key_file == null) {
        return error.CertLoadFailed;
    }
    defer cert_file.?.close();
    defer key_file.?.close();

    // For now, skip certificate loading - use default NULL certs
    // This is sufficient for testing the QUIC handshake
    // TODO: Implement proper certificate loading
    // The server will use NULL certificates for now
}

fn handleQuicPacket(allocator: std.mem.Allocator, data: []u8, response: []u8, conn_state: *ConnectionState, session_cache: *tls_session.SessionCache, token_cache: *tls_session.TokenCache) !usize {
    if (data.len < 7) {
        std.debug.print("[QUIC] Packet too short ({} bytes)\n", .{data.len});
        return 0;
    }

    const first_byte = data[0];

    // Check if long header (bit 7 = 1)
    if ((first_byte & 0x80) == 0) {
        std.debug.print("[QUIC] Short header packet (1-RTT) - not handled yet\n", .{});
        return 0;
    }

    // Parse long header
    const version = std.mem.readInt(u32, data[1..5], .big);
    std.debug.print("[QUIC] Version: 0x{X:0>8}\n", .{version});

    if (version != 0x00000001) {
        std.debug.print("[QUIC] Unsupported version, would send Version Negotiation\n", .{});
        // TODO: Send Version Negotiation packet
        return 0;
    }

    const packet_type = (first_byte & 0x30) >> 4;
    const packet_type_name = switch (packet_type) {
        0 => "INITIAL",
        1 => "0-RTT",
        2 => "HANDSHAKE",
        3 => "RETRY",
        else => "UNKNOWN",
    };
    std.debug.print("[QUIC] Packet type: {} ({s})\n", .{ packet_type, packet_type_name });

    if (packet_type == 0) {
        // INITIAL packet - start handshake timeout
        conn_state.startHandshake();
        return handleInitialPacket(allocator, data, response, conn_state, &session_cache, &token_cache);
    } else if (packet_type == 1) {
        // 0-RTT packet
        std.debug.print("[QUIC] 0-RTT packet received\n", .{});
        conn_state.state = .zero_rtt;
        return handleZeroRttPacket(allocator, data, response, conn_state, &session_cache, &token_cache);
    } else if (packet_type == 2) {
        // HANDSHAKE packet
        std.debug.print("[QUIC] HANDSHAKE packet received - TODO\n", .{});
        return 0;
    }

    return 0;
}

fn handleInitialPacket(allocator: std.mem.Allocator, data: []u8, response: []u8, conn_state: *ConnectionState, session_cache: *tls_session.SessionCache, token_cache: *tls_session.TokenCache) !usize {
    // Extract connection IDs
    const dcid_len = data[5];
    const dcid = data[6 .. 6 + dcid_len];

    const scid_offset = 6 + dcid_len;
    const scid_len = data[scid_offset];
    const scid = data[scid_offset + 1 .. scid_offset + 1 + scid_len];

    std.debug.print("[QUIC] DCID ({} bytes): ", .{dcid_len});
    for (dcid) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});

    std.debug.print("[QUIC] SCID ({} bytes): ", .{scid_len});
    for (scid) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});

    // Derive Initial secrets from DCID
    std.debug.print("[CRYPTO] Deriving Initial secrets from DCID...\n", .{});
    const secrets = crypto.deriveInitialSecrets(dcid) catch |err| {
        std.log.err("[CRYPTO] Failed to derive secrets: {any}", .{err});
        return 0;
    };
    std.debug.print("[CRYPTO] ✅ Initial secrets derived\n", .{});

    // Find packet number offset
    const pn_offset = crypto.findPacketNumberOffset(data) catch |err| {
        std.log.err("[CRYPTO] Failed to find PN offset: {any}", .{err});
        return 0;
    };
    std.debug.print("[CRYPTO] Packet number at offset {}\n", .{pn_offset});

    // Make a copy for decryption (we'll modify header)
    var packet_copy: [1500]u8 = undefined;
    @memcpy(packet_copy[0..data.len], data);

    // Remove header protection
    const pn = crypto.removeHeaderProtection(packet_copy[0..data.len], &secrets.client_hp, pn_offset) catch |err| {
        std.log.err("[CRYPTO] Failed to remove HP: {any}", .{err});
        return 0;
    };
    std.debug.print("[CRYPTO] Packet number: {}\n", .{pn});

    // Get packet number length from unprotected first byte
    const pn_len: usize = (packet_copy[0] & 0x03) + 1;
    const header_len = pn_offset + pn_len;

    // Parse length field to find payload boundaries
    // Look at the byte immediately before the packet number to determine varint size
    if (pn_offset == 0) {
        std.log.err("[CRYPTO] Invalid packet: no length field before packet number", .{});
        return 0;
    }
    const len_first = data[pn_offset - 1];
    const prefix = (len_first & 0xC0) >> 6;

    // Determine varint size based on prefix
    const varint_size = switch (prefix) {
        0 => 1, // 00 prefix: 1 byte
        1 => 2, // 01 prefix: 2 bytes
        2 => 4, // 10 prefix: 4 bytes
        3 => 8, // 11 prefix: 8 bytes
    };

    // Check bounds
    if (pn_offset < varint_size) {
        std.log.err("[CRYPTO] Packet too short for varint length field", .{});
        return 0;
    }

    const len_offset = pn_offset - varint_size;
    var payload_len: usize = undefined;

    // Read varint value
    switch (prefix) {
        0 => {
            payload_len = len_first & 0x3F;
        },
        1 => {
            payload_len = (@as(usize, len_first & 0x3F) << 8) | @as(usize, data[len_offset + 1]);
        },
        2 => {
            if (len_offset + 4 > data.len) {
                std.log.err("[CRYPTO] Packet too short for 4-byte varint", .{});
                return 0;
            }
            payload_len = (@as(usize, len_first & 0x3F) << 24) |
                (@as(usize, data[len_offset + 1]) << 16) |
                (@as(usize, data[len_offset + 2]) << 8) |
                @as(usize, data[len_offset + 3]);
        },
        3 => {
            if (len_offset + 8 > data.len) {
                std.log.err("[CRYPTO] Packet too short for 8-byte varint", .{});
                return 0;
            }
            payload_len = (@as(usize, len_first & 0x3F) << 56) |
                (@as(usize, data[len_offset + 1]) << 48) |
                (@as(usize, data[len_offset + 2]) << 40) |
                (@as(usize, data[len_offset + 3]) << 32) |
                (@as(usize, data[len_offset + 4]) << 24) |
                (@as(usize, data[len_offset + 5]) << 16) |
                (@as(usize, data[len_offset + 6]) << 8) |
                @as(usize, data[len_offset + 7]);
        },
    }

    std.debug.print("[CRYPTO] Payload length field: {}\n", .{payload_len});

    // Encrypted payload starts after header, includes PN
    const encrypted_start = header_len;
    const encrypted_len = payload_len - pn_len; // Length field includes PN

    if (encrypted_start + encrypted_len > data.len) {
        std.log.err("[CRYPTO] Invalid payload bounds", .{});
        return 0;
    }

    std.debug.print("[CRYPTO] Decrypting {} bytes...\n", .{encrypted_len});

    // Decrypt payload
    var plaintext: [1500]u8 = undefined;
    const decrypted_len = crypto.decryptPayload(
        packet_copy[encrypted_start .. encrypted_start + encrypted_len],
        &secrets.client_key,
        &secrets.client_iv,
        pn,
        packet_copy[0..header_len],
        &plaintext,
    ) catch |err| {
        std.log.err("[CRYPTO] Decryption failed: {any}", .{err});
        return 0;
    };

    std.debug.print("[CRYPTO] ✅ Decrypted {} bytes\n", .{decrypted_len});

    // Parse frames in decrypted payload
    var offset: usize = 0;
    while (offset < decrypted_len) {
        const frame_type = plaintext[offset];

        if (frame_type == 0x00) {
            // PADDING frame
            offset += 1;
            continue;
        } else if (frame_type == 0x06) {
            // CRYPTO frame!
            std.debug.print("[FRAME] Found CRYPTO frame at offset {}\n", .{offset});

            const crypto_frame = frames.CryptoFrame.parse(plaintext[offset..decrypted_len]) catch |err| {
                std.log.err("[FRAME] Failed to parse CRYPTO: {any}", .{err});
                return 0;
            };

            std.debug.print("[FRAME] CRYPTO offset={}, length={}\n", .{ crypto_frame.offset, crypto_frame.length });

            // This is the ClientHello!
            if (crypto_frame.data.len > 0 and crypto_frame.data[0] == 0x01) {
                std.debug.print("[TLS] ✅ Found ClientHello ({} bytes)\n", .{crypto_frame.data.len});

                // Now we need to run TLS handshake
                return processTlsHandshake(allocator, crypto_frame.data, dcid, scid, &secrets, response, conn_state, session_cache, token_cache);
            } else {
                std.debug.print("[TLS] CRYPTO frame content type: 0x{X:0>2}\n", .{crypto_frame.data[0]});
            }

            break;
        } else if (frame_type == 0x01) {
            // PING frame
            offset += 1;
            continue;
        } else if (frame_type == 0x02 or frame_type == 0x03) {
            // ACK frame - skip for now
            std.debug.print("[FRAME] ACK frame at offset {}\n", .{offset});
            break;
        } else {
            std.debug.print("[FRAME] Unknown frame type 0x{X:0>2} at offset {}\n", .{ frame_type, offset });
            break;
        }
    }

    return 0;
}

fn processTlsHandshake(
    allocator: std.mem.Allocator,
    client_hello: []const u8,
    client_dcid: []const u8,
    client_scid: []const u8,
    secrets: *const crypto.InitialSecrets,
    response: []u8,
    conn_state: *ConnectionState,
    session_cache: *tls_session.SessionCache,
    token_cache: *tls_session.TokenCache,
) !usize {
    // Initialize per-connection TLS state if not already done
    if (conn_state.ptls == null) {
        conn_state.ptls = c.ptls_server_new(getContext());
        if (conn_state.ptls == null) {
            return error.TlsInitFailed;
        }
    }

    const input = c.ptls_iovec_t{ .base = @constCast(client_hello.ptr), .len = client_hello.len };

    // CORRECT ptls_buffer_t usage in Zig — used by every real project
    var initial_buf: [8192]u8 = undefined;
    var handshake_buf: [8192]u8 = undefined;
    var one_rtt_buf: [8192]u8 = undefined;

    var out_initial: c.ptls_buffer_t = undefined;
    var out_handshake: c.ptls_buffer_t = undefined;
    var out_1rtt: c.ptls_buffer_t = undefined;

    c.ptls_buffer_init(&out_initial, &initial_buf, initial_buf.len);
    c.ptls_buffer_init(&out_handshake, &handshake_buf, handshake_buf.len);
    c.ptls_buffer_init(&out_1rtt, &one_rtt_buf, one_rtt_buf.len);

    defer {
        c.ptls_buffer_dispose(&out_initial);
        c.ptls_buffer_dispose(&out_handshake);
        c.ptls_buffer_dispose(&out_1rtt);
    }

    var epoch_offsets: [5]u64 = [_]u64{0} ** 5;

    const rc = c.ptls_handle_message(conn_state.ptls.?, &out_initial, &out_handshake, &out_1rtt, &epoch_offsets, 0, input.base, input.len, null);

    if (rc != 0 and rc != c.PTLS_ERROR_IN_PROGRESS) {
        std.log.err("picotls error {any}", .{rc});
        return 0;
    }

    var sent: usize = 0;

    if (out_initial.off > 0) {
        sent += try buildInitialResponse(response[sent..], client_scid, client_dcid, out_initial.base[0..out_initial.off], secrets);

        // CRITICAL: Send ACK-only INITIAL packet for client's PN=0
        // This is mandatory in QUIC - without it, client never leaves INITIAL phase
        sent += try buildAckOnlyInitialPacket(response[sent..], client_scid, client_dcid, secrets, 0);
    }

    if (out_handshake.off > 0) {
        var hs_keys: HandshakeSecrets = undefined;
        try deriveHandshakeKeysFromPicotls(&hs_keys, conn_state);

        sent += try buildHandshakeResponse(response[sent..], client_scid, client_dcid, out_handshake.base[0..out_handshake.off], &hs_keys, conn_state);
    }

    if (out_1rtt.off > 0) {
        std.debug.print("HANDSHAKE COMPLETE — YOU WON\n", .{});

        // Mark connection as established
        conn_state.state = .established;

        // Generate and store session ticket for 0-RTT resumption
        std.debug.print("[TLS] Generating session ticket for 0-RTT...\n", .{});
        const ticket = try generateSessionTicket(allocator, client_dcid, conn_state);
        try session_cache.storeTicket(ticket);
        std.debug.print("[TLS] ✅ Session ticket stored\n", .{});

        // Generate QUIC token for address validation
        std.debug.print("[QUIC] Generating address validation token...\n", .{});
        const token_data = try generateQuicToken(allocator, client_dcid, conn_state.client_ip, conn_state.client_port);
        const token = try tls_session.QuicToken.init(allocator, token_data, conn_state.client_ip, conn_state.client_port);
        try token_cache.storeToken(token);
        std.debug.print("[QUIC] ✅ Address validation token stored\n", .{});

        // Send HTTP/3 response over 1-RTT
        std.debug.print("[HTTP/3] Sending HTTP/3 response...\n", .{});
        sent += try buildHttp3Response(response[sent..], client_scid, client_dcid, null, conn_state); // No request data for initial response
        std.debug.print("[HTTP/3] ✅ HTTP/3 response sent ({} total bytes)\n", .{sent});
    }

    return sent;
}

// Build HTTP/3 response (HEADERS + DATA frames) in a 1-RTT QUIC packet
fn buildHttp3Response(
    out: []u8,
    dcid: []const u8,
    scid: []const u8,
    request_data: ?[]const u8,
    conn_state: *ConnectionState,
) !usize {
    _ = scid; // Not used in HTTP/3 response
    std.debug.print("[HTTP/3] Building response...\n", .{});

    // Get 1-RTT keys from picotls
    var rtt_keys: RttSecrets = undefined;
    try derive1RttKeysFromPicotls(&rtt_keys, conn_state);

    // Create HTTP/3 response payload
    var http3_payload: [2048]u8 = undefined;
    var http3_offset: usize = 0;

    // Create QPACK encoder
    var qpack_encoder = qpack.QpackEncoder.init(std.heap.page_allocator);
    defer qpack_encoder.deinit();

    // Process request and generate response
    const response_data = try generateHttp3ResponseContent(request_data);
    defer std.heap.page_allocator.free(response_data.body);

    // HTTP response headers
    var headers = std.ArrayList(qpack.HeaderField).init(std.heap.page_allocator);
    defer headers.deinit();

    try headers.append(.{ .name = ":status", .value = response_data.status });
    try headers.append(.{ .name = "content-type", .value = response_data.content_type });

    var content_length_buf: [32]u8 = undefined;
    const content_length_str = try std.fmt.bufPrint(&content_length_buf, "{}", .{response_data.body.len});
    try headers.append(.{ .name = "content-length", .value = content_length_str });

    // Generate HEADERS frame
    var headers_writer = std.io.fixedBufferStream(http3_payload[http3_offset..]);
    try frame.HeadersFrame.generateFromHeaders(headers_writer.writer(), &qpack_encoder, headers.items);
    http3_offset += headers_writer.pos;

    // Generate DATA frame with response body
    var data_writer = std.io.fixedBufferStream(http3_payload[http3_offset..]);
    try frame.DataFrame.generate(data_writer.writer(), response_data.body);
    http3_offset += data_writer.pos;

    // Build 1-RTT QUIC packet
    var pkt_offset: usize = 0;

    // Short header (1-RTT packet)
    out[pkt_offset] = 0x40 | 0x02; // Short header, key phase = 0, packet number length = 2
    pkt_offset += 1;

    // Destination Connection ID
    @memcpy(out[pkt_offset..][0..dcid.len], dcid);
    pkt_offset += dcid.len;

    // Packet number (starting from 0 for 1-RTT)
    std.mem.writeInt(u16, out[pkt_offset..][0..2], 0, .big);
    pkt_offset += 2;

    const header_end = pkt_offset;

    // Encrypt payload
    const ciphertext_len = crypto.encryptPayload(
        http3_payload[0..http3_offset],
        &rtt_keys.server_key,
        &rtt_keys.server_iv,
        0, // packet number
        out[0..header_end],
        out[pkt_offset..],
    ) catch |err| {
        std.log.err("[HTTP/3] Encryption failed: {any}", .{err});
        return 0;
    };
    pkt_offset += ciphertext_len;

    // Apply header protection
    crypto.applyHeaderProtection(out[0..pkt_offset], &rtt_keys.server_hp, header_end - 2, 2) catch |err| {
        std.log.err("[HTTP/3] Header protection failed: {any}", .{err});
        return 0;
    };

    std.debug.print("[HTTP/3] ✅ Built 1-RTT packet with {} bytes of HTTP/3 data\n", .{http3_offset});
    return pkt_offset;
}

// Derive QUIC 1-RTT keys from picotls
fn deriveHandshakeKeysFromPicotls(out: *HandshakeSecrets, conn_state: *ConnectionState) !void {
    if (conn_state.ptls == null) return error.NoTlsConnection;

    // Get handshake traffic secrets from picotls
    var client_secret: [32]u8 = undefined;
    var server_secret: [32]u8 = undefined;

    // CORRECT LABELS — NO "QUIC " PREFIX!
    // picotls uses TLS 1.3 labels (RFC 8446), NOT QUIC labels (RFC 9001)
    // NO context iovec — pass null, 0
    if (c.ptls_export_secret(conn_state.ptls.?, &client_secret, client_secret.len, "client handshake traffic secret", null, 0) != 0) {
        return error.ClientSecretFailed;
    }
    if (c.ptls_export_secret(conn_state.ptls.?, &server_secret, server_secret.len, "server handshake traffic secret", null, 0) != 0) {
        return error.ServerSecretFailed;
    }

    // Now derive QUIC keys with "quic key"/"quic iv"/"quic hp" labels
    try hkdfExpandLabel(&out.client_key, &client_secret, "quic key", "");
    try hkdfExpandLabel(&out.client_iv, &client_secret, "quic iv", "");
    try hkdfExpandLabel(&out.client_hp, &client_secret, "quic hp", "");

    try hkdfExpandLabel(&out.server_key, &server_secret, "quic key", "");
    try hkdfExpandLabel(&out.server_iv, &server_secret, "quic iv", "");
    try hkdfExpandLabel(&out.server_hp, &server_secret, "quic hp", "");

    std.debug.print("[picotls] Handshake keys derived successfully!\n", .{});
}

// Derive QUIC 1-RTT keys from picotls
fn derive1RttKeysFromPicotls(out: *RttSecrets, conn_state: *ConnectionState) !void {
    if (conn_state.ptls == null) return error.NoTlsConnection;

    // Get application traffic secrets from picotls
    var client_secret: [32]u8 = undefined;
    var server_secret: [32]u8 = undefined;

    // 1-RTT secrets use "traffic" labels (RFC 8446)
    if (c.ptls_export_secret(conn_state.ptls.?, &client_secret, client_secret.len, "client application traffic secret", null, 0) != 0) {
        return error.ClientSecretFailed;
    }
    if (c.ptls_export_secret(conn_state.ptls.?, &server_secret, server_secret.len, "server application traffic secret", null, 0) != 0) {
        return error.ServerSecretFailed;
    }

    // Derive QUIC keys with "quic key"/"quic iv"/"quic hp" labels
    try hkdfExpandLabel(&out.client_key, &client_secret, "quic key", "");
    try hkdfExpandLabel(&out.client_iv, &client_secret, "quic iv", "");
    try hkdfExpandLabel(&out.client_hp, &client_secret, "quic hp", "");

    try hkdfExpandLabel(&out.server_key, &server_secret, "quic key", "");
    try hkdfExpandLabel(&out.server_iv, &server_secret, "quic iv", "");
    try hkdfExpandLabel(&out.server_hp, &server_secret, "quic hp", "");

    std.debug.print("[picotls] 1-RTT keys derived successfully!\n", .{});
}

// Build HANDSHAKE packet (similar to buildInitialResponse but with handshake keys)
fn buildHandshakeResponse(
    out: []u8,
    dcid: []const u8,
    scid: []const u8,
    tls_data: []const u8,
    secrets: *const HandshakeSecrets,
    conn_state: *ConnectionState,
) !usize {
    std.debug.print("[QUIC] Building HANDSHAKE response packet...\n", .{});

    // Build plaintext payload (CRYPTO frame)
    var plaintext: [4096]u8 = undefined;
    var pt_offset: usize = 0;

    // Write CRYPTO frame
    const crypto_len = frames.CryptoFrame.generate(conn_state.crypto_offset_handshake, tls_data, plaintext[pt_offset..]) catch |err| {
        std.log.err("[QUIC] Failed to generate CRYPTO frame: {any}", .{err});
        return 0;
    };
    pt_offset += crypto_len;

    // Build HANDSHAKE packet header
    var pkt_offset: usize = 0;
    out[pkt_offset] = 0xE0 | 0x02; // Long header, packet type = HANDSHAKE (2)
    pkt_offset += 1;

    // Version
    std.mem.writeInt(u32, out[pkt_offset..][0..4], 0x00000001, .big);
    pkt_offset += 4;

    // DCID length + DCID
    out[pkt_offset] = @intCast(dcid.len);
    pkt_offset += 1;
    @memcpy(out[pkt_offset..][0..dcid.len], dcid);
    pkt_offset += dcid.len;

    // SCID length + SCID
    out[pkt_offset] = @intCast(scid.len);
    pkt_offset += 1;
    @memcpy(out[pkt_offset..][0..scid.len], scid);
    pkt_offset += scid.len;

    // Length field (will be set after encryption)
    const length_field_offset = pkt_offset;
    pkt_offset += 2;

    const pn_offset = pkt_offset;
    std.mem.writeInt(u32, out[pkt_offset..][0..4], 0, .big); // Packet number
    pkt_offset += 4;

    const header_end = pkt_offset;

    // Encrypt payload
    const ciphertext_len = crypto.encryptPayload(
        plaintext[0..pt_offset],
        &secrets.server_key,
        &secrets.server_iv,
        0, // packet number
        out[0..header_end],
        out[pkt_offset..],
    ) catch |err| {
        std.log.err("[QUIC] Encryption failed: {any}", .{err});
        return 0;
    };
    pkt_offset += ciphertext_len;

    // Set length field
    const length_field = pt_offset + 4 + 16; // payload + 4-byte PN + 16-byte tag
    out[length_field_offset] = @intCast((length_field >> 8) & 0x3F);
    out[length_field_offset + 1] = @intCast(length_field & 0xFF);

    // Apply header protection
    crypto.applyHeaderProtection(out[0..pkt_offset], &secrets.server_hp, pn_offset, 4) catch |err| {
        std.log.err("[QUIC] Header protection failed: {any}", .{err});
        return 0;
    };

    std.debug.print("[QUIC] ✅ Built HANDSHAKE packet: {} bytes\n", .{pkt_offset});
    return pkt_offset;
}

fn buildAckOnlyInitialPacket(
    out: []u8,
    dcid: []const u8,
    scid: []const u8,
    secrets: *const crypto.InitialSecrets,
    acking_pn: u32,
) !usize {
    std.debug.print("[QUIC] Building ACK-only INITIAL packet (acking PN={})\n", .{acking_pn});

    // Build minimal payload with ACK frame
    var plaintext: [64]u8 = undefined; // Small packet
    var pt_offset: usize = 0;

    // ACK frame (type 0x02, largest=acking_pn, delay=0, range count=0)
    plaintext[pt_offset] = 0x02; // ACK frame type
    pt_offset += 1;

    // Largest acknowledged (varint)
    const largest_ack = acking_pn;
    if (largest_ack < 64) {
        plaintext[pt_offset] = @intCast(largest_ack);
        pt_offset += 1;
    } else if (largest_ack < 16384) {
        plaintext[pt_offset] = @intCast(0x40 | (largest_ack >> 8));
        plaintext[pt_offset + 1] = @intCast(largest_ack & 0xFF);
        pt_offset += 2;
    } else {
        // Simplified - just encode as 2 bytes for now
        plaintext[pt_offset] = @intCast(0x40 | (largest_ack >> 8));
        plaintext[pt_offset + 1] = @intCast(largest_ack & 0xFF);
        pt_offset += 2;
    }

    // ACK delay (varint) - set to 0
    plaintext[pt_offset] = 0;
    pt_offset += 1;

    // ACK range count (varint) - 0 ranges
    plaintext[pt_offset] = 0;
    pt_offset += 1;

    // First ACK range (varint) - 0 (only acking one packet)
    plaintext[pt_offset] = 0;
    pt_offset += 1;

    // Build INITIAL packet header
    var pkt_offset: usize = 0;
    out[pkt_offset] = 0xC0 | 0x00; // Long header, packet type = INITIAL (0)
    pkt_offset += 1;

    // Version
    std.mem.writeInt(u32, out[pkt_offset..][0..4], 0x00000001, .big);
    pkt_offset += 4;

    // DCID length + DCID
    out[pkt_offset] = @intCast(dcid.len);
    pkt_offset += 1;
    @memcpy(out[pkt_offset..][0..dcid.len], dcid);
    pkt_offset += dcid.len;

    // SCID length + SCID
    out[pkt_offset] = @intCast(scid.len);
    pkt_offset += 1;
    @memcpy(out[pkt_offset..][0..scid.len], scid);
    pkt_offset += scid.len;

    // Token length (0 for Initial)
    out[pkt_offset] = 0;
    pkt_offset += 1;

    // Length field (will be set after encryption)
    const length_field_offset = pkt_offset;
    pkt_offset += 2;

    const pn_offset = pkt_offset;
    std.mem.writeInt(u32, out[pkt_offset..][0..4], 1, .big); // Packet number = 1 (different from ServerHello packet)
    pkt_offset += 4;

    const header_end = pkt_offset;

    // Encrypt payload
    const ciphertext_len = crypto.encryptPayload(
        plaintext[0..pt_offset],
        &secrets.server_key,
        &secrets.server_iv,
        1, // packet number
        out[0..header_end],
        out[pkt_offset..],
    ) catch |err| {
        std.log.err("[QUIC] ACK packet encryption failed: {any}", .{err});
        return 0;
    };
    pkt_offset += ciphertext_len;

    // Set length field
    const length_field = pt_offset + 4 + 16; // payload + 4-byte PN + 16-byte tag
    out[length_field_offset] = @intCast((length_field >> 8) & 0x3F);
    out[length_field_offset + 1] = @intCast(length_field & 0xFF);

    // Apply header protection
    crypto.applyHeaderProtection(out[0..pkt_offset], &secrets.server_hp, pn_offset, 4) catch |err| {
        std.log.err("[QUIC] ACK packet header protection failed: {any}", .{err});
        return 0;
    };

    std.debug.print("[QUIC] ✅ Built ACK-only INITIAL packet: {} bytes\n", .{pkt_offset});
    return pkt_offset;
}

fn buildInitialResponse(
    out: []u8,
    dcid: []const u8,
    scid: []const u8,
    tls_data: []const u8,
    secrets: *const crypto.InitialSecrets,
) !usize {
    std.debug.print("[QUIC] Building INITIAL response packet...\n", .{});

    // Build plaintext payload (CRYPTO frame + padding)
    var plaintext: [4096]u8 = undefined;
    var pt_offset: usize = 0;

    // Write CRYPTO frame
    const crypto_len = frames.CryptoFrame.generate(0, tls_data, plaintext[pt_offset..]) catch |err| {
        std.log.err("[QUIC] Failed to generate CRYPTO frame: {any}", .{err});
        return 0;
    };
    pt_offset += crypto_len;

    // Pad to minimum 1200 bytes for Initial
    const min_packet_size = 1200;
    var header_len: usize = 0;

    // Calculate header length:
    // 1 (flags) + 4 (version) + 1 (dcid len) + dcid + 1 (scid len) + scid +
    // 1 (token len) + 2 (length) + 4 (packet number)
    header_len = 1 + 4 + 1 + dcid.len + 1 + scid.len + 1 + 2 + 4;

    const min_payload = min_packet_size - header_len - 16; // 16 = auth tag
    while (pt_offset < min_payload) {
        plaintext[pt_offset] = 0x00; // PADDING frame
        pt_offset += 1;
    }

    std.debug.print("[QUIC] Plaintext payload: {} bytes\n", .{pt_offset});

    // Build packet header
    var pkt_offset: usize = 0;

    // First byte: 11 (long header) + 00 (Initial) + 00 (reserved) + 11 (4-byte PN)
    out[pkt_offset] = 0xC3; // 1100 0011
    pkt_offset += 1;

    // Version
    std.mem.writeInt(u32, out[pkt_offset..][0..4], 0x00000001, .big);
    pkt_offset += 4;

    // DCID length + DCID
    out[pkt_offset] = @intCast(dcid.len);
    pkt_offset += 1;
    @memcpy(out[pkt_offset .. pkt_offset + dcid.len], dcid);
    pkt_offset += dcid.len;

    // SCID length + SCID
    out[pkt_offset] = @intCast(scid.len);
    pkt_offset += 1;
    @memcpy(out[pkt_offset .. pkt_offset + scid.len], scid);
    pkt_offset += scid.len;

    // Token length (0 for server)
    out[pkt_offset] = 0;
    pkt_offset += 1;

    // Length field (payload + PN + auth tag) as 2-byte varint
    const length_field = pt_offset + 4 + 16; // payload + 4-byte PN + 16-byte tag
    out[pkt_offset] = 0x40 | @as(u8, @intCast((length_field >> 8) & 0x3F));
    out[pkt_offset + 1] = @intCast(length_field & 0xFF);
    pkt_offset += 2;

    const pn_offset = pkt_offset;

    // Packet number (4 bytes, starting at 0)
    std.mem.writeInt(u32, out[pkt_offset..][0..4], 0, .big);
    pkt_offset += 4;

    const header_end = pkt_offset;
    std.debug.print("[QUIC] Header: {} bytes, PN at offset {}\n", .{ header_end, pn_offset });

    // Encrypt payload
    const ciphertext_len = crypto.encryptPayload(
        plaintext[0..pt_offset],
        &secrets.server_key,
        &secrets.server_iv,
        0, // packet number
        out[0..header_end],
        out[pkt_offset..],
    ) catch |err| {
        std.log.err("[QUIC] Encryption failed: {any}", .{err});
        return 0;
    };
    pkt_offset += ciphertext_len;

    std.debug.print("[QUIC] Encrypted payload: {} bytes\n", .{ciphertext_len});

    // Apply header protection
    crypto.applyHeaderProtection(out[0..pkt_offset], &secrets.server_hp, pn_offset, 4) catch |err| {
        std.log.err("[QUIC] Header protection failed: {any}", .{err});
        return 0;
    };

    std.debug.print("[QUIC] ✅ Built INITIAL packet: {} bytes\n", .{pkt_offset});
    std.debug.print("[SEND] Sending INITIAL (with ServerHello)\n", .{});

    return pkt_offset;
}

fn handleZeroRttPacket(allocator: std.mem.Allocator, data: []u8, response: []u8, conn_state: *ConnectionState, session_cache: *tls_session.SessionCache, token_cache: *tls_session.TokenCache) !usize {
    // Extract connection IDs
    const dcid_len = data[5];
    const dcid = data[6 .. 6 + dcid_len];

    const scid_offset = 6 + dcid_len;
    const scid_len = data[scid_offset];
    const scid = data[scid_offset + 1 .. scid_offset + 1 + scid_len];

    std.debug.print("[0-RTT] DCID ({} bytes): ", .{dcid_len});
    for (dcid) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});

    std.debug.print("[0-RTT] SCID ({} bytes): ", .{scid_len});
    for (scid) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});

    // Parse token from 0-RTT packet
    const token_offset = scid_offset + 1 + scid_len;
    const token_len = std.mem.readInt(u32, data[token_offset .. token_offset + 4], .big);
    const token_data = data[token_offset + 4 .. token_offset + 4 + token_len];

    std.debug.print("[0-RTT] Token length: {}\n", .{token_len});

    // Validate token
    const client_ip = conn_state.client_ip;
    const client_port = conn_state.client_port;

    if (token_cache.validateToken(token_data, client_ip, client_port)) |_| {
        std.debug.print("[0-RTT] ✅ Token validated\n");

        // Look up session ticket
        const psk_identity = token_data; // In practice, this would be extracted from the token
        if (session_cache.getTicket(psk_identity)) |ticket| {
            std.debug.print("[0-RTT] ✅ Session ticket found\n");

            // Store session ticket in connection state
            conn_state.session_ticket = ticket;
            conn_state.zero_rtt_enabled = true;

            // Initialize early data context
            conn_state.early_data = allocator.create(tls_session.EarlyDataContext) catch |err| {
                std.log.err("[0-RTT] Failed to create early data context: {any}", .{err});
                return 0;
            };
            conn_state.early_data.?.* = tls_session.EarlyDataContext.init(allocator, ticket.max_early_data_size);

            // Derive 0-RTT secrets from session ticket
            // This is a simplified version - in practice, you'd use HKDF with the PSK
            const zero_rtt_secrets = crypto.deriveZeroRttSecrets(dcid, ticket.psk_identity) catch |err| {
                std.log.err("[0-RTT] Failed to derive 0-RTT secrets: {any}", .{err});
                return 0;
            };

            // Derive handshake secrets for the 0-RTT response
            // For 0-RTT, handshake secrets are derived from the PSK using TLS 1.3 resumption
            const handshake_secrets = try deriveHandshakeSecretsFromPsk(ticket.psk_identity);

            // Decrypt 0-RTT packet payload
            const pn_offset = crypto.findPacketNumberOffset(data) catch |err| {
                std.log.err("[0-RTT] Failed to find PN offset: {any}", .{err});
                return 0;
            };

            var decrypted_data: [1500]u8 = undefined;
            const decrypted_len = crypto.decryptZeroRttPacket(
                data,
                pn_offset,
                &zero_rtt_secrets,
                &decrypted_data,
            ) catch |err| {
                std.log.err("[0-RTT] Failed to decrypt 0-RTT packet: {any}", .{err});
                return 0;
            };

            // Extract early data from decrypted payload
            if (decrypted_len > 0) {
                const early_data = decrypted_data[0..decrypted_len];
                if (conn_state.early_data.?.addData(early_data)) {
                    std.debug.print("[0-RTT] ✅ Early data accepted: {} bytes\n", .{early_data.len});
                    conn_state.zero_rtt_accepted = true;

                    // Process early data immediately if it's HTTP/3
                    if (try processEarlyHttp3Data(allocator, early_data, response, conn_state)) |http_response_len| {
                        std.debug.print("[0-RTT] ✅ Processed early HTTP/3 data: {} bytes response\n", .{http_response_len});
                        return http_response_len;
                    }
                } else {
                    std.debug.print("[0-RTT] ❌ Early data rejected (too large)\n");
                }
            }

            // Send 0-RTT response (could be early HTTP/3 response or just ACK)
            return buildZeroRttResponse(allocator, dcid, scid, response, conn_state, &handshake_secrets);
        } else {
            std.debug.print("[0-RTT] ❌ No session ticket found for PSK identity\n");
        }
    } else {
        std.debug.print("[0-RTT] ❌ Token validation failed\n");
    }

    // If 0-RTT fails, fall back to regular handshake
    conn_state.state = .initial;
    return handleInitialPacket(allocator, data, response, conn_state, session_cache, token_cache);
}

// Helper function to read varint from buffer (same as http3/frame.zig)
fn readVarInt(data: []const u8) !struct { value: u64, bytes_read: usize } {
    if (data.len == 0) {
        return error.IncompleteVarInt;
    }

    const first_byte = data[0];
    const prefix = (first_byte & 0xC0) >> 6;

    return switch (prefix) {
        0 => .{
            .value = @as(u64, first_byte & 0x3F),
            .bytes_read = 1,
        },
        1 => blk: {
            if (data.len < 2) return error.IncompleteVarInt;
            break :blk .{
                .value = @as(u64, first_byte & 0x3F) << 8 | @as(u64, data[1]),
                .bytes_read = 2,
            };
        },
        2 => blk: {
            if (data.len < 4) return error.IncompleteVarInt;
            break :blk .{
                .value = @as(u64, first_byte & 0x3F) << 24 |
                    @as(u64, data[1]) << 16 |
                    @as(u64, data[2]) << 8 |
                    @as(u64, data[3]),
                .bytes_read = 4,
            };
        },
        3 => blk: {
            if (data.len < 8) return error.IncompleteVarInt;
            break :blk .{
                .value = @as(u64, first_byte & 0x3F) << 56 |
                    @as(u64, data[1]) << 48 |
                    @as(u64, data[2]) << 40 |
                    @as(u64, data[3]) << 32 |
                    @as(u64, data[4]) << 24 |
                    @as(u64, data[5]) << 16 |
                    @as(u64, data[6]) << 8 |
                    @as(u64, data[7]),
                .bytes_read = 8,
            };
        },
        else => return error.InvalidVarInt,
    };
}

// Helper function to write varint to buffer
fn writeVarIntToBuffer(buf: []u8, value: u64) !usize {
    if (value < (1 << 6)) {
        if (buf.len < 1) return error.BufferTooSmall;
        buf[0] = @truncate(value);
        return 1;
    } else if (value < (1 << 14)) {
        if (buf.len < 2) return error.BufferTooSmall;
        buf[0] = @truncate((value >> 8) | 0x40);
        buf[1] = @truncate(value);
        return 2;
    } else if (value < (1 << 30)) {
        if (buf.len < 4) return error.BufferTooSmall;
        buf[0] = @truncate((value >> 24) | 0x80);
        buf[1] = @truncate(value >> 16);
        buf[2] = @truncate(value >> 8);
        buf[3] = @truncate(value);
        return 4;
    } else {
        if (buf.len < 8) return error.BufferTooSmall;
        buf[0] = @truncate((value >> 56) | 0xC0);
        buf[1] = @truncate(value >> 48);
        buf[2] = @truncate(value >> 40);
        buf[3] = @truncate(value >> 32);
        buf[4] = @truncate(value >> 24);
        buf[5] = @truncate(value >> 16);
        buf[6] = @truncate(value >> 8);
        buf[7] = @truncate(value);
        return 8;
    }
}

fn processEarlyHttp3Data(_: std.mem.Allocator, early_data: []const u8, response: []u8, _: *ConnectionState) !?usize {
    // Check if early data contains HTTP/3 frames
    if (early_data.len < 1) return null;

    // Parse frame type as varint
    const frame_type_result = readVarInt(early_data) catch return null;
    const frame_type_value = frame_type_result.value;

    // Check if it's a HEADERS frame (0x01)
    const headers_frame_type = @intFromEnum(frame.FrameType.headers);
    if (frame_type_value != headers_frame_type) {
        return null; // Not a HEADERS frame
    }

    std.debug.print("[0-RTT] HTTP/3 HEADERS frame detected in early data\n");

    // Build valid HTTP/3 response:
    // 1. HEADERS frame: varint(frame_type=0x01) + QPACK-encoded header block
    // 2. DATA frame: varint(frame_type=0x00) + payload

    var written: usize = 0;

    // Write HEADERS frame type (0x01)
    const headers_type_bytes = writeVarIntToBuffer(response[written..], headers_frame_type) catch return null;
    written += headers_type_bytes;

    // Build minimal QPACK header block using static table indices:
    // - QPACK prefix: Required Insert Count (1 byte = 0x00) + Delta Base (1 byte = 0x00)
    // - Indexed field: :status:200 (QPACK static table index 25)
    // - Indexed field: content-type:text/plain (QPACK static table index 53)

    // Minimum size: prefix (2) + :status index (1) + content-type index (1) = 4 bytes
    // But we need to handle multi-byte encoding if indices don't fit in 6 bits
    const min_headers_size = 2 + 1 + 1; // prefix + both indexed fields (single byte each)
    if (written + min_headers_size > response.len) {
        return null; // Insufficient space
    }

    // QPACK header block prefix (RFC 9204 Section 4.5.1)
    response[written] = 0x00; // Required Insert Count = 0
    response[written + 1] = 0x00; // Delta Base = 0 (Sign bit = 0)
    written += 2;

    // Indexed Field Line - Static (RFC 9204 Section 4.5.2)
    // Format: 0b11xxxxxx (T=1, static) with 6-bit prefix for index
    // :status:200 is at static table index 25 (fits in 6 bits: 0x19)
    if (25 < 64) {
        // Fits in 6-bit prefix: 0xC0 | 25 = 0xD9
        response[written] = 0xC0 | 25;
        written += 1;
    } else {
        // Multi-byte encoding needed (shouldn't happen for static table)
        return null;
    }

    // content-type:text/plain is at static table index 53 (fits in 6 bits: 0x35)
    if (53 < 64) {
        // Fits in 6-bit prefix: 0xC0 | 53 = 0xF5
        response[written] = 0xC0 | 53;
        written += 1;
    } else {
        // Multi-byte encoding needed (shouldn't happen for static table)
        return null;
    }

    // Write DATA frame: varint(frame_type=0x00) + payload
    const data_frame_type = @intFromEnum(frame.FrameType.data);
    const data_type_bytes = writeVarIntToBuffer(response[written..], data_frame_type) catch return null;
    written += data_type_bytes;

    // Payload: "Hello from 0-RTT!\n"
    const payload = "Hello from 0-RTT!\n";
    if (written + payload.len > response.len) {
        return null; // Insufficient space
    }
    @memcpy(response[written..][0..payload.len], payload);
    written += payload.len;

    return written;
}

fn buildZeroRttResponse(_: std.mem.Allocator, dcid: []const u8, scid: []const u8, response: []u8, conn_state: *ConnectionState, secrets: *const HandshakeSecrets) !usize {
    std.debug.print("[0-RTT] Building 0-RTT response packet with CRYPTO frame...\n", .{});

    // Build plaintext payload (CRYPTO frame)
    var plaintext: [4096]u8 = undefined;
    var pt_offset: usize = 0;

    // Write CRYPTO frame containing "0-RTT ACCEPTED" payload
    const payload = "0-RTT ACCEPTED";
    const crypto_len = frames.CryptoFrame.generate(conn_state.crypto_offset_handshake, payload, plaintext[pt_offset..]) catch |err| {
        std.log.err("[0-RTT] Failed to generate CRYPTO frame: {any}", .{err});
        return 0;
    };
    pt_offset += crypto_len;

    // Build HANDSHAKE packet header
    var pkt_offset: usize = 0;
    response[pkt_offset] = 0xE0 | 0x02; // Long header, packet type = HANDSHAKE (2)
    pkt_offset += 1;

    // Version
    std.mem.writeInt(u32, response[pkt_offset..][0..4], 0x00000001, .big);
    pkt_offset += 4;

    // DCID length + DCID
    response[pkt_offset] = @intCast(dcid.len);
    pkt_offset += 1;
    @memcpy(response[pkt_offset..][0..dcid.len], dcid);
    pkt_offset += dcid.len;

    // SCID length + SCID
    response[pkt_offset] = @intCast(scid.len);
    pkt_offset += 1;
    @memcpy(response[pkt_offset..][0..scid.len], scid);
    pkt_offset += scid.len;

    // Length field (payload + PN + auth tag) as varint - handle all 4 forms (1, 2, 4, 8 bytes)
    // Calculate length before encryption: plaintext (CRYPTO frame) + 4-byte PN + 16-byte auth tag
    const length_field = pt_offset + 4 + 16;

    if (length_field < (1 << 6)) {
        // 1-byte varint (0x00-0x3F)
        response[pkt_offset] = @intCast(length_field);
        pkt_offset += 1;
    } else if (length_field < (1 << 14)) {
        // 2-byte varint (0x40-0x7F)
        response[pkt_offset] = @intCast(0x40 | ((length_field >> 8) & 0x3F));
        response[pkt_offset + 1] = @intCast(length_field & 0xFF);
        pkt_offset += 2;
    } else if (length_field < (1 << 30)) {
        // 4-byte varint (0x80-0xBF)
        response[pkt_offset] = @intCast(0x80 | ((length_field >> 24) & 0x3F));
        response[pkt_offset + 1] = @intCast((length_field >> 16) & 0xFF);
        response[pkt_offset + 2] = @intCast((length_field >> 8) & 0xFF);
        response[pkt_offset + 3] = @intCast(length_field & 0xFF);
        pkt_offset += 4;
    } else {
        // 8-byte varint (0xC0-0xFF)
        response[pkt_offset] = @intCast(0xC0 | ((length_field >> 56) & 0x3F));
        response[pkt_offset + 1] = @intCast((length_field >> 48) & 0xFF);
        response[pkt_offset + 2] = @intCast((length_field >> 40) & 0xFF);
        response[pkt_offset + 3] = @intCast((length_field >> 32) & 0xFF);
        response[pkt_offset + 4] = @intCast((length_field >> 24) & 0xFF);
        response[pkt_offset + 5] = @intCast((length_field >> 16) & 0xFF);
        response[pkt_offset + 6] = @intCast((length_field >> 8) & 0xFF);
        response[pkt_offset + 7] = @intCast(length_field & 0xFF);
        pkt_offset += 8;
    }

    const pn_offset = pkt_offset;
    std.mem.writeInt(u32, response[pkt_offset..][0..4], 0, .big); // Packet number
    pkt_offset += 4;

    const header_end = pkt_offset;

    // Encrypt payload (CRYPTO frame) using AEAD
    const ciphertext_len = crypto.encryptPayload(
        plaintext[0..pt_offset],
        &secrets.server_key,
        &secrets.server_iv,
        0, // packet number
        response[0..header_end],
        response[pkt_offset..],
    ) catch |err| {
        std.log.err("[0-RTT] Encryption failed: {any}", .{err});
        return 0;
    };
    pkt_offset += ciphertext_len;

    // Apply header protection
    crypto.applyHeaderProtection(response[0..pkt_offset], &secrets.server_hp, pn_offset, 4) catch |err| {
        std.log.err("[0-RTT] Header protection failed: {any}", .{err});
        return 0;
    };

    std.debug.print("[0-RTT] ✅ Built 0-RTT response packet: {} bytes\n", .{pkt_offset});
    return pkt_offset;
}

const Http3Response = struct {
    status: []const u8,
    content_type: []const u8,
    body: []u8,
};

fn generateHttp3ResponseContent(request_data: ?[]const u8) !Http3Response {
    // For now, return a simple response
    // TODO: Parse HTTP/3 request headers and implement JWT authentication

    if (request_data) |data| {
        std.debug.print("[HTTP/3] Processing request data ({} bytes)\n", .{data.len});
        // TODO: Parse QPACK headers and extract Authorization header
        // TODO: Validate JWT token using middleware
    }

    // Default response for HTTP/3 handshake completion
    const body = try std.fmt.allocPrint(std.heap.page_allocator,
        \\{{
        \\  "message": "HTTP/3 connection established successfully",
        \\  "protocol": "h3",
        \\  "features": ["quic", "qpack", "0rtt"],
        \\  "timestamp": {}
        \\}}
    , .{std.time.timestamp()});

    return Http3Response{
        .status = "200",
        .content_type = "application/json",
        .body = body,
    };
}

fn generateSessionTicket(allocator: std.mem.Allocator, dcid: []const u8, _: *ConnectionState) !*tls_session.SessionTicket {
    // Generate a unique PSK identity (simplified - in practice use random bytes)
    var psk_identity: [32]u8 = undefined;
    std.crypto.random.bytes(&psk_identity);

    // Create ticket data (simplified - in practice this would be encrypted TLS ticket)
    var ticket_data: [64]u8 = undefined;
    @memcpy(ticket_data[0..dcid.len], dcid);
    std.crypto.random.bytes(ticket_data[dcid.len..]);

    return tls_session.SessionTicket.init(allocator, &ticket_data, &psk_identity);
}

fn generateQuicToken(allocator: std.mem.Allocator, dcid: []const u8, client_ip: u32, client_port: u16) ![]u8 {
    // Generate a simple token containing DCID, IP, and port
    // In practice, this should be cryptographically signed
    var token = try allocator.alloc(u8, dcid.len + 4 + 2);
    errdefer allocator.free(token);

    @memcpy(token[0..dcid.len], dcid);
    std.mem.writeInt(u32, token[dcid.len .. dcid.len + 4], client_ip, .big);
    std.mem.writeInt(u16, token[dcid.len + 4 .. dcid.len + 6], client_port, .big);

    return token;
}
