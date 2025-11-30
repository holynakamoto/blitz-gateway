//! HTTP Middleware system for Blitz Gateway
//! Supports chaining multiple middleware handlers

const std = @import("std");
const jwt = @import("jwt.zig");

/// HTTP Request context passed to middleware
pub const RequestContext = struct {
    method: []const u8,
    path: []const u8,
    headers: *std.StringHashMap([]const u8),
    body: ?[]const u8 = null,
    remote_addr: ?[]const u8 = null,

    // Middleware-specific data
    user: ?jwt.Token = null,
    custom_data: std.StringHashMap(json_mod.Value),

    pub fn init(allocator: std.mem.Allocator, method: []const u8, path: []const u8, headers: *std.StringHashMap([]const u8)) RequestContext {
        return .{
            .method = method,
            .path = path,
            .headers = headers,
            .custom_data = std.StringHashMap(json_mod.Value).init(allocator),
        };
    }

    pub fn deinit(self: *RequestContext) void {
        if (self.user) |*user| {
            user.deinit(self.custom_data.allocator);
        }

        var it = self.custom_data.iterator();
        while (it.next()) |entry| {
            self.custom_data.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.custom_data.deinit();
    }

    /// Set authenticated user
    pub fn setUser(self: *RequestContext, user: jwt.Token) void {
        if (self.user) |*existing| {
            existing.deinit(self.custom_data.allocator);
        }
        self.user = user;
    }

    /// Get user ID if authenticated
    pub fn getUserId(self: *RequestContext) ?[]const u8 {
        if (self.user) |user| {
            return user.payload.sub;
        }
        return null;
    }

    /// Check if user is authenticated
    pub fn isAuthenticated(self: *RequestContext) bool {
        return self.user != null;
    }

    /// Check if user has specific role/permission
    pub fn hasRole(self: *RequestContext, role: []const u8) bool {
        if (self.user) |user| {
            const roles_claim = user.payload.custom_claims.get("roles");
            if (roles_claim) |claim| {
                if (claim == .Array) {
                    for (claim.Array.items) |item| {
                        if (item == .String and std.mem.eql(u8, item.String, role)) {
                            return true;
                        }
                    }
                } else if (claim == .String and std.mem.eql(u8, claim.String, role)) {
                    return true;
                }
            }
        }
        return false;
    }
};

/// HTTP Response context
pub const ResponseContext = struct {
    allocator: std.mem.Allocator,
    status_code: u16 = 200,
    headers: std.StringHashMap([]const u8),
    body: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) ResponseContext {
        return .{
            .allocator = allocator,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *ResponseContext) void {
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        self.body.deinit();
    }

    /// Set response status
    pub fn setStatus(self: *ResponseContext, status: u16) void {
        self.status_code = status;
    }

    /// Add header
    pub fn setHeader(self: *ResponseContext, name: []const u8, value: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.headers.put(name_copy, value_copy);
    }

    /// Write response body
    pub fn write(self: *ResponseContext, data: []const u8) !void {
        try self.body.appendSlice(data);
    }

    /// Write JSON response
    pub fn json(self: *ResponseContext, value: anytype) !void {
        try self.setHeader("Content-Type", "application/json");
        try json_mod.stringify(value, .{}, self.body.writer());
    }
};

/// Middleware result
pub const MiddlewareResult = enum {
    /// Continue to next middleware
    next,
    /// Stop processing and return response
    respond,
};

/// Middleware handler function type
pub const MiddlewareHandler = *const fn (*RequestContext, *ResponseContext) anyerror!MiddlewareResult;

/// Middleware chain
pub const MiddlewareChain = struct {
    allocator: std.mem.Allocator,
    handlers: std.ArrayListUnmanaged(MiddlewareHandler) = .{},

    pub fn init(allocator: std.mem.Allocator) MiddlewareChain {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MiddlewareChain) void {
        self.handlers.deinit(self.allocator);
    }

    /// Add middleware to the chain
    pub fn use(self: *MiddlewareChain, handler: MiddlewareHandler) !void {
        try self.handlers.append(self.allocator, handler);
    }

    /// Process request through middleware chain
    pub fn process(self: *MiddlewareChain, req: *RequestContext, res: *ResponseContext) !void {
        for (self.handlers.items) |handler| {
            const result = try handler(req, res);
            switch (result) {
                .next => continue,
                .respond => return,
            }
        }
    }
};

/// JWT Authentication middleware
pub const JWTAuthMiddleware = struct {
    jwt_middleware: jwt.JWTMiddleware,

    pub fn init(allocator: std.mem.Allocator, validator_config: jwt.ValidatorConfig) !JWTAuthMiddleware {
        const validator = jwt.Validator.init(allocator, validator_config);
        const jwt_middleware = jwt.JWTMiddleware.init(allocator, validator);

        return .{
            .jwt_middleware = jwt_middleware,
        };
    }

    pub fn deinit(self: *JWTAuthMiddleware) void {
        self.jwt_middleware.deinit();
    }

    /// Create middleware handler function
    pub fn handler(_: *JWTAuthMiddleware) MiddlewareHandler {
        return &jwtAuthHandler;
    }

    /// JWT authentication handler
    fn jwtAuthHandler(req: *RequestContext, res: *ResponseContext) !MiddlewareResult {
        // Skip authentication for certain paths
        if (std.mem.eql(u8, req.path, "/health") or
            std.mem.eql(u8, req.path, "/metrics") or
            std.mem.startsWith(u8, req.path, "/.well-known/")) {
            return .next;
        }

        // Create a temporary middleware instance (in real implementation, this would be stored)
        var temp_config = jwt.ValidatorConfig.init(req.custom_data.allocator);
        defer temp_config.deinit(req.custom_data.allocator);

        // TODO: Get config from server configuration
        temp_config.algorithm = .HS256;
        const secret = try req.custom_data.allocator.dupe(u8, "your-secret-key");
        temp_config.secret = secret;

        var temp_validator = jwt.Validator.init(req.custom_data.allocator, temp_config);
        defer temp_validator.deinit();

        var temp_jwt_middleware = jwt.JWTMiddleware.init(req.custom_data.allocator, temp_validator);
        defer temp_jwt_middleware.deinit();

        // Try to authenticate
        const token = temp_jwt_middleware.authenticateRequest(req.headers) catch |err| {
            switch (err) {
                jwt.ValidationError.InvalidToken,
                jwt.ValidationError.InvalidSignature,
                jwt.ValidationError.TokenExpired,
                jwt.ValidationError.InvalidIssuer,
                jwt.ValidationError.InvalidAudience => {
                    res.setStatus(401);
                    try res.setHeader("WWW-Authenticate", "Bearer");
                    try res.setHeader("Content-Type", "application/json");
                    try res.write("{\"error\":\"Unauthorized\",\"message\":\"Invalid or missing JWT token\"}");
                    return .respond;
                },
                else => {
                    res.setStatus(500);
                    try res.setHeader("Content-Type", "application/json");
                    try res.write("{\"error\":\"Internal Server Error\",\"message\":\"Authentication failed\"}");
                    return .respond;
                },
            }
        };

        // Store authenticated user in request context
        req.setUser(token);
        return .next;
    }
};

/// Authorization middleware factory
pub fn requireRole(required_role: []const u8) MiddlewareHandler {
    const Handler = struct {
        role: []const u8,

        fn handler(self: *const Handler, req: *RequestContext, res: *ResponseContext) !MiddlewareResult {
            if (!req.hasRole(self.role)) {
                res.setStatus(403);
                try res.setHeader("Content-Type", "application/json");
                try res.write("{\"error\":\"Forbidden\",\"message\":\"Insufficient permissions\",\"required_role\":\"");
                try res.write(self.role);
                try res.write("\"}");
                return .respond;
            }
            return .next;
        }
    };

    // This is a simplified approach - in a real implementation, you'd need to manage the lifetime
    // of the Handler instance. For now, we'll use a global or find another way.
    return struct {
        fn handler(req: *RequestContext, res: *ResponseContext) !MiddlewareResult {
            // For demo purposes, hardcode role check
            if (!req.hasRole(required_role)) {
                res.setStatus(403);
                try res.setHeader("Content-Type", "application/json");
                try res.write("{\"error\":\"Forbidden\",\"message\":\"Insufficient permissions\"}");
                return .respond;
            }
            return .next;
        }
    }.handler;
}

/// CORS middleware
pub fn corsMiddleware(req: *RequestContext, res: *ResponseContext) !MiddlewareResult {
    if (std.mem.eql(u8, req.method, "OPTIONS")) {
        res.setStatus(200);
        try res.setHeader("Access-Control-Allow-Origin", "*");
        try res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
        try res.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
        return .respond;
    }

    try res.setHeader("Access-Control-Allow-Origin", "*");
    return .next;
}

/// Logging middleware
pub fn loggingMiddleware(req: *RequestContext, _: *ResponseContext) !MiddlewareResult {
    const user_id = req.getUserId() orelse "anonymous";
    std.debug.print("[REQUEST] {s} {s} - User: {s}\n", .{ req.method, req.path, user_id });

    // Continue to next middleware
    const start_time = std.time.milliTimestamp();

    // Note: In a real implementation, we'd need to hook into the response
    // to log after completion. For now, just log the request.

    _ = start_time; // Unused in this simplified version
    return .next;
}

/// Rate limiting middleware (placeholder)
pub fn rateLimitMiddleware(req: *RequestContext, res: *ResponseContext) !MiddlewareResult {
    // TODO: Implement rate limiting based on IP/user
    const client_ip = req.remote_addr orelse "unknown";

    // Placeholder: Allow all requests
    std.debug.print("[RATE LIMIT] Request from {s} - ALLOWED\n", .{client_ip});
    _ = res;
    return .next;
}

const json_mod = std.json;
