//! JWT (JSON Web Token) authentication and authorization
//! Supports HS256, RS256, and ES256 signature algorithms
//! RFC 7519 compliant implementation

const std = @import("std");
const crypto = std.crypto;
const json = std.json;
const base64 = std.base64;
const mem = std.mem;
const time = std.time;
const json_mod = std.json;

pub const Algorithm = enum {
    HS256,
    RS256,
    ES256,
};

/// JWT Header structure
pub const Header = struct {
    alg: Algorithm,
    typ: []const u8 = "JWT",
    kid: ?[]const u8 = null, // Key ID

    pub fn deinit(self: *Header, allocator: std.mem.Allocator) void {
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
    custom_claims: std.StringHashMap(json_mod.Value),

    pub fn init(allocator: std.mem.Allocator) Payload {
        return .{
            .custom_claims = std.StringHashMap(json_mod.Value).init(allocator),
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
            entry.value_ptr.*.deinit();
        }
        self.custom_claims.deinit();
    }

    /// Check if token is expired
    pub fn isExpired(self: *const Payload) bool {
        if (self.exp) |exp| {
            const now = time.timestamp();
            return now >= exp;
        }
        return false;
    }

    /// Check if token is not yet valid
    pub fn isNotYetValid(self: *const Payload) bool {
        if (self.nbf) |nbf| {
            const now = time.timestamp();
            return now < nbf;
        }
        return false;
    }

    /// Validate standard claims
    pub fn validateClaims(self: *const Payload, expected_issuer: ?[]const u8, expected_audience: ?[]const u8) !void {
        // Check expiration
        if (self.isExpired()) {
            return error.TokenExpired;
        }

        // Check not before
        if (self.isNotYetValid()) {
            return error.TokenNotYetValid;
        }

        // Check issuer
        if (expected_issuer) |expected| {
            if (self.iss == null or !mem.eql(u8, self.iss.?, expected)) {
                return error.InvalidIssuer;
            }
        }

        // Check audience
        if (expected_audience) |expected| {
            if (self.aud == null or !mem.eql(u8, self.aud.?, expected)) {
                return error.InvalidAudience;
            }
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
};

/// JWT Validator configuration
pub const ValidatorConfig = struct {
    algorithm: Algorithm,
    issuer: ?[]const u8 = null,
    audience: ?[]const u8 = null,
    leeway_seconds: i64 = 0, // Clock skew tolerance

    // For HMAC
    secret: ?[]const u8 = null,

    // For RSA/ECDSA - key set with kid mapping
    keys: std.StringHashMap([]const u8) = undefined,

    pub fn init(allocator: std.mem.Allocator) ValidatorConfig {
        return .{
            .algorithm = .HS256,
            .keys = std.StringHashMap([]const u8).init(allocator),
        };
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
    pub fn addKey(self: *ValidatorConfig, allocator: std.mem.Allocator, kid: []const u8, key_pem: []const u8) !void {
        const kid_copy = try allocator.dupe(u8, kid);
        const key_copy = try allocator.dupe(u8, key_pem);
        try self.keys.put(kid_copy, key_copy);
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
        // Split token into parts
        var parts = std.mem.splitSequence(u8, token_str, ".");
        const header_b64 = parts.next() orelse return ValidationError.InvalidToken;
        const payload_b64 = parts.next() orelse return ValidationError.InvalidToken;
        const signature_b64 = parts.next() orelse return ValidationError.InvalidToken;

        if (parts.next() != null) return ValidationError.InvalidToken;

        // Decode header
        const header_decoded_len = std.base64.url_safe.Decoder.calcSize(header_b64.len) catch return error.InvalidBase64;
        const header_json = try self.allocator.alloc(u8, header_decoded_len);
        errdefer self.allocator.free(header_json);
        _ = std.base64.url_safe.Decoder.decode(header_json, header_b64) catch return error.InvalidBase64;

        var header = try self.parseHeader(header_json);
        defer header.deinit(self.allocator);

        // Decode payload
        const payload_json = try std.base64.url_safe.Decoder.allocDecode(self.allocator, payload_b64);
        defer self.allocator.free(payload_json);

        var payload = try self.parsePayload(payload_json);
        defer payload.deinit(self.allocator);

        // Decode signature
        const signature_decoded_len = std.base64.url_safe.Decoder.calcSize(signature_b64.len) catch return error.InvalidBase64;
        const signature = try self.allocator.alloc(u8, signature_decoded_len);
        errdefer self.allocator.free(signature);
        _ = std.base64.url_safe.Decoder.decode(signature, signature_b64) catch return error.InvalidBase64;

        // Validate algorithm matches config
        if (@intFromEnum(header.alg) != @intFromEnum(self.config.algorithm)) {
            return ValidationError.UnsupportedAlgorithm;
        }

        // Create signing input
        const signing_input = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_b64, payload_b64 });
        defer self.allocator.free(signing_input);

        // Verify signature
        try self.verifySignature(signing_input, signature, &header);

        // Validate claims
        try payload.validateClaims(self.config.issuer, self.config.audience);

        // Adjust for clock skew
        if (payload.exp) |exp| {
            payload.exp = exp + self.config.leeway_seconds;
        }
        if (payload.nbf) |nbf| {
            payload.nbf = nbf - self.config.leeway_seconds;
        }

        return Token{
            .header = header,
            .payload = payload,
            .signature = signature,
        };
    }

    /// Parse JWT header from JSON
    fn parseHeader(self: *Validator, json_str: []const u8) !Header {
        var parser = json.Parser.init(self.allocator, false);
        defer parser.deinit();

        var tree = try parser.parse(json_str);
        defer tree.deinit();

        const root = tree.root.Object;

        // Get algorithm
        const alg_str = root.get("alg") orelse return ValidationError.InvalidHeader;
        const alg = try self.parseAlgorithm(alg_str.String);

        // Get type (optional)
        const typ = if (root.get("typ")) |t| t.String else "JWT";

        // Get key ID (optional)
        const kid = if (root.get("kid")) |k| try self.allocator.dupe(u8, k.String) else null;

        return Header{
            .alg = alg,
            .typ = typ,
            .kid = kid,
        };
    }

    /// Parse JWT payload from JSON
    fn parsePayload(self: *Validator, json_str: []const u8) !Payload {
        var parser = json.Parser.init(self.allocator, false);
        defer parser.deinit();

        var tree = try parser.parse(json_str);
        defer tree.deinit();

        const root = tree.root.Object;
        var payload = Payload.init(self.allocator);

        // Parse standard claims
        if (root.get("iss")) |v| {
            payload.iss = try self.allocator.dupe(u8, v.String);
        }
        if (root.get("sub")) |v| {
            payload.sub = try self.allocator.dupe(u8, v.String);
        }
        if (root.get("aud")) |v| {
            payload.aud = try self.allocator.dupe(u8, v.String);
        }
        if (root.get("exp")) |v| {
            payload.exp = v.Integer;
        }
        if (root.get("nbf")) |v| {
            payload.nbf = v.Integer;
        }
        if (root.get("iat")) |v| {
            payload.iat = v.Integer;
        }
        if (root.get("jti")) |v| {
            payload.jti = try self.allocator.dupe(u8, v.String);
        }

        // Store custom claims
        var it = root.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            // Skip standard claims
            if (mem.eql(u8, key, "iss") or mem.eql(u8, key, "sub") or
                mem.eql(u8, key, "aud") or mem.eql(u8, key, "exp") or
                mem.eql(u8, key, "nbf") or mem.eql(u8, key, "iat") or
                mem.eql(u8, key, "jti"))
            {
                continue;
            }

            const key_copy = try self.allocator.dupe(u8, key);
            try payload.custom_claims.put(key_copy, entry.value_ptr.*);
        }

        return payload;
    }

    /// Parse algorithm string
    fn parseAlgorithm(_: *Validator, alg_str: []const u8) !Algorithm {
        if (mem.eql(u8, alg_str, "HS256")) return .HS256;
        if (mem.eql(u8, alg_str, "RS256")) return .RS256;
        if (mem.eql(u8, alg_str, "ES256")) return .ES256;
        return ValidationError.UnsupportedAlgorithm;
    }

    /// Verify JWT signature
    fn verifySignature(self: *Validator, signing_input: []const u8, signature: []const u8, header: *const Header) !void {
        switch (self.config.algorithm) {
            .HS256 => try self.verifyHmac(signing_input, signature),
            .RS256 => try self.verifyRsa(signing_input, signature, header),
            .ES256 => try self.verifyEcdsa(signing_input, signature, header),
        }
    }

    /// Verify HMAC signature
    fn verifyHmac(self: *Validator, data: []const u8, signature: []const u8) !void {
        const secret = self.config.secret orelse return ValidationError.KeyNotFound;

        var expected_sig: [32]u8 = undefined;
        crypto.auth.hmac.sha2.HmacSha256.create(&expected_sig, data, secret);

        if (!crypto.utils.timingSafeEql([32]u8, expected_sig, signature[0..32])) {
            return ValidationError.InvalidSignature;
        }
    }

    /// Verify RSA signature (placeholder - needs crypto implementation)
    fn verifyRsa(self: *Validator, data: []const u8, signature: []const u8, header: *const Header) !void {
        _ = data;
        _ = signature;

        // Get key by kid
        const kid = header.kid orelse return ValidationError.KeyNotFound;
        const key_pem = self.config.keys.get(kid) orelse return ValidationError.KeyNotFound;

        // TODO: Implement RSA signature verification using std.crypto.sign
        // For now, this is a placeholder
        _ = key_pem;
        return ValidationError.UnsupportedAlgorithm; // Remove when implemented
    }

    /// Verify ECDSA signature (placeholder - needs crypto implementation)
    fn verifyEcdsa(self: *Validator, data: []const u8, signature: []const u8, header: *const Header) !void {
        _ = data;
        _ = signature;

        // Get key by kid
        const kid = header.kid orelse return ValidationError.KeyNotFound;
        const key_pem = self.config.keys.get(kid) orelse return ValidationError.KeyNotFound;

        // TODO: Implement ECDSA signature verification using std.crypto.sign
        // For now, this is a placeholder
        _ = key_pem;
        return ValidationError.UnsupportedAlgorithm; // Remove when implemented
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
        self.allocator.free(self.header_name);
        self.allocator.free(self.scheme);
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
        if (claim_value == .String) {
            if (!mem.eql(u8, claim_value.String, required_value)) {
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
    pub fn getClaim(self: *JWTMiddleware, token: *const Token, claim_name: []const u8) ?json_mod.Value {
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
            .typ = header.typ,
            .kid = header.kid,
        }, .{}, buffer.writer());

        return buffer.toOwnedSlice();
    }

    fn encodePayload(self: *Creator, payload: Payload) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        try json.stringify(.{
            .iss = payload.iss,
            .sub = payload.sub,
            .aud = payload.aud,
            .exp = payload.exp,
            .nbf = payload.nbf,
            .iat = payload.iat,
            .jti = payload.jti,
        }, .{}, buffer.writer());

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
