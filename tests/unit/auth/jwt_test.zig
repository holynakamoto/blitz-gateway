const std = @import("std");
const jwt = @import("../src/jwt.zig");
const testing = std.testing;

test "JWT HS256 token creation and validation" {
    const allocator = testing.allocator;

    // Create a token
    var header = jwt.Header{
        .alg = .HS256,
        .typ = "JWT",
    };

    var payload = jwt.Payload.init(allocator);
    defer payload.deinit(allocator);

    payload.iss = try allocator.dupe(u8, "test-issuer");
    payload.sub = try allocator.dupe(u8, "user123");
    payload.aud = try allocator.dupe(u8, "test-audience");
    payload.exp = std.time.timestamp() + 3600; // 1 hour from now
    payload.iat = std.time.timestamp();

    // Add custom claims
    var roles_claim = std.json.Value{ .Array = std.json.Array.initCapacity(allocator, 2) };
    roles_claim.Array.appendAssumeCapacity(.{ .String = try allocator.dupe(u8, "user") });
    roles_claim.Array.appendAssumeCapacity(.{ .String = try allocator.dupe(u8, "admin") });

    try payload.custom_claims.put(try allocator.dupe(u8, "roles"), roles_claim);
    try payload.custom_claims.put(try allocator.dupe(u8, "department"), .{ .String = try allocator.dupe(u8, "engineering") });

    var creator = jwt.Creator.init(allocator);
    defer creator.deinit();

    const secret = "my-super-secret-key-for-testing";
    const token_str = try creator.createToken(header, payload, secret);
    defer allocator.free(token_str);

    // Now validate the token
    var validator_config = jwt.ValidatorConfig.init(allocator);
    defer validator_config.deinit(allocator);

    validator_config.algorithm = .HS256;
    validator_config.secret = try allocator.dupe(u8, secret);
    validator_config.issuer = try allocator.dupe(u8, "test-issuer");
    validator_config.audience = try allocator.dupe(u8, "test-audience");

    var validator = jwt.Validator.init(allocator, validator_config);
    defer validator.deinit();

    const validated_token = try validator.validateToken(token_str);
    defer allocator.free(validated_token.signature);

    // Check claims
    try testing.expectEqualStrings("user123", validated_token.payload.sub.?);
    try testing.expectEqualStrings("test-issuer", validated_token.payload.iss.?);
    try testing.expectEqualStrings("test-audience", validated_token.payload.aud.?);

    // Check custom claims
    const roles_value = validated_token.payload.custom_claims.get("roles").?;
    try testing.expect(roles_value == .Array);
    try testing.expectEqual(@as(usize, 2), roles_value.Array.items.len);

    const dept_value = validated_token.payload.custom_claims.get("department").?;
    try testing.expectEqualStrings("engineering", dept_value.String);
}

test "JWT token expiration" {
    const allocator = testing.allocator;

    // Create an expired token
    var header = jwt.Header{ .alg = .HS256 };
    var payload = jwt.Payload.init(allocator);
    defer payload.deinit(allocator);

    payload.exp = std.time.timestamp() - 3600; // 1 hour ago

    var creator = jwt.Creator.init(allocator);
    defer creator.deinit();

    const token_str = try creator.createToken(header, payload, "secret");
    defer allocator.free(token_str);

    // Try to validate - should fail
    var validator_config = jwt.ValidatorConfig.init(allocator);
    defer validator_config.deinit(allocator);

    validator_config.algorithm = .HS256;
    validator_config.secret = try allocator.dupe(u8, "secret");

    var validator = jwt.Validator.init(allocator, validator_config);
    defer validator.deinit();

    const result = validator.validateToken(token_str);
    try testing.expectError(jwt.ValidationError.TokenExpired, result);
}

test "JWT middleware authentication" {
    const allocator = testing.allocator;

    // Create JWT middleware
    var validator_config = jwt.ValidatorConfig.init(allocator);
    defer validator_config.deinit(allocator);

    validator_config.algorithm = .HS256;
    validator_config.secret = try allocator.dupe(u8, "test-secret");

    var jwt_middleware = try jwt.JWTMiddleware.init(allocator, validator_config);
    defer jwt_middleware.deinit();

    // Create a test request with Authorization header
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = headers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        headers.deinit();
    }

    // Create a valid token
    var header = jwt.Header{ .alg = .HS256 };
    var payload = jwt.Payload.init(allocator);
    defer payload.deinit(allocator);

    payload.sub = try allocator.dupe(u8, "test-user");
    payload.exp = std.time.timestamp() + 3600;

    var creator = jwt.Creator.init(allocator);
    defer creator.deinit();

    const token_str = try creator.createToken(header, payload, "test-secret");
    defer allocator.free(token_str);

    // Add Authorization header
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token_str});
    defer allocator.free(auth_value);

    try headers.put(try allocator.dupe(u8, "Authorization"), auth_value);

    // Test authentication
    const authenticated_token = try jwt_middleware.authenticateRequest(&headers);
    defer allocator.free(authenticated_token.signature);

    try testing.expectEqualStrings("test-user", authenticated_token.payload.sub.?);

    // Test user ID getter
    const user_id = jwt_middleware.getUserId(authenticated_token);
    try testing.expectEqualStrings("test-user", user_id.?);
}

test "JWT middleware authorization" {
    const allocator = testing.allocator;

    // Create JWT middleware
    var validator_config = jwt.ValidatorConfig.init(allocator);
    defer validator_config.deinit(allocator);

    validator_config.algorithm = .HS256;
    validator_config.secret = try allocator.dupe(u8, "test-secret");

    var jwt_middleware = try jwt.JWTMiddleware.init(allocator, validator_config);
    defer jwt_middleware.deinit();

    // Create a token with roles
    var header = jwt.Header{ .alg = .HS256 };
    var payload = jwt.Payload.init(allocator);
    defer payload.deinit(allocator);

    payload.sub = try allocator.dupe(u8, "test-user");
    payload.exp = std.time.timestamp() + 3600;

    // Add roles claim
    var roles_claim = std.json.Value{ .Array = std.json.Array.initCapacity(allocator, 1) };
    roles_claim.Array.appendAssumeCapacity(.{ .String = try allocator.dupe(u8, "admin") });
    try payload.custom_claims.put(try allocator.dupe(u8, "roles"), roles_claim);

    var creator = jwt.Creator.init(allocator);
    defer creator.deinit();

    const token_str = try creator.createToken(header, payload, "test-secret");
    defer allocator.free(token_str);

    // Create middleware request context
    var req_ctx = jwt.middleware.RequestContext.init(allocator, "GET", "/api/admin", undefined);
    defer req_ctx.deinit();

    // Set authenticated user
    var auth_token = try jwt_middleware.authenticateRequest(undefined); // This would normally come from headers
    _ = auth_token; // Skip for this test

    // For this test, we'll manually create the authenticated token
    var authenticated_token = jwt.Token{
        .header = header,
        .payload = payload,
        .signature = try allocator.dupe(u8, "dummy-signature"),
    };
    defer allocator.free(authenticated_token.signature);

    req_ctx.setUser(authenticated_token);

    // Test authorization
    try jwt_middleware.authorize(&authenticated_token, "roles", "admin");

    // Test hasRole helper
    const has_admin_role = req_ctx.hasRole("admin");
    try testing.expect(has_admin_role);

    const has_user_role = req_ctx.hasRole("user");
    try testing.expect(!has_user_role);
}

test "JWT invalid token handling" {
    const allocator = testing.allocator;

    // Create JWT middleware
    var validator_config = jwt.ValidatorConfig.init(allocator);
    defer validator_config.deinit(allocator);

    validator_config.algorithm = .HS256;
    validator_config.secret = try allocator.dupe(u8, "correct-secret");

    var jwt_middleware = try jwt.JWTMiddleware.init(allocator, validator_config);
    defer jwt_middleware.deinit();

    // Test with invalid token
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = headers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        headers.deinit();
    }

    try headers.put(try allocator.dupe(u8, "Authorization"), "Bearer invalid.jwt.token");

    const result = jwt_middleware.authenticateRequest(&headers);
    try testing.expectError(jwt.ValidationError.InvalidToken, result);
}

test "JWT payload validation" {
    const allocator = testing.allocator;

    var payload = jwt.Payload.init(allocator);
    defer payload.deinit(allocator);

    // Test valid payload
    payload.iss = try allocator.dupe(u8, "test-issuer");
    payload.aud = try allocator.dupe(u8, "test-audience");
    payload.exp = std.time.timestamp() + 3600;

    try payload.validateClaims(try allocator.dupe(u8, "test-issuer"), try allocator.dupe(u8, "test-audience"));

    // Test expired token
    payload.exp = std.time.timestamp() - 1;
    const expired_result = payload.validateClaims(null, null);
    try testing.expectError(jwt.ValidationError.TokenExpired, expired_result);

    // Test invalid issuer
    payload.exp = std.time.timestamp() + 3600;
    const issuer_result = payload.validateClaims(try allocator.dupe(u8, "wrong-issuer"), null);
    try testing.expectError(jwt.ValidationError.InvalidIssuer, issuer_result);
}

test "JWT base64 URL encoding/decoding" {
    const allocator = testing.allocator;

    var creator = jwt.Creator.init(allocator);
    defer creator.deinit();

    // Test encoding
    const original = "Hello, JWT world! 🌍";
    const encoded = try creator.base64Encode(original);
    defer allocator.free(encoded);

    // Verify it's valid base64url (no padding, URL-safe chars)
    for (encoded) |c| {
        try testing.expect(c != '+' and c != '/' and c != '=');
    }

    // Test decoding (we'd need a decode function for full round-trip test)
    // For now, just ensure encoding produces expected output
    try testing.expect(encoded.len > 0);
}

