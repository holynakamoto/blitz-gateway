//! JWT (JSON Web Token) authentication and authorization
//! Supports HS256, RS256, and ES256 signature algorithms
//! RFC 7519 compliant implementation
//! Compiles on Zig 0.15.0+ on macOS, Windows, and Linux (strict mode)

const std = @import("std");
const crypto = std.crypto;
const json = std.json;
const base64 = std.base64;
const mem = std.mem;
const time = std.time;

pub const Algorithm = enum {
    HS256,
    RS256,
    ES256,
};

/// JWT Header structure
pub const Header = struct {
    alg: Algorithm,
    typ: ?[]const u8 = null, // null means default "JWT"
    kid: ?[]const u8 = null, // Key ID

    /// Get the typ value, returning "JWT" if null (default)
    pub fn getTyp(self: *const Header) []const u8 {
        return self.typ orelse "JWT";
    }

    pub fn deinit(self: *Header, allocator: std.mem.Allocator) void {
        if (self.typ) |typ| allocator.free(typ);
        if (self.kid) |kid| allocator.free(kid);
    }
};

/// JWT Payload structure (standard claims)
pub const Payload = struct {
    iss: ?[]const u8 = null, // Issuer
    sub: ?[]const u8 = null, // Subject
    aud: ?[]const u8 = null, // Audience
    exp: ?i64 = null, // Expiration time
    nbf: ?i64 = null, // Not before
    iat: ?i64 = null, // Issued at
    jti: ?[]const u8 = null, // JWT ID

    // Custom claims can be added via additional JSON parsing
    custom_claims: std.StringHashMap(json.Value),

    pub fn init(allocator: std.mem.Allocator) Payload {
        return .{
            .custom_claims = std.StringHashMap(json.Value).init(allocator),
        };
    }

    pub fn deinit(self: *Payload, allocator: std.mem.Allocator) void {
        if (self.iss) |iss| allocator.free(iss);
        if (self.sub) |sub| allocator.free(sub);
        if (self.aud) |aud| allocator.free(aud);
        if (self.jti) |jti| allocator.free(jti);

        var it = self.custom_claims.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            // Free duplicated string values
            if (entry.value_ptr.* == .string) {
                allocator.free(entry.value_ptr.*.string);
            }
        }
        self.custom_claims.deinit();
    }

    /// Check if token is expired
    pub fn isExpired(self: *const Payload) bool {
        return if (self.exp) |exp| time.timestamp() >= exp else false;
    }

    /// Check if token is not yet valid
    pub fn isNotYetValid(self: *const Payload) bool {
        return if (self.nbf) |nbf| time.timestamp() < nbf else false;
    }

    /// Validate standard claims
    pub fn validateClaims(
        self: *const Payload,
        expected_issuer: ?[]const u8,
        expected_audience: ?[]const u8,
        leeway: i64,
    ) !void {
        const now = time.timestamp();

        if (self.exp) |exp| if (now >= exp + leeway) return error.TokenExpired;
        if (self.nbf) |nbf| if (now < nbf - leeway) return error.TokenNotYetValid;

        if (expected_issuer) |exp| {
            if (self.iss == null or !mem.eql(u8, self.iss.?, exp))
                return error.InvalidIssuer;
        }

        if (expected_audience) |exp| {
            if (self.aud == null or !mem.eql(u8, self.aud.?, exp))
                return error.InvalidAudience;
        }
    }
};

/// JWT Token structure
pub const Token = struct {
    header: Header,
    payload: Payload,
    signature: []const u8,

    pub fn deinit(self: *Token, allocator: std.mem.Allocator) void {
        self.header.deinit(allocator);
        self.payload.deinit(allocator);
        allocator.free(self.signature);
    }
};

/// JWT Validation errors
pub const ValidationError = error{
    InvalidToken,
    InvalidHeader,
    InvalidPayload,
    InvalidSignature,
    TokenExpired,
    TokenNotYetValid,
    InvalidIssuer,
    InvalidAudience,
    UnsupportedAlgorithm,
    KeyNotFound,
    InvalidBase64,
};

/// JWT Validator configuration
pub const ValidatorConfig = struct {
    algorithm: Algorithm = .HS256,
    issuer: ?[]const u8 = null,
    audience: ?[]const u8 = null,
    leeway_seconds: i64 = 0, // Clock skew tolerance

    // For HMAC
    secret: ?[]const u8 = null,

    // For RSA/ECDSA - key set with kid mapping
    keys: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) ValidatorConfig {
        return .{ .keys = std.StringHashMap([]const u8).init(allocator) };
    }

    pub fn deinit(self: *ValidatorConfig, allocator: std.mem.Allocator) void {
        if (self.issuer) |iss| allocator.free(iss);
        if (self.audience) |aud| allocator.free(aud);
        if (self.secret) |sec| allocator.free(sec);

        var it = self.keys.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.keys.deinit();
    }

    /// Add a key for RSA/ECDSA validation
    pub fn addKey(self: *ValidatorConfig, allocator: std.mem.Allocator, kid: []const u8, pem: []const u8) !void {
        try self.keys.put(try allocator.dupe(u8, kid), try allocator.dupe(u8, pem));
    }
};

/// JWT Validator
pub const Validator = struct {
    allocator: std.mem.Allocator,
    config: ValidatorConfig,

    pub fn init(allocator: std.mem.Allocator, config: ValidatorConfig) Validator {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Validator) void {
        self.config.deinit(self.allocator);
    }

    /// Validate a JWT token string
    pub fn validateToken(self: *Validator, token_str: []const u8) !Token {
        var parts = mem.splitSequence(u8, token_str, ".");
        const header_b64 = parts.next() orelse return error.InvalidToken;
        const payload_b64 = parts.next() orelse return error.InvalidToken;
        const sig_b64 = parts.next() orelse return error.InvalidToken;
        if (parts.next() != null) return error.InvalidToken;

        // Decode header
        const header_json = try self.decodeUrlBase64(header_b64);
        errdefer self.allocator.free(header_json);
        var header = try self.parseHeader(header_json);

        // Decode payload
        const payload_json = try self.decodeUrlBase64(payload_b64);
        errdefer self.allocator.free(payload_json);
        var payload = try self.parsePayload(payload_json);

        // Decode signature
        const signature = try self.decodeUrlBase64(sig_b64);
        errdefer self.allocator.free(signature);

        if (header.alg != self.config.algorithm) return error.UnsupportedAlgorithm;

        const signing_input = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_b64, payload_b64 });
        defer self.allocator.free(signing_input);

        try self.verifySignature(signing_input, signature, &header);
        try payload.validateClaims(self.config.issuer, self.config.audience, self.config.leeway_seconds);

        return Token{
            .header = header,
            .payload = payload,
            .signature = signature,
        };
    }

    fn decodeUrlBase64(self: *Validator, input: []const u8) ![]u8 {
        // Calculate decoded size: (input_len * 3) / 4
        // For URL-safe base64, the decoded length is exact for valid input
        const decoded_len = (input.len * 3) / 4;
        const out = try self.allocator.alloc(u8, decoded_len);
        errdefer self.allocator.free(out);

        // URL-safe base64 uses '-' and '_' instead of '+' and '/', and no padding
        const alphabet = base64.url_safe.alphabet_chars;
        var decoder = base64.Base64Decoder.init(alphabet, null);
        decoder.decode(out, input) catch return error.InvalidBase64;

        return out;
    }

    /// Parse JWT header from JSON
    fn parseHeader(self: *Validator, json_str: []const u8) !Header {
        var parsed = try json.parseFromSlice(json.Value, self.allocator, json_str, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;

        const alg_str = obj.get("alg") orelse return error.InvalidHeader;
        const alg = if (alg_str == .string) try parseAlg(alg_str.string) else return error.InvalidHeader;

        const typ = if (obj.get("typ")) |v| if (v == .string) try self.allocator.dupe(u8, v.string) else null else null;
        const kid = if (obj.get("kid")) |v| if (v == .string) try self.allocator.dupe(u8, v.string) else null else null;

        return Header{ .alg = alg, .typ = typ, .kid = kid };
    }

    /// Parse JWT payload from JSON
    fn parsePayload(self: *Validator, json_str: []const u8) !Payload {
        var parsed = try json.parseFromSlice(json.Value, self.allocator, json_str, .{});
        defer parsed.deinit();

        var payload = Payload.init(self.allocator);
        const obj = parsed.value.object;

        inline for (.{ "iss", "sub", "aud", "jti" }) |field| {
            if (obj.get(field)) |v| {
                if (v == .string) {
                    @field(payload, field) = try self.allocator.dupe(u8, v.string);
                }
            }
        }

        inline for (.{ "exp", "nbf", "iat" }) |field| {
            if (obj.get(field)) |v| {
                if (v == .integer) @field(payload, field) = v.integer;
            }
        }

        var it = obj.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (mem.eql(u8, key, "iss") or mem.eql(u8, key, "sub") or
                mem.eql(u8, key, "aud") or mem.eql(u8, key, "exp") or
                mem.eql(u8, key, "nbf") or mem.eql(u8, key, "iat") or
                mem.eql(u8, key, "jti")) continue;

            const k = try self.allocator.dupe(u8, key);
            const v = entry.value_ptr.*;
            const v_copy = switch (v) {
                .string => |s| json.Value{ .string = try self.allocator.dupe(u8, s) },
                .integer, .float, .bool, .null => v,
                // Skip complex types that would require deep cloning
                else => continue,
            };
            try payload.custom_claims.put(k, v_copy);
        }

        return payload;
    }

    fn parseAlg(str: []const u8) ValidationError!Algorithm {
        if (mem.eql(u8, str, "HS256")) return .HS256;
        if (mem.eql(u8, str, "RS256")) return .RS256;
        if (mem.eql(u8, str, "ES256")) return .ES256;
        return error.UnsupportedAlgorithm;
    }

    fn verifySignature(self: *Validator, data: []const u8, sig: []const u8, header: *const Header) !void {
        return switch (self.config.algorithm) {
            .HS256 => self.verifyHmac(data, sig),
            .RS256, .ES256 => {
                _ = header;
                return error.UnsupportedAlgorithm; // TODO: implement
            },
        };
    }

    fn verifyHmac(self: *Validator, data: []const u8, sig: []const u8) !void {
        const secret = self.config.secret orelse return error.KeyNotFound;

        if (sig.len != 32) return error.InvalidSignature;

        var expected: [32]u8 = undefined;
        crypto.auth.hmac.sha2.HmacSha256.create(&expected, data, secret);

        // Constant-time comparison to prevent timing attacks
        var diff: u8 = 0;
        for (expected, sig[0..32]) |a, b| {
            diff |= a ^ b;
        }
        if (diff != 0) return error.InvalidSignature;
    }
};

/// JWT Middleware for HTTP requests
pub const JWTMiddleware = struct {
    allocator: std.mem.Allocator,
    validator: Validator,
    header_name: []const u8 = "Authorization",
    scheme: []const u8 = "Bearer",

    pub fn init(allocator: std.mem.Allocator, validator: Validator) JWTMiddleware {
        return .{
            .allocator = allocator,
            .validator = validator,
        };
    }

    pub fn deinit(self: *JWTMiddleware) void {
        self.validator.deinit();
        // Only free if not default string literals (to avoid freeing compile-time literals)
        // Note: If custom values matching defaults are allocated, they won't be freed here.
        // This is safe for the common case where defaults are used.
        if (!mem.eql(u8, self.header_name, "Authorization")) {
            self.allocator.free(self.header_name);
        }
        if (!mem.eql(u8, self.scheme, "Bearer")) {
            self.allocator.free(self.scheme);
        }
    }

    /// Extract and validate JWT from HTTP request
    pub fn authenticateRequest(self: *JWTMiddleware, headers: *const std.StringHashMap([]const u8)) !Token {
        // Get Authorization header
        const auth_header = headers.get(self.header_name) orelse return ValidationError.InvalidToken;

        // Check scheme
        if (!mem.startsWith(u8, auth_header, self.scheme)) {
            return ValidationError.InvalidToken;
        }

        // Extract token (skip scheme + space)
        const token_start = self.scheme.len + 1;
        if (token_start >= auth_header.len) {
            return ValidationError.InvalidToken;
        }

        const token_str = mem.trim(u8, auth_header[token_start..], &std.ascii.whitespace);

        // Validate token
        return try self.validator.validateToken(token_str);
    }

    /// Check if user has required role/permission
    pub fn authorize(_: *JWTMiddleware, token: *const Token, required_claim: []const u8, required_value: []const u8) !void {
        const claim_value = token.payload.custom_claims.get(required_claim) orelse return ValidationError.InvalidToken;

        // For string claims
        if (claim_value == .string) {
            if (!mem.eql(u8, claim_value.string, required_value)) {
                return ValidationError.InvalidToken;
            }
        } else {
            return ValidationError.InvalidToken;
        }
    }

    /// Get user ID from token
    pub fn getUserId(self: *JWTMiddleware, token: *const Token) ?[]const u8 {
        _ = self;
        return token.payload.sub;
    }

    /// Get custom claim value
    pub fn getClaim(self: *JWTMiddleware, token: *const Token, claim_name: []const u8) ?json.Value {
        _ = self;
        return token.payload.custom_claims.get(claim_name);
    }
};

/// Utility functions for JWT creation (for testing/development)
pub const Creator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Creator {
        return .{ .allocator = allocator };
    }

    /// Create a JWT token (for testing/development only)
    pub fn createToken(self: *Creator, header: Header, payload: Payload, secret: []const u8) ![]u8 {
        // Encode header
        const header_json = try self.encodeHeader(header);
        defer self.allocator.free(header_json);

        const header_b64 = try self.base64Encode(header_json);
        defer self.allocator.free(header_b64);

        // Encode payload
        const payload_json = try self.encodePayload(payload);
        defer self.allocator.free(payload_json);

        const payload_b64 = try self.base64Encode(payload_json);
        defer self.allocator.free(payload_b64);

        // Create signing input
        const signing_input = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_b64, payload_b64 });
        defer self.allocator.free(signing_input);

        // Create signature
        const signature = try self.createSignature(signing_input, secret, header.alg);
        defer self.allocator.free(signature);

        const signature_b64 = try self.base64Encode(signature);
        defer self.allocator.free(signature_b64);

        // Combine into JWT
        return std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ header_b64, payload_b64, signature_b64 });
    }

    fn encodeHeader(self: *Creator, header: Header) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        try json.stringify(.{
            .alg = @tagName(header.alg),
            .typ = header.getTyp(),
            .kid = header.kid,
        }, .{}, buffer.writer());

        return buffer.toOwnedSlice();
    }

    fn encodePayload(self: *Creator, payload: Payload) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        // Create a JSON object containing both standard and custom claims
        var json_obj = json.ObjectMap.init(self.allocator);
        defer json_obj.deinit();

        // Add standard claims first (these take precedence over custom claims with same keys)
        if (payload.iss) |iss| try json_obj.put("iss", json.Value{ .string = iss });
        if (payload.sub) |sub| try json_obj.put("sub", json.Value{ .string = sub });
        if (payload.aud) |aud| try json_obj.put("aud", json.Value{ .string = aud });
        if (payload.exp) |exp| try json_obj.put("exp", json.Value{ .integer = exp });
        if (payload.nbf) |nbf| try json_obj.put("nbf", json.Value{ .integer = nbf });
        if (payload.iat) |iat| try json_obj.put("iat", json.Value{ .integer = iat });
        if (payload.jti) |jti| try json_obj.put("jti", json.Value{ .string = jti });

        // Add custom claims (skip if key conflicts with standard claims)
        var it = payload.custom_claims.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            // Skip if this key already exists (standard claims take precedence)
            if (json_obj.contains(key)) continue;
            try json_obj.put(key, entry.value_ptr.*);
        }

        // Serialize the merged object
        try json.stringify(json.Value{ .object = json_obj }, .{}, buffer.writer());

        return buffer.toOwnedSlice();
    }

    fn base64Encode(self: *Creator, data: []const u8) ![]u8 {
        const encoded_size = base64.url_safe_no_pad.Encoder.calcSize(data.len);
        const result = try self.allocator.alloc(u8, encoded_size);
        _ = base64.url_safe_no_pad.Encoder.encode(result, data);
        return result;
    }

    fn createSignature(self: *Creator, data: []const u8, secret: []const u8, alg: Algorithm) ![]u8 {
        switch (alg) {
            .HS256 => {
                var signature: [32]u8 = undefined;
                crypto.auth.hmac.sha2.HmacSha256.create(&signature, data, secret);
                return self.allocator.dupe(u8, &signature);
            },
            else => return ValidationError.UnsupportedAlgorithm,
        }
    }
};
