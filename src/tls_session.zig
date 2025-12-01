//! TLS session management for 0-RTT and session resumption
//! Handles TLS session tickets and early data (0-RTT) support

const std = @import("std");

/// TLS session ticket for session resumption
pub const SessionTicket = struct {
    /// Session ticket data (opaque blob from TLS library)
    ticket_data: []const u8,

    /// Associated server name (SNI)
    server_name: ?[]const u8,

    /// Ticket lifetime hint (seconds)
    lifetime_hint: u32,

    /// Creation timestamp
    created_at: i64,

    /// Maximum early data size (0-RTT)
    max_early_data_size: u32,

    /// PSK identity for this ticket
    psk_identity: []const u8,

    pub fn init(allocator: std.mem.Allocator, ticket_data: []const u8, psk_identity: []const u8) !SessionTicket {
        const ticket_data_copy = try allocator.dupe(u8, ticket_data);
        errdefer allocator.free(ticket_data_copy);

        const psk_identity_copy = try allocator.dupe(u8, psk_identity);
        errdefer allocator.free(psk_identity_copy);

        return SessionTicket{
            .ticket_data = ticket_data_copy,
            .server_name = null,
            .lifetime_hint = 86400, // 24 hours default
            .created_at = std.time.timestamp(),
            .max_early_data_size = 16384, // 16KB default
            .psk_identity = psk_identity_copy,
        };
    }

    pub fn deinit(self: *SessionTicket, allocator: std.mem.Allocator) void {
        allocator.free(self.ticket_data);
        allocator.free(self.psk_identity);
        if (self.server_name) |sn| {
            allocator.free(sn);
        }
    }

    /// Check if ticket is expired
    pub fn isExpired(self: *const SessionTicket) bool {
        const now = std.time.timestamp();
        const age = now - self.created_at;
        return age > self.lifetime_hint;
    }

    /// Set server name (SNI)
    pub fn setServerName(self: *SessionTicket, allocator: std.mem.Allocator, server_name: []const u8) !void {
        if (self.server_name) |sn| {
            allocator.free(sn);
        }
        self.server_name = try allocator.dupe(u8, server_name);
    }
};

/// TLS session cache for storing and retrieving session tickets
pub const SessionCache = struct {
    allocator: std.mem.Allocator,

    /// Map of PSK identity -> Session ticket
    sessions: std.StringHashMap(*SessionTicket),

    /// Maximum cache size
    max_size: usize = 10000,

    /// Current cache size
    size: usize = 0,

    pub fn init(allocator: std.mem.Allocator) SessionCache {
        return SessionCache{
            .allocator = allocator,
            .sessions = std.StringHashMap(*SessionTicket).init(allocator),
        };
    }

    pub fn deinit(self: *SessionCache) void {
        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit();
    }

    /// Store a session ticket
    pub fn storeTicket(self: *SessionCache, ticket: *SessionTicket) !void {
        // Check if we need to evict old entries
        if (self.sessions.count() >= self.max_size) {
            try self.evictExpired();
        }

        // If still at limit, remove oldest entry
        if (self.sessions.count() >= self.max_size) {
            const oldest_key = self.findOldestEntry();
            if (oldest_key) |key| {
                if (self.sessions.fetchRemove(key)) |kv| {
                    kv.value.deinit(self.allocator);
                    self.allocator.destroy(kv.value);
                    self.size -= 1;
                }
            }
        }

        // Store the ticket
        const ticket_copy = try self.allocator.create(SessionTicket);
        ticket_copy.* = ticket.*;
        // Note: We take ownership of the ticket data

        try self.sessions.put(ticket.psk_identity, ticket_copy);
        self.size += 1;
    }

    /// Retrieve a session ticket by PSK identity
    pub fn getTicket(self: *SessionCache, psk_identity: []const u8) ?*SessionTicket {
        return self.sessions.get(psk_identity);
    }

    /// Remove a session ticket
    pub fn removeTicket(self: *SessionCache, psk_identity: []const u8) void {
        if (self.sessions.fetchRemove(psk_identity)) |kv| {
            kv.value.deinit(self.allocator);
            self.allocator.destroy(kv.value);
            self.size -= 1;
        }
    }

    /// Clean up expired tickets
    pub fn evictExpired(self: *SessionCache) !void {
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                try to_remove.append(entry.key_ptr.*);
            }
        }

        for (to_remove.items) |key| {
            self.removeTicket(key);
        }
    }

    /// Find the oldest entry (for LRU eviction)
    fn findOldestEntry(self: *SessionCache) ?[]const u8 {
        var oldest_key: ?[]const u8 = null;
        var oldest_time: i64 = std.math.maxInt(i64);

        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.created_at < oldest_time) {
                oldest_time = entry.value_ptr.created_at;
                oldest_key = entry.key_ptr.*;
            }
        }

        return oldest_key;
    }

    /// Get cache statistics
    pub fn getStats(self: *const SessionCache) struct {
        total_sessions: usize,
        max_sessions: usize,
    } {
        return .{
            .total_sessions = self.size,
            .max_sessions = self.max_size,
        };
    }
};

/// TLS 0-RTT early data context
pub const EarlyDataContext = struct {
    /// Early data buffer
    data: std.ArrayList(u8),

    /// Whether early data was accepted
    accepted: bool = false,

    /// Maximum early data size allowed
    max_size: usize,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) EarlyDataContext {
        return EarlyDataContext{
            .data = std.ArrayList(u8).initCapacity(allocator, max_size) catch std.ArrayList(u8).init(allocator),
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *EarlyDataContext) void {
        self.data.deinit();
    }

    /// Add early data
    pub fn addData(self: *EarlyDataContext, data: []const u8) !bool {
        if (self.data.items.len + data.len > self.max_size) {
            return false; // Would exceed max size
        }

        try self.data.appendSlice(data);
        return true;
    }

    /// Get early data
    pub fn getData(self: *const EarlyDataContext) []const u8 {
        return self.data.items;
    }

    /// Check if early data is available
    pub fn hasData(self: *const EarlyDataContext) bool {
        return self.data.items.len > 0;
    }

    /// Mark early data as accepted
    pub fn accept(self: *EarlyDataContext) void {
        self.accepted = true;
    }
};

/// QUIC token for address validation and 0-RTT
pub const QuicToken = struct {
    /// Token data (opaque)
    token_data: []const u8,

    /// Client IP address
    client_ip: u32,

    /// Client port
    client_port: u16,

    /// Token creation time
    created_at: i64,

    /// Token lifetime (seconds)
    lifetime_seconds: u32 = 300, // 5 minutes default

    pub fn init(allocator: std.mem.Allocator, token_data: []const u8, client_ip: u32, client_port: u16) !QuicToken {
        const token_data_copy = try allocator.dupe(u8, token_data);

        return QuicToken{
            .token_data = token_data_copy,
            .client_ip = client_ip,
            .client_port = client_port,
            .created_at = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *QuicToken, allocator: std.mem.Allocator) void {
        allocator.free(self.token_data);
    }

    /// Check if token is expired
    pub fn isExpired(self: *const QuicToken) bool {
        const now = std.time.timestamp();
        const age = now - self.created_at;
        return age > self.lifetime_seconds;
    }

    /// Validate token against client address
    pub fn validateAddress(self: *const QuicToken, client_ip: u32, client_port: u16) bool {
        return self.client_ip == client_ip and self.client_port == client_port;
    }
};

/// QUIC token cache for address validation
pub const TokenCache = struct {
    allocator: std.mem.Allocator,

    /// Map of client IP+port -> QUIC token
    tokens: std.AutoHashMap(u64, *QuicToken),

    /// Maximum cache size
    max_size: usize = 100000,

    pub fn init(allocator: std.mem.Allocator) TokenCache {
        return TokenCache{
            .allocator = allocator,
            .tokens = std.AutoHashMap(u64, *QuicToken).init(allocator),
        };
    }

    pub fn deinit(self: *TokenCache) void {
        var iterator = self.tokens.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.tokens.deinit();
    }

    /// Generate a unique key from IP and port
    fn makeKey(client_ip: u32, client_port: u16) u64 {
        return (@as(u64, client_ip) << 16) | client_port;
    }

    /// Store a token
    pub fn storeToken(self: *TokenCache, token: *QuicToken) !void {
        // Check cache size limit
        if (self.tokens.count() >= self.max_size) {
            try self.evictExpired();
        }

        const key = makeKey(token.client_ip, token.client_port);
        const token_copy = try self.allocator.create(QuicToken);
        token_copy.* = token.*;
        // Note: We take ownership

        try self.tokens.put(key, token_copy);
    }

    /// Retrieve a token
    pub fn getToken(self: *TokenCache, client_ip: u32, client_port: u16) ?*QuicToken {
        const key = makeKey(client_ip, client_port);
        return self.tokens.get(key);
    }

    /// Validate a token
    pub fn validateToken(self: *TokenCache, token_data: []const u8, client_ip: u32, client_port: u16) ?*QuicToken {
        const token = self.getToken(client_ip, client_port) orelse return null;

        // Check if token data matches
        if (!std.mem.eql(u8, token.token_data, token_data)) {
            return null;
        }

        // Check if token is expired
        if (token.isExpired()) {
            // Remove expired token
            const key = makeKey(client_ip, client_port);
            _ = self.tokens.remove(key);
            token.deinit(self.allocator);
            self.allocator.destroy(token);
            return null;
        }

        return token;
    }

    /// Clean up expired tokens
    pub fn evictExpired(self: *TokenCache) !void {
        var to_remove = std.ArrayList(u64).init(self.allocator);
        defer to_remove.deinit();

        var iterator = self.tokens.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                try to_remove.append(entry.key_ptr.*);
            }
        }

        for (to_remove.items) |key| {
            if (self.tokens.fetchRemove(key)) |kv| {
                kv.value.deinit(self.allocator);
                self.allocator.destroy(kv.value);
            }
        }
    }

    /// Get cache statistics
    pub fn getStats(self: *const TokenCache) struct {
        total_tokens: usize,
        max_tokens: usize,
    } {
        return .{
            .total_tokens = self.tokens.count(),
            .max_tokens = self.max_size,
        };
    }
};
// Reviewed: 2025-12-01
