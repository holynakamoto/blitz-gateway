// Connection pooling for backend servers
// Reuses TCP connections to backends for better performance

const std = @import("std");
const backend = @import("backend.zig");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
});

pub const BackendConnection = struct {
    fd: c_int,
    backend: *backend.Backend,
    last_used: i64,
    is_idle: bool = true,
    
    pub fn init(fd: c_int, backend_server: *backend.Backend) BackendConnection {
        return BackendConnection{
            .fd = fd,
            .backend = backend_server,
            .last_used = std.time.milliTimestamp(),
            .is_idle = true,
        };
    }
    
    pub fn deinit(self: *BackendConnection) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }
    
    pub fn markUsed(self: *BackendConnection) void {
        self.last_used = std.time.milliTimestamp();
        self.is_idle = false;
    }
    
    pub fn markIdle(self: *BackendConnection) void {
        self.is_idle = true;
        self.last_used = std.time.milliTimestamp();
    }
    
    pub fn isStale(self: *const BackendConnection, max_idle_time: i64) bool {
        const now = std.time.milliTimestamp();
        return (now - self.last_used) > max_idle_time;
    }
};

pub const ConnectionPool = struct {
    connections: std.ArrayListUnmanaged(BackendConnection),
    allocator: std.mem.Allocator,
    max_connections_per_backend: usize = 10,
    max_idle_time: i64 = 30000, // 30 seconds
    
    pub fn init(allocator: std.mem.Allocator) ConnectionPool {
        return ConnectionPool{
            .connections = .{},
            .allocator = allocator,
            .max_connections_per_backend = 10,
            .max_idle_time = 30000,
        };
    }
    
    pub fn deinit(self: *ConnectionPool) void {
        for (self.connections.items) |*conn| {
            conn.deinit();
        }
        self.connections.deinit(self.allocator);
    }
    
    /// Get or create a connection to a backend
    pub fn getConnection(self: *ConnectionPool, backend_server: *backend.Backend) !?*BackendConnection {
        // First, try to find an idle connection to this backend
        for (self.connections.items) |*conn| {
            if (conn.backend == backend_server and conn.is_idle) {
                // Check if connection is still valid
                if (!conn.isStale(self.max_idle_time)) {
                    conn.markUsed();
                    return conn;
                } else {
                    // Stale connection, close it
                    conn.deinit();
                }
            }
        }
        
        // Count active connections to this backend
        var count: usize = 0;
        for (self.connections.items) |*conn| {
            if (conn.backend == backend_server and !conn.is_idle) {
                count += 1;
            }
        }
        
        // Check if we've reached the limit
        if (count >= self.max_connections_per_backend) {
            return null; // Connection limit reached
        }
        
        // Create new connection
        const sockfd = try self.createConnection(backend_server);
        errdefer _ = c.close(sockfd);
        
        const conn = BackendConnection.init(sockfd, backend_server);
        try self.connections.append(self.allocator, conn);
        
        const conn_ptr = &self.connections.items[self.connections.items.len - 1];
        conn_ptr.markUsed();
        
        return conn_ptr;
    }
    
    /// Create a new TCP connection to a backend
    fn createConnection(self: *ConnectionPool, backend_server: *backend.Backend) !c_int {
        _ = self;
        
        const sockfd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (sockfd < 0) {
            return error.SocketCreationFailed;
        }
        
        // Set socket options
        const reuse = 1;
        _ = c.setsockopt(sockfd, c.SOL_SOCKET, c.SO_REUSEADDR, &reuse, @sizeOf(c_int));
        
        // Get backend address
        const addr = try backend_server.getAddress();
        const addr_ptr: *const c.struct_sockaddr = @ptrCast(&addr);
        
        // Connect
        const connect_result = c.connect(sockfd, addr_ptr, @sizeOf(c.struct_sockaddr_in));
        if (connect_result < 0) {
            _ = c.close(sockfd);
            return error.ConnectionFailed;
        }
        
        return sockfd;
    }
    
    /// Return a connection to the pool (mark as idle)
    pub fn returnConnection(self: *ConnectionPool, conn: *BackendConnection) void {
        _ = self; // Method signature requires self
        conn.markIdle();
    }
    
    /// Remove a connection from the pool (e.g., on error)
    pub fn removeConnection(self: *ConnectionPool, conn: *BackendConnection) void {
        for (self.connections.items, 0..) |*connection, i| {
            if (connection == conn) {
                connection.deinit();
                _ = self.connections.swapRemove(i);
                break;
            }
        }
    }
    
    /// Clean up stale connections
    pub fn cleanupStaleConnections(self: *ConnectionPool) void {
        var i: usize = 0;
        while (i < self.connections.items.len) {
            const conn = &self.connections.items[i];
            if (conn.is_idle and conn.isStale(self.max_idle_time)) {
                conn.deinit();
                _ = self.connections.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

